import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/offline/offline_screen.dart';
import 'package:r2_gallery/src/offline/offline_store.dart';
import 'package:r2_gallery/src/state/app_state.dart';
import 'package:r2_gallery/src/store/kv.dart';
import 'package:r2_gallery/src/transfer/transfer_api.dart';
import 'package:r2_gallery/src/transfer/transfer_platform.dart';
import 'package:r2_gallery/src/transfer/transfer_queue.dart';
import 'package:r2_gallery/src/transfer/transfers_strip.dart';
import 'package:r2_gallery/src/transfer/upload_confirm.dart';
import 'package:r2_gallery/src/ui/home_shell.dart';
import 'package:r2_gallery/src/ui/import_browser_tab.dart';
import 'package:r2_gallery/src/ui/import_parts.dart';
import 'package:r2_gallery/src/ui/media_tile.dart';
import 'package:r2_gallery/src/ui/settings_tab.dart';
import 'package:r2_gallery/src/webdl/detected.dart';
import 'package:r2_gallery/src/webdl/web_transfer.dart';

import 'offline_store_test.dart' show MemKv;
import 'transfer_queue_test.dart' show FakeWorker, MemLedger, until;

class FakePlatform implements TransferPlatform {
  final List<bool> keepAlive = [];
  final StreamController<bool> net = StreamController<bool>.broadcast();
  @override
  Future<void> setKeepAlive(bool active) async => keepAlive.add(active);
  @override
  Stream<bool> get online => net.stream;
}

class _Api extends ApiClient {
  @override
  Future<FolderPage> folder(String libId,
          {String prefix = '', String? cursor, bool recursive = false}) async =>
      const FolderPage(items: [
        // 画像だと一覧がネットのサムネを読みに行くので、通信の要らない動画にする
        MediaItem(key: 'a.mp4', type: 'video', url: 'https://w.example/m/a.mp4'),
        MediaItem(key: 'b.mp4', type: 'video', url: 'https://w.example/m/b.mp4'),
      ]);
}

class _RetryUploadApi extends _Api {
  final Map<String, int> attempts = {};
  final Map<String, Uint8List> saved = {};

  _RetryUploadApi() {
    setConnection(const Connection('https://w.example', 'tok'));
  }

  @override
  Future<void> putObject(String libId, String key, Uint8List bytes,
      String contentType,
      {void Function(int sent, int total)? onProgress,
      CancelToken? cancelToken,
      bool verifyStorage = false}) async {
    final n = attempts.update(key, (n) => n + 1, ifAbsent: () => 1);
    if (key == 'retry.jpg' && n == 1) throw const ApiError(500, 'try again');
    saved[key] = Uint8List.fromList(bytes);
  }
}

class _QueueApp extends AppState {
  _QueueApp({
    required ApiClient api,
    required this.queue,
    required TransferPlatform platform,
    required OfflineStore offline,
  }) : super(
          api: api,
          bakedEndpoint: '',
          bakedToken: '',
          transferPlatform: platform,
          offline: offline,
        );

  final TransferQueue queue;

  @override
  TransferQueue get transfers => queue;
}

UploadSource _src(String name, int size, String mime) =>
    UploadSource(name: name, size: size, mime: mime, bytes: Uint8List(size));

/// 画面の外で進む非同期（秘密置き場の読み書きなど）を流し切る。
Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// 端末のファイル読み書きは本物の非同期で返り、続きは画面側の時計で進む。両方を交互に回して待つ。
Future<void> _io(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
  expect(done(), isTrue);
}

/// 1件目だけ一度 500 で落とし、残りは返さずに止めておく worker。
/// 失敗行と進行中・待機中の行が混ざった転送シートを、通信なしで作るため。
class _StuckApi implements TransferApi {
  final Set<String> failOnce;
  final Completer<void> gate = Completer<void>();
  final List<String> puts = [];
  _StuckApi(this.failOnce);

