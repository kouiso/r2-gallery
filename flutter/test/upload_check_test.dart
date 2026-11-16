import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/duplicates/upload_check.dart';
import 'package:r2_gallery/src/offline/offline_store.dart';
import 'package:r2_gallery/src/state/app_state.dart';
import 'package:r2_gallery/src/transfer/transfer_api.dart';
import 'package:r2_gallery/src/transfer/transfer_queue.dart';
import 'package:r2_gallery/src/transfer/upload_confirm.dart';

UploadSource _src(String name, String content) {
  final b = Uint8List.fromList(utf8.encode(content));
  return UploadSource(name: name, size: b.length, mime: 'image/jpeg', bytes: b);
}

const _stored = MediaItem(
    key: 'old/same.jpg', type: 'image', url: 'https://w.example/m/same');

/// 中身の文字列そのものをハッシュ代わりにし、計算した名前を数える。
class _Hasher {
  final List<String> called = [];
  final Set<String> fail = {};
  Future<String> call(UploadSource s) async {
    called.add(s.name);
    if (fail.contains(s.name)) throw const FileSystemException('gone');
    return 'h:${utf8.decode(s.bytes!)}';
  }
}

/// Worker の照合を真似る。保存済みは「サイズ→中身」の表で持つ。
class _Checker {
  final Map<int, List<String>> stored;
  final List<List<({int size, String? sha256})>> calls = [];
  int pendingCalls = 0;
  ApiError? failWith;
  bool failOnHash = false;
  Completer<void>? gate;
  _Checker(this.stored);

  Future<ObjectCheck> call(
      String lib, List<({int size, String? sha256})> items) async {
    calls.add(items);
    await gate?.future;
    final f = failWith;
    final hashed = items.any((i) => i.sha256 != null);
    if (f != null && (!failOnHash || hashed)) throw f;
    final pending = hashed && pendingCalls > 0 ? pendingCalls-- : 0;
    return ObjectCheck(pending: pending, results: [
      for (final i in items)
        ObjectCheckResult(
          sizeMatches: stored[i.size]?.length ?? 0,
          matches: [
            if (pending == 0 &&
                i.sha256 != null &&
                (stored[i.size] ?? const []).contains(i.sha256))
              _stored,
          ],
        ),
    ]);
  }
}

Future<UploadCheckOutcome> _run(_Checker c, _Hasher h, List<UploadSource> s,
        {int maxCalls = 10}) =>
    runUploadCheck(
      check: c.call,
      lib: 'lib',
      sources: s,
      hasher: h.call,
      maxCalls: maxCalls,
      retryDelay: Duration.zero,
    );

/// 積まれた物を記録するだけの AppState。転送キューまでは動かさない。
class _UploadApp extends AppState {
  _UploadApp(ApiClient api, {bool readOnly = false})
      : super(api: api, bakedEndpoint: '', bakedToken: '') {
    connected = true;
    libraries = [Library(id: 'lib', title: 'L', readOnly: readOnly)];
    activeLib = 'lib';
  }
  final List<List<UploadSource>> uploads = [];
  @override
  Future<int> upload(String lib, List<UploadSource> sources) async {
    uploads.add(sources);
    return sources.length;
  }
}

class _CheckApi extends ApiClient {
  _CheckApi(this.checker);
  final _Checker checker;
  @override
  Future<ObjectCheck> checkObjects(
          String libId, List<({int size, String? sha256})> items) =>
      checker.call(libId, items);
}

/// 単発PUTに添えたハッシュと multipart の開始を記録する転送 API。
class _RecordingTransferApi implements TransferApi {
  final Map<String, String?> puts = {};
  final List<String> multiparts = [];
  @override
  Future<void> putObject(String lib, String key, Uint8List bytes, String mime,
      {CancelToken? cancelToken,
      void Function(int sent)? onProgress,
      String? sha256}) async {
    puts[key] = sha256;
  }

  @override
  Future<String> multipartCreate(String lib, String key, String contentType) async {
    multiparts.add(key);
    return 'u1';
  }

