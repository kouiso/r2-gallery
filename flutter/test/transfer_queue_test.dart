import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/offline/offline_store.dart';
import 'package:r2_gallery/src/transfer/transfer_api.dart';
import 'package:r2_gallery/src/transfer/transfer_queue.dart';

/// worker と署名URLの配信を1つのローカルサーバーで真似る。本物の Dio で往復させる。
class FakeWorker {
  late final HttpServer server;
  String get base => 'http://127.0.0.1:${server.port}';

  final Map<String, Uint8List> objects = {};
  final Map<String, Uint8List> media = {};
  final Set<String> expired = {};
  final Map<String, Map<int, Uint8List>> _parts = {};
  final List<String> partsSeen = [];
  final List<String> partsRequested = [];
  int creates = 0;
  final List<String> aborts = [];
  int failPutStatus = 0;
  // このパート番号の PUT を返さずに止めておく（落とされる前の通信中を作る）
  int? holdPart;
  final Completer<void> holdRelease = Completer<void>();
  // このキーの単発 PUT を受け取ったまま返さずに止めておく（完了が重なる瞬間を作る）
  String? holdPutKey;
  final Completer<void> holdPutSeen = Completer<void>();
  final Completer<void> holdPutRelease = Completer<void>();
  // multipart の完了要求を受け取ったまま返さずに止めておく
  // 保存済みの中身を返す口を 500 にする（照合の読み出しが失敗する場面）
  bool failOpen = false;
  bool holdComplete = false;
  int completesSeen = 0;
  final Completer<void> holdCompleteSeen = Completer<void>();
  final Completer<void> holdCompleteRelease = Completer<void>();
  int _upload = 0;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) => _handle(r).catchError((Object _) {}));
  }

  Future<void> stop() => server.close(force: true);

  Future<Uint8List> _body(HttpRequest r) async {
    final b = BytesBuilder(copy: false);
    await for (final c in r) {
      b.add(c);
    }
    return b.takeBytes();
  }

  Future<void> _json(HttpRequest r, Object o, [int code = 200]) async {
    r.response.statusCode = code;
    r.response.headers.contentType = ContentType.json;
    r.response.write(jsonEncode(o));
    await r.response.close();
  }

  Future<void> _handle(HttpRequest r) async {
    final p = r.uri.path;
    if (p.startsWith('/m/')) {
      final name = p.substring(3);
      if (expired.contains(name) && r.uri.queryParameters['sig'] != 'fresh') {
        r.response.statusCode = 403;
        await r.response.close();
        return;
      }
      final data = media[name];
      if (data == null) {
        r.response.statusCode = 404;
        await r.response.close();
        return;
      }
      r.response.contentLength = data.length;
      r.response.add(data);
      await r.response.close();
      return;
    }
    if (p.startsWith('/o/')) {
      // objects の中身を署名URL越しに返す（保存済みの照合用）
      final data = objects[Uri.decodeComponent(p.substring(3))];
      if (failOpen) {
        r.response.statusCode = 500;
        await r.response.close();
        return;
      }
      if (data == null) {
        r.response.statusCode = 404;
        await r.response.close();
        return;
      }
      r.response.contentLength = data.length;
      r.response.add(data);
      await r.response.close();
      return;
    }
    if (r.headers.value('authorization') != 'Bearer tok') {
      r.response.statusCode = 401;
      await r.response.close();
      return;
    }
    final key = r.uri.queryParameters['key'];
    if (r.method == 'GET' && p == '/v1/libraries') {
      return _json(r, {
        'libraries': [
          {'id': 'lib', 'title': 'Lib'},
        ],
      });
    }
    if (r.method == 'GET' && p.endsWith('/folders')) {
      return _json(r, {
        'items': [
          for (final n in media.keys)
            {'key': n, 'type': 'image', 'url': '$base/m/$n?sig=fresh'},
          for (final e in objects.entries)
            {
              'key': e.key,
              'type': 'video',
              'size': e.value.length,
              'url': '$base/o/${Uri.encodeComponent(e.key)}',
            },
        ],
      });
    }
    if (r.method == 'PUT' && p.endsWith('/thumb')) {
      await _body(r);
      return _json(r, {});
    }
    if (r.method == 'PUT' && p.endsWith('/objects')) {
      final body = await _body(r);
      if (failPutStatus != 0) return _json(r, {'error': 'x'}, failPutStatus);
      if (key == holdPutKey) {
        if (!holdPutSeen.isCompleted) holdPutSeen.complete();
        await holdPutRelease.future;
      }
      if (objects.containsKey(key)) return _json(r, {'error': 'exists'}, 409);
      objects[key!] = body;
      return _json(r, {});
    }
    if (p.endsWith('/objects/multipart') && r.method == 'POST') {
      creates++;
      final b = jsonDecode(utf8.decode(await _body(r))) as Map<String, dynamic>;
      if (objects.containsKey(b['key'])) return _json(r, {'error': 'exists'}, 409);
      final id = 'up${++_upload}';
      _parts[id] = {};
      return _json(r, {'uploadId': id});
    }
    if (p.endsWith('/objects/multipart/part') && r.method == 'PUT') {
      final body = await _body(r);
      final n = int.parse(r.uri.queryParameters['part']!);
      partsRequested.add('${r.uri.queryParameters['uploadId']}#$n');
      if (holdPart == n) {
        await holdRelease.future;
        return;
      }
      final parts = _parts[r.uri.queryParameters['uploadId']];
      if (parts == null) return _json(r, {'error': 'no such upload'}, 404);
      parts[n] = body;
      partsSeen.add('${r.uri.queryParameters['uploadId']}#$n');
      return _json(r, {'partNumber': n, 'etag': 'e$n'});
    }
    if (p.endsWith('/objects/multipart/complete')) {
      final b = jsonDecode(utf8.decode(await _body(r))) as Map<String, dynamic>;
      completesSeen++;
      if (holdComplete) {
        if (!holdCompleteSeen.isCompleted) holdCompleteSeen.complete();
        await holdCompleteRelease.future;
      }
      // 本物の completeCreateOnly と同じく、完了の直前に同名があれば 409
      if (objects.containsKey(b['key'])) return _json(r, {'error': 'exists'}, 409);
      final parts = _parts[b['uploadId']]!;
      final all = BytesBuilder();
      for (final e in (b['parts'] as List)) {
        all.add(parts[(e as Map)['partNumber']]!);
      }
      objects[b['key'] as String] = all.takeBytes();
      return _json(r, {});
    }
    if (p.endsWith('/objects/multipart/abort')) {
      final b = jsonDecode(utf8.decode(await _body(r))) as Map<String, dynamic>;
      aborts.add(b['uploadId'] as String);
      return _json(r, {});
    }
    r.response.statusCode = 404;
    await r.response.close();
  }
}