  @override
  Future<void> putObject(String lib, String key, Uint8List bytes, String mime,
      {CancelToken? cancelToken, void Function(int sent)? onProgress}) async {
    puts.add(key);
    if (failOnce.remove(key)) throw const ApiError(500, 'boom');
    await gate.future;
    throw const ApiError(0, 'stopped');
  }

  @override
  Future<String> multipartCreate(String lib, String key, String contentType) =>
      throw UnimplementedError();
  @override
  Future<UploadPart> putPart(
          String lib, String key, String uploadId, int part, Uint8List bytes,
          {CancelToken? cancelToken, void Function(int sent)? onProgress}) =>
      throw UnimplementedError();
  @override
  Future<void> multipartComplete(
          String lib, String key, String uploadId, List<UploadPart> parts) =>
      throw UnimplementedError();
  @override
  Future<void> multipartAbort(String lib, String key, String uploadId) async {}
  @override
  Future<void> putThumb(String lib, String key, Uint8List webp) async {}
  @override
  Future<Uint8List> fetchBytes(String url,
          {CancelToken? cancelToken,
          void Function(int got, int total)? onProgress}) =>
      throw UnimplementedError();
  @override
  Future<String?> itemUrl(String lib, String key) async => null;
}

/// 小さい端末（360x640dp）に、ステータスバーとナビゲーションバーの余白を付ける。
void _smallPhone(WidgetTester tester, {double textScale = 1.0}) {
  tester.view.physicalSize = const Size(360, 640);
  tester.view.devicePixelRatio = 1;
  tester.view.padding = const FakeViewPadding(top: 24, bottom: 48);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

/// 画面（キーボードを除いた見えている範囲）に丸ごと入っているか。
void _expectOnScreen(WidgetTester tester, Finder f, {double keyboard = 0}) {
  final r = tester.getRect(f);
  expect(r.top, greaterThanOrEqualTo(0), reason: '$r');
  expect(r.left, greaterThanOrEqualTo(0), reason: '$r');
  expect(r.right, lessThanOrEqualTo(360), reason: '$r');
  expect(r.bottom, lessThanOrEqualTo(640 - keyboard), reason: '$r');
}

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  late Directory tmp;
  late FakePlatform platform;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('r2g-ui-test-');
    platform = FakePlatform();
  });
  tearDown(() => tmp.delete(recursive: true));

  // アップロードの可否は #145 の書き込みガードで決まり、未接続だと止まるので接続済みから始める
  AppState makeApp({ApiClient? api, MemKv? kv}) => AppState(
        api: api ?? _Api(),
        bakedEndpoint: '',
        bakedToken: '',
        transferPlatform: platform,
        offline: OfflineStore(
            kv: kv ?? MemKv(), dir: () async => Directory('${tmp.path}/off')),
      )..connected = true;

  Widget confirmHost(AppState app, List<UploadSource> sources) => _wrap(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => confirmAndUpload(context, app, 'lib', sources),
            child: const Text('go'),
          ),
        ),
      );

  group('アップロード確認', () {
    testWidgets('保存先・合計サイズ・先頭3件を出し、押した時だけ積む', (tester) async {
      final app = makeApp()
        ..libraries = const [Library(id: 'lib', title: '家族の写真')];
      // 台帳の読み戻しは端末の口（path_provider など）を通るので、先に本物の非同期で済ませておく
      await tester.runAsync(app.transfers.restore);
      final sources = [
        _src('a.jpg', 1500000, 'image/jpeg'),
        _src('b.jpg', 1500000, 'image/jpeg'),
        _src('c.mp4', 2000000, 'video/mp4'),
        _src('d.png', 1000000, 'image/png'),
      ];
      await tester.pumpWidget(confirmHost(app, sources));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();

      expect(find.text('4件をアップロード'), findsOneWidget);
      expect(find.text('家族の写真'), findsOneWidget);
      expect(find.text('6.0 MB'), findsOneWidget);
      expect(find.text('a.jpg'), findsOneWidget);
      expect(find.text('c.mp4'), findsOneWidget);
      expect(find.text('d.png'), findsNothing);
      expect(find.text('ほか 1件'), findsOneWidget);
      // 確認前は何も積んでいない
      expect(app.transfers.tasks, isEmpty);

      await tester.tap(find.text('アップロード'));
      await tester.pumpAndSettle();
      await _drain(tester);
      expect(find.text('4件をアップロード'), findsNothing);
      expect(app.transfers.tasks.map((t) => t.name), ['a.jpg', 'b.jpg', 'c.mp4', 'd.png']);
      expect(app.transfers.tasks.every((t) => t.lib == 'lib' && t.isUpload), isTrue);
    });

    testWidgets('キャンセルすれば積まない', (tester) async {
      final app = makeApp()..libraries = const [Library(id: 'lib', title: 'Lib')];
      await tester.pumpWidget(confirmHost(app, [_src('a.jpg', 10, 'image/jpeg')]));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('キャンセル'));
      await tester.pumpAndSettle();
      expect(find.text('1件をアップロード'), findsNothing);
      expect(app.transfers.tasks, isEmpty);
    });

    testWidgets('読み取り専用のライブラリでは警告を出して押せない', (tester) async {
      final app = makeApp()
        ..libraries = const [Library(id: 'lib', title: 'Review', readOnly: true)];
      await tester.pumpWidget(confirmHost(app, [_src('a.jpg', 10, 'image/jpeg')]));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text('このライブラリは読み取り専用なので、アップロードできません。'), findsOneWidget);
      await tester.tap(find.text('アップロード'));
      await tester.pumpAndSettle();
      expect(find.text('1件をアップロード'), findsOneWidget);
      expect(app.transfers.tasks, isEmpty);
      // 画面を通さず呼ばれても、書き込めない保存先には積まない
      expect(await tester.runAsync(() => app.upload('lib', [_src('a.jpg', 1, 'image/jpeg')])), 0);
    });

    testWidgets('ライブラリが見つからない時も警告を出して押せない', (tester) async {
      final app = makeApp();
      await tester.pumpWidget(confirmHost(app, [_src('a.jpg', 10, 'image/jpeg')]));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text('保存先のライブラリが見つかりません。接続先を確認してください。'), findsOneWidget);
    });

    test('サイズが分からないものは「一部サイズ不明」と出す', () {
      final s = summarizeUpload([
        _src('a.jpg', 2000, 'image/jpeg'),
        const UploadSource(name: 'b.jpg', size: 0, mime: 'image/jpeg'),
      ]);
      expect(s.sizeText, '2 KB（一部サイズ不明）');
      expect(summarizeUpload([const UploadSource(name: 'b', size: 0, mime: 'x')]).sizeText,
          'サイズ不明');
    });
  });

  group('転送バーと転送シート', () {
    Future<AppState> appWithUpload(WidgetTester tester) async {
      final app = makeApp()..libraries = const [Library(id: 'lib', title: 'Lib')];
      // 接続していないので積んだまま待機に留まる（通信なしで行を作れる）
      await tester.runAsync(() => app.upload('lib', [_src('movie.mp4', 3000000, 'video/mp4')]));
      return app;
    }

    testWidgets('転送中の要約を下に出し、タップでシートを開いて一時停止・再開・取り消しできる', (tester) async {
      final app = await appWithUpload(tester);
      await tester.pumpWidget(_wrap(Align(
          alignment: Alignment.bottomCenter,
          child: TransfersDock(app: app, child: const SizedBox(height: 10)))));
      expect(find.text('アップロード中 1件'), findsOneWidget);
      expect(find.text('残り 3.0 MB'), findsOneWidget);

      await tester.tap(find.text('アップロード中 1件'));
      await tester.pumpAndSettle();
      expect(find.text('転送の状況'), findsOneWidget);
      expect(find.text('待機中 1'), findsOneWidget);
      expect(find.text('movie.mp4'), findsOneWidget);

      await tester.tap(find.byTooltip('一時停止'));
      await tester.pump();
      expect(find.text('一時停止中'), findsWidgets);
      expect(app.transfers.tasks.single.status, TransferStatus.paused);

      await tester.tap(find.byTooltip('再開'));
      await tester.pump();
      expect(app.transfers.tasks.single.status, TransferStatus.queued);
      expect(find.text('待機中'), findsOneWidget);

      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('取り消す'));
        await until(() => app.transfers.tasks.isEmpty);
      });
      await tester.pumpAndSettle();
      expect(find.text('転送はありません'), findsOneWidget);
      expect(find.text('アップロード中 1件'), findsNothing);
    });

    testWidgets('圏外の間は「オフライン（接続待ち）」と出す', (tester) async {
      final app = await appWithUpload(tester);
      app.transfers.setOnline(false);
      await tester.pumpWidget(_wrap(TransfersDock(app: app, child: const SizedBox())));
      expect(find.text('オフライン（接続待ち）'), findsOneWidget);
      await tester.tap(find.text('アップロード中 1件'));
      await tester.pumpAndSettle();
      expect(find.text('待機中（オフライン）'), findsOneWidget);
    });

    testWidgets('転送が無ければ何も出さない', (tester) async {
      final app = makeApp();
      await tester.pumpWidget(_wrap(TransfersDock(app: app, child: const Text('tabs'))));
      expect(find.text('tabs'), findsOneWidget);
      expect(find.byIcon(Icons.keyboard_arrow_up), findsNothing);
    });

    testWidgets('完了行が消えた後も失敗だけのバーから開いて再試行し、成功した行は再送しない',
        (tester) async {
      _smallPhone(tester, textScale: 1.3);
      final api = _RetryUploadApi();
      // キューは本物の非同期の側で作り、台帳は端末の口を通らんメモリ台帳にする。端末の口を通る台帳だと、
      // 完了行を消す時の書き込みがテストの時計の側で止まったままになり、やり直しの完了が待たされ続ける
      late final TransferQueue queue;
      await tester.runAsync(() async {
        queue = TransferQueue(
          api: ApiClientTransferApi(api),
          offline: OfflineStore(
              kv: MemKv(), dir: () async => Directory('${tmp.path}/off')),
          ledger: MemLedger(),
          stageDir: () async => Directory('${tmp.path}/stage'),
          configured: () => true,
        );
        await queue.restore();
      });
      final app = _QueueApp(
        api: api,
        queue: queue,
        platform: platform,
        offline: OfflineStore(
            kv: MemKv(), dir: () async => Directory('${tmp.path}/off')),
      )
        ..connected = true
        ..libraries = const [Library(id: 'lib', title: 'Lib')];
      addTearDown(() {
        queue.dispose();
        app.webQueue.dispose();
        app.dispose();
      });
      await tester.runAsync(() async {
        await app.upload('lib', [
          _src('done.jpg', 4, 'image/jpeg'),
          _src('retry.jpg', 5, 'image/jpeg'),
        ]);
        await app.transfers.idle();
      });
      expect(app.transfers.tasks.map((t) => t.status),
          [TransferStatus.done, TransferStatus.error]);
      await tester.pumpWidget(_wrap(Align(
        alignment: Alignment.bottomCenter,
        child: TransfersDock(app: app, child: const SizedBox(height: 10)),
      )));
      await tester.pump(TransfersStrip.finishedRowLife);
      await tester.pump();
      expect(app.transfers.tasks.single.name, 'retry.jpg');

      final entry = find.text('転送に失敗したものがあります');
      expect(entry.hitTestable(), findsOneWidget);
      await tester.tap(entry);
      // 進行中の行は進み具合が不定のバーを回し続けるので、settle を待たずにシートが開くまで進める
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('要対応 1'), findsOneWidget);
      expect(find.text('retry.jpg'), findsOneWidget);
      final retry = find.byTooltip('やり直す');
      expect(retry.hitTestable(), findsOneWidget);
      _expectOnScreen(tester, retry);

      await tester.runAsync(() => tester.tap(retry));
      // 送信は本物の非同期で進み、台帳の書き込みはテストの時計の側の続きも待つ。
      // 本物の時間を少し進めては pump して続きを流す
      for (var i = 0;
          i < 200 && app.transfers.tasks.single.status != TransferStatus.done;
          i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      await tester.pump(const Duration(seconds: 1));
      expect(app.transfers.tasks.single.status, TransferStatus.done);
      expect(api.attempts, {'done.jpg': 1, 'retry.jpg': 2});
      expect(api.saved['retry.jpg'], Uint8List(5));
      expect(find.text('要対応 1'), findsNothing);
      expect(entry, findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  // #106: 転送が何件あっても、取り込み画面の URL 入力欄を塞がない
  // #111: 先頭の失敗行の「やり直す」が画面内にあって押せ、その行だけをやり直す
  group('転送が多い時も操作を塞がない（#106 / #111）', () {
    testWidgets('アップロード6件と失敗1件があっても、取り込みの URL 欄はキーボードを出しても入力できる',
        (tester) async {
      _smallPhone(tester);
      final app = makeApp()
        ..libraries = const [Library(id: 'lib', title: 'Lib')]
        ..activeLib = 'lib';
      addTearDown(app.webQueue.dispose);
      // 接続先が無いので、積んだアップロードは待機のまま残る（通信なしで行を作れる）
      await tester.runAsync(() => app.upload('lib', [
            for (var i = 0; i < 6; i++) _src('p$i.jpg', 1000, 'image/jpeg'),
          ]));
      // 音声はギャラリーに出せないので、積んだその場で失敗の行になる
      app.webQueue.enqueue('lib', const [
        DetectedItem('https://cdn.example.com/a/song.mp3', DetectedKind.audio),
      ]);
      await tester.pumpWidget(MaterialApp(home: HomeShell(app: app, initialTab: HomeShell.photosTab)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('取り込み'));
      await tester.pumpAndSettle();
      expect(find.byType(ImportBrowserTab), findsOneWidget);

      // 転送バーは件数によらず1行の要約。個々の行は画面に並べない
      expect(find.text('アップロード中 6件'), findsOneWidget);
      expect(find.textContaining('失敗 1件'), findsOneWidget);
      expect(find.text('p0.jpg'), findsNothing);
      expect(tester.getSize(find.byType(TransfersStrip)).height, lessThan(64));

      final url = find.byType(TextField);
      expect(url.hitTestable(), findsOneWidget);
      _expectOnScreen(tester, url);
      final stripTop = tester.getRect(find.byType(TransfersStrip)).top;
      expect(tester.getRect(url).bottom, lessThan(stripTop));

      // キーボードを出しても URL 欄は見える範囲に残り、入力できる
      await tester.tap(url);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      expect(url.hitTestable(), findsOneWidget);
      _expectOnScreen(tester, url, keyboard: 300);
      await tester.enterText(url, 'example.com/video');
      expect(find.text('example.com/video'), findsOneWidget);

      // 詳細は転送バーから開ける（キーボードを閉じた状態で）
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pumpAndSettle();
      await tester.tap(find.text('アップロード中 6件'));
      await tester.pumpAndSettle();
      expect(find.text('転送の状況'), findsOneWidget);
      expect(find.text('要対応 1'), findsOneWidget);
      expect(find.text('song.mp3'), findsOneWidget);
    });

    for (final scale in [1.0, 1.3]) {
      testWidgets('先頭の失敗行の「やり直す」は小さい画面でも画面内で押せ、その行だけやり直す（文字 ${scale}x）',
          (tester) async {
        _smallPhone(tester, textScale: scale);
        final api = _StuckApi({'bad.jpg'});
        // キューは本物の非同期の側で作る。テストの時計の側で作ると、内部の Future.value の続きが
        // pump を待って止まる
        late final TransferQueue q;
        await tester.runAsync(() async {
          q = TransferQueue(
            api: api,
            offline: OfflineStore(
                kv: MemKv(), dir: () async => Directory('${tmp.path}/off')),
            ledger: MemLedger(),
            // 既定の置き場は path_provider を呼び、テストでは返ってこない
            stageDir: () async => Directory('${tmp.path}/stage'),
            persist: false,
          );
          await q.restore();
          await q.enqueueUploads('lib', [
            _src('bad.jpg', 10, 'image/jpeg'),
            for (var i = 0; i < 20; i++) _src('ok$i.jpg', 10, 'image/jpeg'),
          ]);
          await until(() => q.tasks.first.status == TransferStatus.error);
        });
        final web = WebTransferQueue(api: ApiClient());
        addTearDown(() {
          q.dispose();
          web.dispose();
        });
        final bad = q.tasks.first;
        expect(bad.name, 'bad.jpg');
        final before = {
          for (final t in q.tasks.skip(1)) t.id: t.status,
        };

        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) =>
                      TransfersSheetContent(queue: web, transfers: q),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ));
        await tester.tap(find.text('open'));
        // 進行中の行は進み具合が不定のバーを回し続けるので、settle を待たずにシートが開くまで進める
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));

        // 失敗は「要対応」として一番上に出る。行数が多くても先頭の操作は画面内にある
        expect(find.text('要対応 1'), findsOneWidget);
        expect(find.textContaining('失敗: HTTP 500'), findsOneWidget);
        final retry = find.byTooltip('やり直す');
        expect(retry, findsOneWidget);
        expect(retry.hitTestable(), findsOneWidget);
        _expectOnScreen(tester, retry);
        expect(tester.getRect(retry).top,
            lessThan(tester.getRect(find.text('進行中 2')).top));

        await tester.tap(retry);
        await tester.pump();
        // やり直した行だけが失敗から戻る（同時2件の枠は埋まっているので待機に入る）
        expect(bad.status, isNot(TransferStatus.error));
        expect(bad.error, isNull);
        expect({for (final t in q.tasks.skip(1)) t.id: t.status}, before);
        expect(find.text('要対応 1'), findsNothing);
      });
    }
  });

  group('オフライン保存', () {
    testWidgets('選択して「オフライン保存」を押すとキューに積み、保存済みには印が付く', (tester) async {
      final kv = MemKv();
      // 選択バーは写真タブではなくシェルが描く（#146）ので、接続済みのシェルごと出す
      final app = makeApp(kv: kv)
        ..connected = true
        ..libraries = const [Library(id: 'lib', title: 'L')]
        ..activeLib = 'lib';
      await tester.runAsync(app.transfers.restore);
      // b.mp4 は前に保存済み
      await tester.runAsync(() => app.offline.saveBytes(
          lib: 'lib', key: 'b.mp4', type: 'video', name: 'b.mp4', plain: Uint8List(4)));
      await tester.pumpWidget(MaterialApp(home: HomeShell(app: app, initialTab: HomeShell.photosTab)));
      await tester.pumpAndSettle();

      Finder tile(String key) =>
          find.byWidgetPredicate((w) => w is MediaTile && w.item.key == key);
      expect(find.descendant(of: find.byType(Stack), matching: find.byType(OfflineBadge)),
          findsOneWidget);
      expect(find.ancestor(of: tile('b.mp4'), matching: find.byType(Stack)), findsWidgets);

      await tester.longPress(tile('a.mp4'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('オフライン'));
      await _drain(tester);
      await tester.pump();
      expect(find.text('1件をオフライン保存に追加しました'), findsOneWidget);
      final t = app.transfers.tasks.single;
      expect(t.kind, 'down');
      expect(t.itemKey, 'a.mp4');
    });

    testWidgets('設定に件数を出し、すべて削除できる', (tester) async {
      final app = makeApp();
      await tester.runAsync(() async {
        for (final k in ['a.jpg', 'b.jpg']) {
          await app.offline.saveBytes(
              lib: 'lib', key: k, type: 'image', name: k, plain: Uint8List(4));
        }
      });
      await tester.pumpWidget(_wrap(SettingsTab(app: app)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      expect(find.text('2件'), findsOneWidget);

      await tester.tap(find.text('オフライン保存をすべて削除'));
      await tester.pumpAndSettle();
      expect(find.text('端末に保存した 2 件を削除します。サーバー上の写真・動画は消えません。'),
          findsOneWidget);
      await tester.tap(find.text('削除'));
      await _io(tester, () => find.text('0件').evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      expect(find.text('0件'), findsOneWidget);
      expect(Directory('${tmp.path}/off').listSync(), isEmpty);
    });

    testWidgets('保存した写真は回線なしで一覧から開ける', (tester) async {
      final app = makeApp(api: ApiClient());
      final png = Uint8List.fromList([
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0x0d, 0x49,
        0x48, 0x44, 0x52, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 0x1f, 0x15,
        0xc4, 0x89, 0, 0, 0, 0x0a, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63,
        0, 1, 0, 0, 5, 0, 1, 0x0d, 0x0a, 0x2d, 0xb4, 0, 0, 0, 0, 0x49, 0x45,
        0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
      ]);
      await tester.runAsync(() => app.offline.saveBytes(
          lib: 'lib', key: 'p/dot.png', type: 'image', name: 'dot.png', plain: png));
      await tester.pumpWidget(MaterialApp(home: OfflineListScreen(app: app)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      expect(find.text('dot.png'), findsOneWidget);

      await tester.tap(find.text('dot.png'));
      await _io(tester, () => find.byType(Image).evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      final img = tester.widget<Image>(find.byType(Image));
      expect(img.image, isA<MemoryImage>());
      expect((img.image as MemoryImage).bytes, png);
    });
  });

  group('AppState のつなぎ', () {
    late FakeWorker w;
    setUp(() async {
      // 画面テスト用の束ねは HTTP を全部 400 にする。ここは本物の通信でローカルの偽 worker と往復させる
      HttpOverrides.global = null;
      w = FakeWorker();
      await w.start();
      FlutterSecureStorage.setMockInitialValues({
        Keys.endpoint: w.base,
        Keys.token: 'tok',
      });
    });
    tearDown(() async {
      if (!w.holdRelease.isCompleted) w.holdRelease.complete();
      await w.stop();
    });

    test('失敗したアップロードはアプリへの復帰で積み直され、転送中だけサービスを張る', () async {
      final app = makeApp(api: ApiClient());
      await app.init();
      app.unlock();
      await until(() => app.libraries.isNotEmpty);
      w.failPutStatus = 500;
      expect(await app.upload('lib', [_src('a.jpg', 5, 'image/jpeg')]), 1);
      await until(() => app.transfers.tasks.single.status == TransferStatus.error);
      expect(platform.keepAlive, [true, false]);

      w.failPutStatus = 0;
      app.onBackground();
      await app.onForeground();
      await until(() => app.transfers.tasks.single.status == TransferStatus.done);
      expect(w.objects['a.jpg'], Uint8List(5));
      expect(platform.keepAlive, [true, false, true, false]);
    });

    test('回線の知らせで待機と再開が切り替わる', () async {
      final app = makeApp(api: ApiClient());
      await app.init();
      app.unlock();
      await until(() => app.libraries.isNotEmpty);
      platform.net.add(false);
      await until(() => !app.transfers.online);
      expect(await app.upload('lib', [_src('a.jpg', 5, 'image/jpeg')]), 1);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(app.transfers.tasks.single.status, TransferStatus.queued);
      expect(w.objects, isEmpty);
      platform.net.add(true);
      await until(() => app.transfers.tasks.single.status == TransferStatus.done);
    });
  });
}