  @override
  Future<UploadPart> putPart(
          String lib, String key, String uploadId, int part, Uint8List bytes,
          {CancelToken? cancelToken, void Function(int sent)? onProgress}) async =>
      UploadPart(part, 'e$part');
  @override
  Future<void> multipartComplete(
      String lib, String key, String uploadId, List<UploadPart> parts) async {}
  @override
  Future<void> multipartAbort(String lib, String key, String uploadId) async {}
  @override
  Future<void> multipartAbortOn(String endpoint, String token, String lib,
          String key, String uploadId) =>
      multipartAbort(lib, key, uploadId);
  @override
  Future<void> putThumb(String lib, String key, Uint8List bytes) async {}
  @override
  Future<Uint8List> fetchBytes(String url,
          {CancelToken? cancelToken,
          void Function(int got, int total)? onProgress}) async =>
      Uint8List(0);
  @override
  Future<bool> storedMatches(
          String lib, String key, int size, Stream<List<int>> Function() local,
          {CancelToken? cancelToken, void Function(int matched)? onProgress}) async =>
      false;
  @override
  Future<String?> itemUrl(String lib, String key) async => null;
}

class _MemKv implements SecretKv {
  final Map<String, String> v = {};
  @override
  Future<String?> get(String key) async => v[key];
  @override
  Future<void> set(String key, String value) async => v[key] = value;
}

class _MemLedger implements LedgerStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String json) async => value = json;
}