class MemLedger implements LedgerStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String json) async => value = json;
}

/// 指定した条件の書き込みを 1 回だけ止めておける台帳（完了の書き込みが遅い端末を真似る）。
class GateLedger extends MemLedger {
  bool Function(String json)? holdWhen;
  final Completer<void> held = Completer<void>();
  final Completer<void> release = Completer<void>();
  @override
  Future<void> write(String json) async {
    final cond = holdWhen;
    if (cond != null && cond(json)) {
      holdWhen = null;
      held.complete();
      await release.future;
    }
    value = json;
  }
}

class MemKv implements SecretKv {
  final Map<String, String> values = {};
  @override
  Future<String?> get(String key) async => values[key];
  @override
  Future<void> set(String key, String value) async => values[key] = value;
}

Uint8List bytesOf(int n, [int seed = 3]) =>
    Uint8List.fromList(List.generate(n, (i) => (i * 7 + seed) & 0xff));

Future<void> until(bool Function() cond, {String? what}) async {
  for (var i = 0; i < 500; i++) {
    if (cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('timed out waiting for ${what ?? 'condition'}');
}

/// 退避ファイルの delete だけを遅らせる File。完了通知が掃除より先に出る順序を決定的に作る。
/// キューが使う操作だけ転送する（未対応の操作は noSuchMethod で落とし、黙って素通りさせない）。
class _SlowDeleteFile implements File {
  _SlowDeleteFile(this._inner, this.delay);
  final File _inner;
  final Duration delay;

  @override
  String get path => _inner.path;

  @override
  Future<bool> exists() => _inner.exists();

  @override
  Future<int> length() => _inner.length();

  @override
  IOSink openWrite({FileMode mode = FileMode.write, Encoding encoding = utf8}) =>
      _inner.openWrite(mode: mode, encoding: encoding);

  @override
  Future<Uint8List> readAsBytes() => _inner.readAsBytes();

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) =>
      _inner.open(mode: mode);

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    await Future<void>.delayed(delay);
    return _inner.delete(recursive: recursive);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _SlowDeleteOverrides extends IOOverrides {
  _SlowDeleteOverrides(this.delay);
  final Duration delay;

  @override
  File createFile(String path) => path.contains('/stage/')
      ? _SlowDeleteFile(super.createFile(path), delay)
      : super.createFile(path);
}

/// 退避ファイルの delete が永久に返らない File。掃除が止まった時も完了が報告されることを見る。
class _HangDeleteFile extends _SlowDeleteFile {
  _HangDeleteFile(File inner, this.never) : super(inner, Duration.zero);
  final Completer<void> never;

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    await never.future;
    return this;
  }
}

final class _HangDeleteOverrides extends IOOverrides {
  _HangDeleteOverrides(this.never);
  final Completer<void> never;

  @override
  File createFile(String path) => path.contains('/stage/')
      ? _HangDeleteFile(super.createFile(path), never)
      : super.createFile(path);
}

void main() {
  late FakeWorker w;
  late ApiClient api;
  late Directory tmp;
  late MemLedger ledger;
  late OfflineStore offline;
  final queues = <TransferQueue>[];

  TransferQueue make({
    int threshold = 1024,
    int part = 1024,
    Duration stagedDeleteTimeout = const Duration(seconds: 5),
  }) {
    final q = TransferQueue(
      api: ApiClientTransferApi(api),
      offline: offline,
      ledger: ledger,
      stageDir: () async => Directory('${tmp.path}/stage'),
      persist: true,
      multipartThreshold: threshold,
      partSize: part,
      netRetryDelay: const Duration(milliseconds: 50),
      stagedDeleteTimeout: stagedDeleteTimeout,
      configured: () => api.conn != null,
    );
    queues.add(q);
    return q;
  }

  Future<String> source(String name, Uint8List data) async {
    final f = File('${tmp.path}/picked-$name');
    await f.writeAsBytes(data);
    return f.path;
  }

  setUp(() async {
    w = FakeWorker();
    await w.start();
    api = ApiClient()..setConnection(Connection(w.base, 'tok'));
    tmp = await Directory.systemTemp.createTemp('r2g-queue-test-');
    ledger = MemLedger();
    offline = OfflineStore(
        kv: MemKv(), dir: () async => Directory('${tmp.path}/offline'));
  });

  tearDown(() async {
    if (!w.holdPutRelease.isCompleted) w.holdPutRelease.complete();
    if (!w.holdCompleteRelease.isCompleted) w.holdCompleteRelease.complete();
    for (final q in queues) {
      q.dispose();
    }
    queues.clear();
    if (!w.holdRelease.isCompleted) w.holdRelease.complete();
    await w.stop();
    await tmp.delete(recursive: true);
  });

  group('アップロード', () {
    test('選んだファイルは退避してから上がり、終わったら退避ファイルと台帳から消える', () async {
      final q = make();
      await q.restore();
      final data = bytesOf(500);
      final path = await source('a.jpg', data);
      await q.enqueueUploads('lib', [
        UploadSource(name: 'a.jpg', size: 500, mime: 'image/jpeg', path: path),
      ]);
      await until(() => q.tasks.single.status == TransferStatus.done);
      expect(w.objects['a.jpg'], data);
      expect(Directory('${tmp.path}/stage').listSync(), isEmpty);
      expect(jsonDecode(ledger.value!), isEmpty);
      // 元のファイルには触らない
      expect(File(path).existsSync(), isTrue);
    });

    test('完了を報告した時点で退避ファイルは消えている（掃除が遅くても）', () async {
      await IOOverrides.runWithIOOverrides(() async {
        final q = make();
        await q.restore();
        final path = await source('slow.jpg', bytesOf(500));
        await q.enqueueUploads('lib', [
          UploadSource(name: 'slow.jpg', size: 500, mime: 'image/jpeg', path: path),
        ]);
        await until(() => q.tasks.single.status == TransferStatus.done);
        expect(Directory('${tmp.path}/stage').listSync(), isEmpty);
      }, _SlowDeleteOverrides(const Duration(milliseconds: 300)));
    });

    test('退避ファイルの削除が返らなくても完了を報告し、残りは起動時の掃除に任せる', () async {
      final never = Completer<void>();
      await IOOverrides.runWithIOOverrides(() async {
        final q = make(stagedDeleteTimeout: const Duration(milliseconds: 100));
        await q.restore();
        final path = await source('hang.jpg', bytesOf(500));
        await q.enqueueUploads('lib', [
          UploadSource(name: 'hang.jpg', size: 500, mime: 'image/jpeg', path: path),
        ]);
        await until(() => q.tasks.single.status == TransferStatus.done);
        await q.idle();
        expect(q.hasActiveWork, isFalse);
        expect(jsonDecode(ledger.value!), isEmpty);
        // 消せなかったファイルは残る（起動時の掃除の対象）
        expect(Directory('${tmp.path}/stage').listSync(), isNotEmpty);
      }, _HangDeleteOverrides(never));
    });

    test('同名があれば「name (2)」で上げる', () async {
      w.objects['a.jpg'] = Uint8List(1);
      final q = make();
      await q.restore();
      await q.enqueueUploads('lib', [
        UploadSource(name: 'a.jpg', size: 3, mime: 'image/jpeg', bytes: bytesOf(3)),
      ]);
      await until(() => q.tasks.single.status == TransferStatus.done);
      expect(w.objects['a (2).jpg'], bytesOf(3));
    });

    test('大きいファイルは multipart で分けて上がる', () async {
      final q = make();
      await q.restore();
      final data = bytesOf(2500);
      await q.enqueueUploads('lib', [
        UploadSource(
            name: 'v.mp4', size: 2500, mime: 'video/mp4', path: await source('v.mp4', data)),
      ]);
      await until(() => q.tasks.single.status == TransferStatus.done);
      expect(w.objects['v.mp4'], data);
      expect(w.partsSeen, ['up1#1', 'up1#2', 'up1#3']);
    });

    test('アプリが落とされても、次の起動で続きのパートから上げ直す', () async {
      w.holdPart = 2;
      final first = make();
      await first.restore();
      final data = bytesOf(2500);
      await first.enqueueUploads('lib', [
        UploadSource(
            name: 'v.mp4', size: 2500, mime: 'video/mp4', path: await source('v.mp4', data)),
      ]);
      await until(() => w.partsSeen.contains('up1#1'), what: 'part 1');
      await until(() => (ledger.value ?? '').contains('"etag":"e1"'),
          what: 'part 1 in ledger');
      // プロセスごと消えた状態を作る（台帳と退避ファイルだけが残る）
      first.dispose();
      queues.remove(first);
      w.holdPart = null;

      final second = make();
      await second.restore();
      await until(() => second.tasks.single.status == TransferStatus.done,
          what: 'resumed upload');
      expect(w.objects['v.mp4'], data);
      // パート1は送り直さず、同じ uploadId の続きを送る
      expect(w.partsSeen.where((p) => p == 'up1#1'), hasLength(1));
      expect(w.partsSeen, containsAll(['up1#2', 'up1#3']));
      expect(w.creates, 1);
      expect(second.tasks.single.fromLedger, isTrue);
    });

    test('複数動画を連続して復元しても同じセッションで続きから送り、二重登録しない', () async {
      w.holdPart = 2;
      final first = make();
      await first.restore();
      final videos = {'a.mp4': bytesOf(2500), 'b.mp4': bytesOf(3100, 9)};
      await first.enqueueUploads('lib', [
        for (final entry in videos.entries)
          UploadSource(
            name: entry.key,
            size: entry.value.length,
            mime: 'video/mp4',
            path: await source(entry.key, entry.value),
          ),
      ]);
      await until(() =>
          w.partsRequested.contains('up1#2') &&
          w.partsRequested.contains('up2#2'));
      first.dispose();
      queues.remove(first);
      await first.idle();

      final second = make();
      await second.restore();
      await until(() =>
          w.partsRequested.where((p) => p == 'up1#2').length == 2 &&
          w.partsRequested.where((p) => p == 'up2#2').length == 2);
      second.dispose();
      queues.remove(second);
      await second.idle();

      w.holdPart = null;
      final third = make();
      final completed = <String>[];
      final sub = third.doneEvents.listen((t) => completed.add(t.name));
      await third.restore();
      await until(() => third.tasks.every((t) => t.status == TransferStatus.done));
      await third.idle();
      await until(() => completed.length == 2);
      await sub.cancel();

      expect(w.objects, videos);
      expect(w.creates, 2);
      expect(w.aborts, isEmpty);
      expect(w.partsSeen.where((p) => p == 'up1#1'), hasLength(1));
      expect(w.partsSeen.where((p) => p == 'up2#1'), hasLength(1));
      expect(completed, unorderedEquals(videos.keys));
      expect(jsonDecode(ledger.value!), isEmpty);
      expect(Directory('${tmp.path}/stage').listSync(), isEmpty);
    });

    test('一時停止は退避と確定パートを残し、再開で続きから送る', () async {
      w.holdPart = 2;
      final q = make();
      await q.restore();
      final data = bytesOf(2500);
      await q.enqueueUploads('lib', [
        UploadSource(
            name: 'v.mp4', size: 2500, mime: 'video/mp4', path: await source('v.mp4', data)),
      ]);
      await until(() => q.tasks.single.parts.isNotEmpty);
      q.pause(q.tasks.single.id);
      expect(q.tasks.single.status, TransferStatus.paused);
      await q.idle();
      expect(q.tasks.single.status, TransferStatus.paused);
      expect(q.tasks.single.parts.map((p) => p.partNumber), [1]);
      expect(jsonDecode(ledger.value!).single['status'], 'paused');

      w.holdPart = null;
      q.resume(q.tasks.single.id);
      await until(() => q.tasks.single.status == TransferStatus.done);
      expect(w.objects['v.mp4'], data);
      expect(w.creates, 1);
    });

    test('取り消すと multipart を片付け、退避ファイルと行を消す', () async {
      w.holdPart = 2;
      final q = make();
      await q.restore();
      await q.enqueueUploads('lib', [
        UploadSource(
            name: 'v.mp4',
            size: 2500,
            mime: 'video/mp4',
            path: await source('v.mp4', bytesOf(2500))),
      ]);
      await until(() => w.partsSeen.contains('up1#1'));
      await q.cancel(q.tasks.single.id);
      expect(q.tasks, isEmpty);
      expect(w.aborts, ['up1']);
      expect(Directory('${tmp.path}/stage').listSync(), isEmpty);
      expect(w.objects, isEmpty);
    });

    test('2 件の完了が重なっても、先に終わった行を台帳へ書き戻さない', () async {
      final gate = GateLedger();
      ledger = gate;
      // b（multipart）は完了要求で、a（単発）は PUT で止めておき、終わる順番を作る
      w.holdComplete = true;
      w.holdPutKey = 'a.jpg';
      final q = make();
      await q.restore();
      await q.enqueueUploads('lib', [
        UploadSource(
            name: 'a.jpg', size: 4, mime: 'image/jpeg',
            path: await source('a.jpg', bytesOf(4))),
        UploadSource(
            name: 'b.mp4', size: 2000, mime: 'video/mp4',
            path: await source('b.mp4', bytesOf(2000, 5))),
      ]);
      await w.holdPutSeen.future;
      await w.holdCompleteSeen.future;
      // a の完了の書き込み（a が抜けて b だけ残る中身）を止める
      gate.holdWhen = (json) =>
          !json.contains('"name":"a.jpg"') && json.contains('"name":"b.mp4"');
      w.holdPutRelease.complete();
      await gate.held.future;
      // a の書き込みが終わる前に b を終わらせる
      w.holdCompleteRelease.complete();
      await until(() => w.objects.containsKey('b.mp4'), what: 'b uploaded');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      gate.release.complete();
      final a = q.tasks.firstWhere((t) => t.name == 'a.jpg');
      final b = q.tasks.firstWhere((t) => t.name == 'b.mp4');
      await until(() =>
          a.status == TransferStatus.done && b.status == TransferStatus.done);
      await q.idle();
      expect(jsonDecode(gate.value!), isEmpty);
    });

    test('退避ファイルの削除中に別の行が台帳を書いても、完了待ちの行を転送中で書き戻さない', () async {
      await IOOverrides.runWithIOOverrides(() async {
        w.holdComplete = true;
        w.holdPutKey = 'a.jpg';
        final q = make();
        await q.restore();
        await q.enqueueUploads('lib', [
          UploadSource(
              name: 'a.jpg', size: 4, mime: 'image/jpeg',
              path: await source('a.jpg', bytesOf(4))),
          UploadSource(
              name: 'b.mp4', size: 2000, mime: 'video/mp4',
              path: await source('b.mp4', bytesOf(2000, 5))),
        ]);
        await w.holdPutSeen.future;
        await w.holdCompleteSeen.future;
        final a = q.tasks.firstWhere((t) => t.name == 'a.jpg');
        final b = q.tasks.firstWhere((t) => t.name == 'b.mp4');
        w.holdPutRelease.complete();
        // a が削除待ちに入ってから b の完了の書き込みを走らせる
        await until(() => a.stagedPath == null, what: 'a in staged delete');
        w.holdCompleteRelease.complete();
        await until(() =>
            a.status == TransferStatus.done && b.status == TransferStatus.done);
        await q.idle();
        expect(jsonDecode(ledger.value!), isEmpty);
        // 台帳から再起動しても送り直さない
        final r = make();
        await r.restore();
        await r.idle();
        expect(w.objects.keys.toSet(), {'a.jpg', 'b.mp4'});
      }, _SlowDeleteOverrides(const Duration(milliseconds: 500)));
    });

    test('同時に走るのは2件まで', () async {
      w.holdPart = 1;
      final q = make();
      await q.restore();
      await q.enqueueUploads('lib', [
        for (final n in ['a', 'b', 'c'])
          UploadSource(
              name: '$n.mp4', size: 2000, mime: 'video/mp4', bytes: bytesOf(2000)),
      ]);
      await until(() => w.creates == 2);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(w.creates, 2);
      expect(q.tasks.where((t) => t.status == TransferStatus.running), hasLength(2));
      expect(q.tasks.last.status, TransferStatus.queued);
    });

    test('元ファイルを退避できないまま落とされた行は、理由つきの失敗として戻す', () async {
      ledger.value = jsonEncode([
        {
          'id': 'u7',
          'kind': 'up',
          'lib': 'lib',
          'name': 'gone.jpg',
          'size': 10,
          'loaded': 0,
          'mime': 'image/jpeg',
          'status': 'running',
          'sourcePath': '${tmp.path}/does-not-exist.jpg',
        }
      ]);
      final q = make();
      await q.restore();
      expect(q.tasks.single.status, TransferStatus.error);
      expect(q.tasks.single.error, TransferQueue.lostSourceMessage);
      // 続けて積んでも id がぶつからない
      final added = await q.enqueueUploads('lib', [
        UploadSource(name: 'n.jpg', size: 1, mime: 'image/jpeg', bytes: bytesOf(1)),
      ]);
      expect(added.single.id, 'u8');
    });
  });

  group('接続の復旧', () {
    test('圏外では待機のまま始めず、回線が戻ると自動で上げる', () async {
      final q = make();
      await q.restore();
      q.setOnline(false);
      await q.enqueueUploads('lib', [
        UploadSource(name: 'a.jpg', size: 3, mime: 'image/jpeg', bytes: bytesOf(3)),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(q.tasks.single.status, TransferStatus.queued);
      expect(w.objects, isEmpty);
      q.setOnline(true);
      await until(() => q.tasks.single.status == TransferStatus.done);
      expect(w.objects['a.jpg'], bytesOf(3));
    });

    test('通信が切れたら失敗にせず待機に戻し、繋がれば続きをやる', () async {
      // 繋がらない先を向けておく
      final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = dead.port;
      await dead.close();
      api.setConnection(Connection('http://127.0.0.1:$deadPort', 'tok'));
      final q = make();
      await q.restore();
      await q.enqueueUploads('lib', [
        UploadSource(name: 'a.jpg', size: 3, mime: 'image/jpeg', bytes: bytesOf(3)),
      ]);
      await until(() =>
          q.tasks.single.status == TransferStatus.queued &&
          w.objects.isEmpty &&
          q.tasks.single.error == null);
      api.setConnection(Connection(w.base, 'tok'));
      q.wake();
      await until(() => q.tasks.single.status == TransferStatus.done);
      expect(w.objects['a.jpg'], bytesOf(3));
    });

    test('同名の大きいファイルを同時に上げても、2つとも保存される', () async {
      // 両方とも分割の開始は通り、完了の時に先着だけが残る（完了時の 409）
      w.holdComplete = true;
      final q = make();
      await q.restore();
      final a = bytesOf(2000, 1), b = bytesOf(2000, 9);
      await q.enqueueUploads('lib', [
        UploadSource(
            name: 'v.mp4', size: 2000, mime: 'video/mp4',
            path: await source('a-v.mp4', a)),
        UploadSource(
            name: 'v.mp4', size: 2000, mime: 'video/mp4',
            path: await source('b-v.mp4', b)),
      ]);
      await until(() => w.completesSeen >= 2, what: 'both complete requests');
      w.holdCompleteRelease.complete();
      await until(() => q.tasks.every((t) => t.status == TransferStatus.done),
          what: 'all done');
      await q.idle();
      expect(w.objects.keys.toSet(), {'v.mp4', 'v (2).mp4'});
      expect(w.objects.values.map((v) => v[0]).toSet(),
          {a[0], b[0]});
    });

    test('再開で、同名の別の中身がサーバーにあれば名前を変えて上げる', () async {
      w.objects['v.mp4'] = bytesOf(2000, 9);
      // 台帳には前回決めたキーと uploadId がある行（アプリが落ちた後を真似る）
      await ledger.write(jsonEncode([
        {
          'id': 't1', 'kind': 'up', 'lib': 'lib', 'name': 'v.mp4',
          'size': 2000, 'mime': 'video/mp4', 'status': 'running',
          'key': 'v.mp4', 'uploadId': 'gone',
          'stagedPath': await source('stage-v.mp4', bytesOf(2000, 1)),
        }
      ]));
      final q2 = make();
      await q2.restore();
      await until(
          () => q2.tasks.isNotEmpty &&
              q2.tasks.single.status == TransferStatus.done,
          what: 'done');
      await q2.idle();
      expect(w.objects['v.mp4'], bytesOf(2000, 9));
      expect(w.objects['v (2).mp4'], bytesOf(2000, 1));
    });

    test('再開で、サーバーにある物が手元と同じ中身なら重ねて上げずに完了にする', () async {
      w.objects['v.mp4'] = bytesOf(2000, 1);
      await ledger.write(jsonEncode([
        {
          'id': 't1', 'kind': 'up', 'lib': 'lib', 'name': 'v.mp4',
          'size': 2000, 'mime': 'video/mp4', 'status': 'running',
          'key': 'v.mp4',
          'stagedPath': await source('stage-v.mp4', bytesOf(2000, 1)),
        }
      ]));
      final q = make();
      await q.restore();
      await until(
          () => q.tasks.isNotEmpty && q.tasks.single.status == TransferStatus.done,
          what: 'done');
      await q.idle();
      expect(w.objects.keys.toList(), ['v.mp4']);
    });

    /// 台帳に残った1行（アプリが落とされた後）を作る。
    Future<void> ledgerRow({
      required String name,
      required int size,
      required String mime,
      required String staged,
      String? uploadId,
      int partCount = 0,
    }) =>
        ledger.write(jsonEncode([
          {
            'id': 't1', 'kind': 'up', 'lib': 'lib', 'name': name,
            'size': size, 'mime': mime, 'status': 'running',
            'key': name,
            'uploadId': ?uploadId,
            if (partCount > 0)
              'parts': [
                for (var n = 1; n <= partCount; n++)
                  {'partNumber': n, 'etag': 'e$n'}
              ],
            'stagedPath': staged,
          }
        ]));

    Future<TransferQueue> restored() async {
      final q = make();
      await q.restore();
      return q;
    }

    test('完了は通っていたが応答が落ちた行は、完了の 409 を中身の照合で完了にする', () async {
      // 前回の complete は R2 に届いて保存済み。全パート確定の台帳が残っている
      w.objects['v.mp4'] = bytesOf(2000, 1);
      await ledgerRow(
          name: 'v.mp4', size: 2000, mime: 'video/mp4', uploadId: 'up1',
          partCount: 2, staged: await source('stage-v.mp4', bytesOf(2000, 1)));
      final q = await restored();
      await until(() => q.tasks.single.status == TransferStatus.done, what: 'done');
      await q.idle();
      expect(w.objects.keys.toList(), ['v.mp4']);
      expect(w.creates, 0);
      expect(w.partsRequested, isEmpty);
    });

    test('完了の 409 で、サーバーの中身が別物なら名前を変えて最初から上げる', () async {
      w.objects['v.mp4'] = bytesOf(2000, 9);
      await ledgerRow(
          name: 'v.mp4', size: 2000, mime: 'video/mp4', uploadId: 'up1',
          partCount: 2, staged: await source('stage-v.mp4', bytesOf(2000, 1)));
      final q = await restored();
      await until(() => q.tasks.single.status == TransferStatus.done, what: 'done');
      await q.idle();
      expect(w.objects['v.mp4'], bytesOf(2000, 9));
      expect(w.objects['v (2).mp4'], bytesOf(2000, 1));
      expect(w.aborts, contains('up1'));
    });

    test('小さいファイルの再開で PUT が 409、同じ中身なら重ねずに完了にする', () async {
      w.objects['a.jpg'] = bytesOf(500, 1);
      await ledgerRow(
          name: 'a.jpg', size: 500, mime: 'image/jpeg',
          staged: await source('stage-a.jpg', bytesOf(500, 1)));
      final q = await restored();
      await until(() => q.tasks.single.status == TransferStatus.done, what: 'done');
      await q.idle();
      expect(w.objects.keys.toList(), ['a.jpg']);
    });

    test('小さいファイルの再開で PUT が 409、別の中身なら名前を変えて保存する', () async {
      w.objects['a.jpg'] = bytesOf(500, 9);
      await ledgerRow(
          name: 'a.jpg', size: 500, mime: 'image/jpeg',
          staged: await source('stage-a.jpg', bytesOf(500, 1)));
      final q = await restored();
      await until(() => q.tasks.single.status == TransferStatus.done, what: 'done');
      await q.idle();
      expect(w.objects['a.jpg'], bytesOf(500, 9));
      expect(w.objects['a (2).jpg'], bytesOf(500, 1));
    });

    test('照合の読み出しが失敗したら、完了にせず失敗の行として残す', () async {
      w.objects['v.mp4'] = bytesOf(2000, 1);
      w.failOpen = true;
      await ledgerRow(
          name: 'v.mp4', size: 2000, mime: 'video/mp4', uploadId: 'up1',
          partCount: 2, staged: await source('stage-v.mp4', bytesOf(2000, 1)));
      final q = await restored();
      await until(() => q.tasks.single.status == TransferStatus.error, what: 'error');
      expect(q.tasks.single.status, isNot(TransferStatus.done));
      expect(w.objects.keys.toList(), ['v.mp4']);
      // 退避ファイルは残り、読み出しが直れば再試行で完了にできる
      w.failOpen = false;
      q.retryAllFailed();
      await until(() => q.tasks.single.status == TransferStatus.done, what: 'retry done');
      expect(w.objects.keys.toList(), ['v.mp4']);
    });

    test('失敗した行は復帰時の再試行でまとめて積み直す', () async {
      w.failPutStatus = 500;
      final q = make();
      await q.restore();
      await q.enqueueUploads('lib', [
        UploadSource(name: 'a.jpg', size: 3, mime: 'image/jpeg', bytes: bytesOf(3)),
      ]);
      await until(() => q.tasks.single.status == TransferStatus.error);
      expect(q.tasks.single.error, contains('500'));
      w.failPutStatus = 0;
      q.retryAllFailed();
      await until(() => q.tasks.single.status == TransferStatus.done);
      expect(w.objects['a.jpg'], bytesOf(3));
    });
  });

  group('オフライン保存', () {
    test('取った中身を暗号化して端末に置き、復号すると元に戻る', () async {
      w.media['p.jpg'] = bytesOf(4000);
      final q = make();
      await q.restore();
      await q.enqueueDownloads('lib', [
        MediaItem(key: 'p.jpg', type: 'image', url: '${w.base}/m/p.jpg'),
      ]);
      await until(() => q.tasks.single.status == TransferStatus.done);
      expect(await offline.readBytes('lib', 'p.jpg'), bytesOf(4000));
      final blob = Directory('${tmp.path}/offline').listSync().single as File;
      expect(blob.readAsBytesSync().length, 12 + 4000 + 16);
      // 保存済みは積み直さない
      expect(
          await q.enqueueDownloads('lib', [
            MediaItem(key: 'p.jpg', type: 'image', url: '${w.base}/m/p.jpg'),
          ]),
          isEmpty);
    });

    test('署名URLが切れていたら一覧から取り直す', () async {
      w.media['p.jpg'] = bytesOf(100);
      w.expired.add('p.jpg');
      final q = make();
      await q.restore();
      await q.enqueueDownloads('lib', [
        MediaItem(key: 'p.jpg', type: 'image', url: '${w.base}/m/p.jpg?sig=old'),
      ]);
      await until(() => q.tasks.single.status == TransferStatus.done);
      expect(await offline.readBytes('lib', 'p.jpg'), bytesOf(100));
    });
  });
}