void main() {
  group('照合の二段（#109）', () {
    test('サイズが合う物だけ計算し、ライブラリにある物に印を付ける', () async {
      final c = _Checker({4: ['h:same']});
      final h = _Hasher();
      final s = [_src('a.jpg', 'same'), _src('b.jpg', 'unique-content')];
      final o = await _run(c, h, s);
      expect(h.called, ['a.jpg'], reason: 'サイズが合わない b は読まない');
      expect(c.calls.first.every((i) => i.sha256 == null), isTrue);
      expect(c.calls[1], [(size: 4, sha256: 'h:same')]);
      expect(o.status, UploadCheckStatus.done);
      expect(o.flags.keys, [0]);
      expect(o.flags[0]!.stored!.key, 'old/same.jpg');
      expect(o.hashes, {0: 'h:same'});
    });

    test('サイズだけ同じで中身が違う物は印を付けない', () async {
      final c = _Checker({4: ['h:else']});
      final o = await _run(c, _Hasher(), [_src('a.jpg', 'same')]);
      expect(o.flags, isEmpty);
      expect(o.unresolved, isEmpty);
    });

    test('同じ選択の中で重なる物は2件目以降に印が付く。Worker にはハッシュを聞かない', () async {
      final c = _Checker({});
      final h = _Hasher();
      final o = await _run(c, h, [
        _src('a.jpg', 'dup1'),
        _src('b.jpg', 'dup1'),
        _src('c.jpg', 'dup2'),
        _src('d.jpg', 'longer'),
      ]);
      expect(h.called, ['a.jpg', 'b.jpg', 'c.jpg']);
      expect(o.flags.keys, [1]);
      expect(o.flags[1]!.sameAs, 0);
      expect(c.calls, hasLength(1));
    });

    test('Worker の計算待ちが続けば決めた回数で打ち切り、確かめられなかった物として返す', () async {
      final c = _Checker({4: ['h:same']})..pendingCalls = 99;
      final o = await _run(c, _Hasher(), [_src('a.jpg', 'same')], maxCalls: 3);
      expect(c.calls, hasLength(1 + 3));
      expect(o.flags, isEmpty);
      expect(o.unresolved, {0});
    });

    test('時間の上限を過ぎれば回数が残っていても打ち切る', () async {
      final c = _Checker({4: ['h:same']})..pendingCalls = 99;
      final o = await runUploadCheck(
          check: c.call,
          lib: 'lib',
          sources: [_src('a.jpg', 'same')],
          hasher: _Hasher().call,
          retryDelay: Duration.zero,
          budget: Duration.zero);
      expect(c.calls, hasLength(1 + 1));
      expect(o.unresolved, {0});
    });

    test('計算待ちが途中で終われば呼び直した結果で印を付ける', () async {
      final c = _Checker({4: ['h:same']})..pendingCalls = 2;
      final o = await _run(c, _Hasher(), [_src('a.jpg', 'same')]);
      expect(c.calls, hasLength(1 + 3));
      expect(o.flags.keys, [0]);
    });

    test('404 は未対応、それ以外の失敗は失敗として返す', () async {
      final c404 = _Checker({})..failWith = const ApiError(404, 'x');
      expect((await _run(c404, _Hasher(), [_src('a.jpg', 'x')])).status,
          UploadCheckStatus.unsupported);
      final c500 = _Checker({})..failWith = const ApiError(500, 'x');
      expect((await _run(c500, _Hasher(), [_src('a.jpg', 'x')])).status,
          UploadCheckStatus.failed);
    });

    test('読めなかったファイルは確かめられなかった物になる', () async {
      final h = _Hasher()..fail.add('a.jpg');
      final o = await _run(_Checker({4: ['h:same']}), h, [_src('a.jpg', 'same')]);
      expect(o.unresolved, {0});
      expect(o.flags, isEmpty);
    });
  });

  group('確認シート', () {
    late Future<int> result;

    Future<_UploadApp> openSheet(WidgetTester tester, _Checker checker,
        List<UploadSource> sources,
        {_Hasher? hasher, bool readOnly = false}) async {
      final app = _UploadApp(_CheckApi(checker), readOnly: readOnly);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => result = confirmAndUpload(
                  ctx, app, 'lib', sources,
                  hasher: (hasher ?? _Hasher()).call),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      // 照合中は輪が回り続けて落ち着かないので、決まった時間だけ進める
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      return app;
    }

    Future<void> pressUpload(WidgetTester tester) async {
      await tester.ensureVisible(find.text('アップロード'));
      await tester.tap(find.text('アップロード'));
      await tester.pumpAndSettle();
    }

    testWidgets('ライブラリにある物は既定でスキップされ、残りだけ上がる', (tester) async {
      final app = await openSheet(tester, _Checker({4: ['h:same']}),
          [_src('a.jpg', 'same'), _src('b.jpg', 'unique-content')]);
      expect(find.text('ライブラリに同じ物があります'), findsOneWidget);
      expect(find.text('old/same.jpg'), findsOneWidget);
      await pressUpload(tester);
      expect(await result, 1);
      expect(app.uploads.single.map((s) => s.name), ['b.jpg']);
      expect(find.text('同じ物 1件をスキップしました'), findsOneWidget);
    });

    testWidgets('「それでも上げる」を選ぶと上がり、計算済みのハッシュが付く', (tester) async {
      final app = await openSheet(tester, _Checker({4: ['h:same']}),
          [_src('a.jpg', 'same'), _src('b.jpg', 'unique-content')]);
      await tester.tap(find.text('それでも上げる'));
      await tester.pump();
      await pressUpload(tester);
      final up = app.uploads.single;
      expect(up.map((s) => s.name), ['a.jpg', 'b.jpg']);
      expect(up.map((s) => s.sha256), ['h:same', null]);
    });

    testWidgets('同じ選択の中で重なる物に印が付く', (tester) async {
      final app = await openSheet(tester, _Checker({}),
          [_src('a.jpg', 'dup1'), _src('b.jpg', 'dup1')]);
      expect(find.text('選んだ物の中に同じ物があります'), findsOneWidget);
      expect(find.text('同じ物: a.jpg'), findsOneWidget);
      await pressUpload(tester);
      expect(app.uploads.single.map((s) => s.name), ['a.jpg']);
    });

    testWidgets('照合が失敗しても止めずに上げ、確認できなかったと出す', (tester) async {
      final app = await openSheet(
          tester,
          _Checker({4: ['h:same']})..failWith = const ApiError(500, 'x'),
          [_src('a.jpg', 'same')]);
      expect(find.text('重複の確認ができませんでした'), findsOneWidget);
      await pressUpload(tester);
      expect(app.uploads.single.map((s) => s.name), ['a.jpg']);
    });

    testWidgets('古い Worker（404）では何も出さずに上げる', (tester) async {
      final app = await openSheet(
          tester,
          _Checker({})..failWith = const ApiError(404, 'x'),
          [_src('a.jpg', 'same')]);
      expect(find.textContaining('重複'), findsNothing);
      await pressUpload(tester);
      expect(app.uploads.single.map((s) => s.name), ['a.jpg']);
    });

    testWidgets('照合が終わる前に押しても全部上げ、確認できなかったと知らせる', (tester) async {
      final checker = _Checker({4: ['h:same']})..gate = Completer<void>();
      final app = await openSheet(tester, checker, [_src('a.jpg', 'same')]);
      expect(find.text('重複を確認中…'), findsOneWidget);
      await pressUpload(tester);
      expect(app.uploads.single.map((s) => s.name), ['a.jpg']);
      expect(find.text('重複の確認ができませんでした'), findsOneWidget);
      checker.gate!.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('一覧に出ない形式は除かれ、残りだけが上がる', (tester) async {
      final app = await openSheet(tester, _Checker({}),
          [_src('a.heic', 'x'), _src('b.jpg', 'y')]);
      await pressUpload(tester);
      expect(app.uploads.single.map((s) => s.name), ['b.jpg']);
      expect(find.text('一覧に出ない形式 1件を除きました'), findsOneWidget);
    });

    testWidgets('全部が一覧に出ない形式ならシートを出さずに知らせる', (tester) async {
      final app = _UploadApp(_CheckApi(_Checker({})));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () =>
                  result = confirmAndUpload(ctx, app, 'lib', [_src('a.heic', 'x')]),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pump();
      expect(await result, 0);
      expect(app.uploads, isEmpty);
      expect(find.text('一覧に出ない形式 1件を除きました'), findsOneWidget);
    });

    testWidgets('読み取り専用のライブラリでは照合しない', (tester) async {
      final checker = _Checker({});
      await openSheet(tester, checker, [_src('a.jpg', 'same')], readOnly: true);
      expect(checker.calls, isEmpty);
      expect(find.textContaining('重複'), findsNothing);
    });
  });

  group('転送キュー', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('r2g-dup-q-'));
    tearDown(() => tmp.delete(recursive: true));

    TransferQueue make(TransferApi api, {LedgerStore? ledger}) => TransferQueue(
          api: api,
          offline: OfflineStore(
              kv: _MemKv(), dir: () async => Directory('${tmp.path}/off')),
          ledger: ledger ?? _MemLedger(),
          stageDir: () async => Directory('${tmp.path}/stage'),
          persist: ledger != null,
          multipartThreshold: 8,
          partSize: 8,
        );

    Future<void> until(bool Function() cond) async {
      for (var i = 0; i < 300 && !cond(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(cond(), isTrue);
    }

    test('ハッシュは計算済みの単発PUTだけに添え、multipart には送らない', () async {
      final api = _RecordingTransferApi();
      final q = make(api);
      addTearDown(q.dispose);
      await q.restore();
      await q.enqueueUploads('lib', [
        _src('a.jpg', 'tiny').withSha256('h:a'),
        _src('b.jpg', 'tiny2'),
        _src('c.jpg', 'much longer than eight').withSha256('h:c'),
      ]);
      await until(() => q.tasks.every((t) => t.status == TransferStatus.done));
      expect(api.puts, {'a.jpg': 'h:a', 'b.jpg': null});
      expect(api.multiparts, ['c.jpg']);
    });

    test('台帳はハッシュを残し、ハッシュの無い古い行もそのまま読める', () async {
      final staged = File('${tmp.path}/staged.bin');
      await staged.writeAsBytes([1, 2, 3]);
      final ledger = _MemLedger()
        ..value = jsonEncode([
          {
            'id': 'u1', 'kind': 'up', 'lib': 'lib', 'name': 'old.jpg',
            'size': 3, 'mime': 'image/jpeg', 'status': 'paused',
            'stagedPath': staged.path,
          },
          {
            'id': 'u2', 'kind': 'up', 'lib': 'lib', 'name': 'new.jpg',
            'size': 3, 'mime': 'image/jpeg', 'status': 'paused',
            'stagedPath': staged.path, 'sha256': 'h:new',
          },
        ]);
      final q = make(_RecordingTransferApi(), ledger: ledger);
      addTearDown(q.dispose);
      await q.restore();
      expect(q.tasks.map((t) => t.sha256), [null, 'h:new']);
      expect(q.tasks.last.toLedger()['sha256'], 'h:new');
      expect(q.tasks.first.toLedger().containsKey('sha256'), isFalse);
    });
  });
}
