import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/offline/offline_playback_files.dart';
import 'package:r2_gallery/src/offline/offline_screen.dart';
import 'package:r2_gallery/src/offline/offline_store.dart';
import 'package:r2_gallery/src/state/app_state.dart';
import 'package:r2_gallery/src/viewer/screen_awake.dart';

import 'offline_store_test.dart' show MemKv;
import 'support/fake_video.dart';
import 'support/fake_playback.dart';
import 'package:r2_gallery/src/playback/playback_session.dart';

class _DelayedKv extends MemKv {
  bool holdManifest = false;
  final release = Completer<String?>();
  @override
  Future<String?> get(String key) {
    if (holdManifest && key.startsWith('${OfflineStore.manifestKey}.account.')) {
      return release.future;
    }
    return super.get(key);
  }
}

class _App extends AppState {
  _App(this.base) : super(api: ApiClient(), bakedEndpoint: '', bakedToken: '', offline: base);
  final OfflineStore base;
  String scope = 'account-A';
  bool authorized = true;
  Completer<void>? foregroundGate;
  Completer<void>? bytesSeen;
  Completer<void>? bytesRelease;
  @override
  Future<void> get foregroundSettled => foregroundGate?.future ?? Future<void>.value();
  @override
  OfflineStore get offline => base.forAccount(scope);
  @override
  String? get offlineAccountId => scope;
  @override
  bool get offlineAccessible => authorized && !locked;
  @override
  bool canReadOffline(String lib) => offlineAccessible && lib == 'lib';
  @override
  Future<Uint8List?> offlineBytes(String lib, String key) async {
    final bytes = canReadOffline(lib) ? await offline.readBytes(lib, key) : null;
    if (bytesSeen != null && !bytesSeen!.isCompleted) bytesSeen!.complete();
    await bytesRelease?.future;
    return bytes;
  }
  void change({String? account, bool? allow}) {
    scope = account ?? scope;
    authorized = allow ?? authorized;
    notifyListeners();
  }
}

class _InitializingVideo extends FakeVideo {
  final gate = Completer<void>();
  bool initializing = false;
  @override
  Future<void> initialize() async {
    initializing = true;
    await gate.future;
    if (!disposed) await super.initialize();
  }
}

class _AwakeDriver implements ScreenAwakeDriver {
  int acquires = 0;
  int releases = 0;
  @override
  bool get visible => true;
  @override
  Stream<ScreenAwakeEvent> get events => const Stream.empty();
  @override
  Future<ScreenAwakeStatus> acquire() async {
    acquires++;
    return ScreenAwakeStatus.held;
  }
  @override
  Future<void> release() async { releases++; }
  @override
  void dispose() {}
}

Future<void> _io(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
  expect(done(), isTrue);
}

Future<void> _awakeSettled(WidgetTester tester, ScreenAwakeCoordinator awake) async {
  // 実 I/O と仮想時間の両方から来る完了通知を、どちらの zone も進めて待つ。
  var done = false;
  awake.settled.then((_) => done = true);
  await _io(tester, () => done);
}

void main() {
  late Directory temp;
  late Directory playback;
  late _App app;
  late OfflinePlaybackFiles files;
  late OfflineRef item;
  late _DelayedKv kv;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('r2g-offline-privacy-test-');
    playback = await Directory('${temp.path}/private-playback').create();
    files = OfflinePlaybackFiles(root: () async => playback);
    kv = _DelayedKv();
    app = _App(OfflineStore(kv: kv, dir: () async => Directory('${temp.path}/encrypted')));
    await app.offline.saveBytes(lib: 'lib', key: 'clip.mp4', type: 'video',
        name: 'private-fixture.mp4', plain: Uint8List.fromList([1, 2, 3]));
    item = (await app.offline.list()).single;
  });

  tearDown(() async {
    app.dispose();
    await temp.delete(recursive: true);
  });

  testWidgets('管理下の保存動画も同じdecoderで背景再生し、接続取消で平文とOS操作を解放する', (tester) async {
    app.connected = true;
    app.deviceLockEnabled = false;
    app.hasPin = false;
    final port = FakePlaybackPort();
    final owner = PlaybackCoordinator(port);
    final video = FakeVideo();
    await tester.pumpWidget(MaterialApp(home: OfflineViewer(
      app: app, item: item, playbackFiles: files, controllerFactory: (_) => video,
      playbackCoordinator: owner,
    )));
    await _io(tester, () => video.value.isPlaying);
    final session = owner.current!;
    expect(session.controller, same(video));
    await session.setBackgroundAllowed(true);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(video.value.isPlaying, isTrue);
    expect(playback.listSync(), hasLength(1));
    await session.seek(const Duration(seconds: 36));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(video.value.position, const Duration(seconds: 36));
    app.change(account: 'account-B');
    await _io(tester, () => video.disposed && playback.listSync().isEmpty);
    expect(port.bound, isNull);
    expect(port.focus, isFalse);
    expect(owner.current, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final all in [false, true]) {
    testWidgets('${all ? "全件削除" : "1件削除"}は再生中の平文・OS操作も解放し、別接続や旧保存を消さない', (tester) async {
      app.connected = true;
      app.deviceLockEnabled = false;
      app.hasPin = false;
      final other = app.base.forAccount('account-B');
      for (final store in [other, app.base]) {
        await tester.runAsync(() => store.saveBytes(lib: 'lib', key: 'other.jpg',
          type: 'image', name: 'other.jpg', plain: Uint8List.fromList([9])));
      }
      final existing = File('${temp.path}/existing-export-fixture.jpg');
      await tester.runAsync(() => existing.writeAsBytes([8]));
      final port = FakePlaybackPort();
      final owner = PlaybackCoordinator(port);
      final video = FakeVideo();
      await tester.pumpWidget(MaterialApp(home: OfflineViewer(
        app: app, item: item, playbackFiles: files, controllerFactory: (_) => video,
        playbackCoordinator: owner,
      )));
      await _io(tester, () => video.value.isPlaying);
      final session = owner.current!;
      await session.setBackgroundAllowed(true);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      await tester.runAsync(() => all ? app.offline.clear() : app.offline.remove(item.lib, item.key));
      await _io(tester, () => video.disposed && playback.listSync().isEmpty);
      expect(port.bound, isNull);
      expect(port.focus, isFalse);
      expect(await tester.runAsync(app.offline.count), 0);
      expect(await tester.runAsync(other.count), 1);
      expect(await tester.runAsync(app.base.count), 1);
      expect(await tester.runAsync(existing.readAsBytes), [8]);
      expect(session.closed, isTrue);
      await session.play();
      expect(video.plays, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('初期化中に閉じても平文を残さず、遅れて再生しない', (tester) async {
    final video = _InitializingVideo();
    await tester.pumpWidget(MaterialApp(home: OfflineViewer(
      app: app, item: item, playbackFiles: files, controllerFactory: (_) => video,
    )));
    await _io(tester, () => video.initializing);
    await tester.pumpWidget(const SizedBox.shrink());
    await _io(tester, () => playback.listSync().isEmpty && video.disposed);
    video.gate.complete();
    await tester.pump();
    expect(video.plays, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('非同期復号の結果待ちで接続が変わったら平文cacheもdecoderも作らない', (tester) async {
    app.bytesSeen = Completer<void>();
    app.bytesRelease = Completer<void>();
    var controllers = 0;
    await tester.pumpWidget(MaterialApp(home: OfflineViewer(
      app: app, item: item, playbackFiles: files, controllerFactory: (_) {
        controllers++;
        return FakeVideo();
      },
    )));
    await _io(tester, () => app.bytesSeen!.isCompleted);
    app.change(account: 'account-B');
    app.bytesRelease!.complete();
    await tester.pump();
    await tester.pump();
    expect(controllers, 0);
    expect(playback.listSync(), isEmpty);
    expect(find.textContaining('同じ接続'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('再生初期化に失敗したら平文と再生器を片付け、内部パスを表示しない', (tester) async {
    final video = FakeVideo(failInit: true);
    await tester.pumpWidget(MaterialApp(home: OfflineViewer(
      app: app, item: item, playbackFiles: files, controllerFactory: (_) => video,
    )));
    await _io(tester, () => find.text('再生できませんでした').evaluate().isNotEmpty);
    expect(playback.listSync(), isEmpty);
    expect(video.disposed, isTrue);
    expect(find.textContaining(temp.path), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('バックグラウンドで初期化が終わっても再生を始めない', (tester) async {
    addTearDown(() => tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));
    final video = _InitializingVideo();
    final driver = _AwakeDriver();
    final awake = ScreenAwakeCoordinator(driver);
    addTearDown(awake.dispose);
    await tester.pumpWidget(MaterialApp(home: OfflineViewer(
      app: app, item: item, playbackFiles: files, controllerFactory: (_) => video,
      screenAwake: awake,
    )));
    await _io(tester, () => video.initializing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    video.gate.complete();
    await _io(tester, () => video.value.isInitialized);
    expect(video.plays, 0);
    expect(video.value.isPlaying, isFalse);
    await _awakeSettled(tester, awake);
    expect(driver.acquires, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(video.plays, 0);
    expect(driver.acquires, 0);
    await tester.tap(find.byKey(const ValueKey('offline-video-playback')));
    await tester.pump();
    expect(video.plays, 1);
    await _awakeSettled(tester, awake);
    expect(driver.acquires, 1);
    await tester.tap(find.byKey(const ValueKey('offline-video-playback')));
    await tester.pump();
    await _awakeSettled(tester, awake);
    expect(driver.releases, 1);
    await tester.tap(find.byKey(const ValueKey('offline-video-playback')));
    await tester.pump();
    await _awakeSettled(tester, awake);
    expect(driver.acquires, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    await _awakeSettled(tester, awake);
    expect(driver.releases, 2);
    await _io(tester, () => playback.listSync().isEmpty);
    awake.dispose();
    await _awakeSettled(tester, awake);
  });

  testWidgets('復帰のロック判定中にロックされたら再開しない', (tester) async {
    addTearDown(() => tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));
    final video = FakeVideo();
    await tester.pumpWidget(MaterialApp(home: OfflineViewer(
      app: app, item: item, playbackFiles: files, controllerFactory: (_) => video,
    )));
    await _io(tester, () => video.plays == 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(video.value.isPlaying, isFalse);
    app.foregroundGate = Completer<void>();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(video.plays, 1);
    app.locked = true;
    app.change();
    app.foregroundGate!.complete();
    await tester.pump();
    await _io(tester, () => video.disposed && playback.listSync().isEmpty);
    expect(video.plays, 1);
    expect(find.text('private-fixture.mp4'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('復帰待ち中の手動停止を後から自動再生で上書きしない', (tester) async {
    addTearDown(() => tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));
    final video = FakeVideo();
    await tester.pumpWidget(MaterialApp(home: OfflineViewer(
      app: app, item: item, playbackFiles: files, controllerFactory: (_) => video,
    )));
    await _io(tester, () => video.plays == 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    app.foregroundGate = Completer<void>();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('offline-video-playback')));
    app.foregroundGate!.complete();
    await tester.pump();
    expect(video.plays, 1);
    expect(video.value.isPlaying, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await _io(tester, () => playback.listSync().isEmpty);
  });

  for (final event in ['account', 'lock']) {
    testWidgets('$event 変更で作品名と復号データを隠し、動画の平文を削除する', (tester) async {
      final video = FakeVideo();
      await tester.pumpWidget(MaterialApp(home: OfflineViewer(
        app: app, item: item, playbackFiles: files, controllerFactory: (_) => video,
      )));
      await _io(tester, () => video.plays == 1);
      if (event == 'account') {
        app.change(account: 'account-B');
      } else {
        app.change(allow: false);
      }
      await tester.pump();
      await _io(tester, () => playback.listSync().isEmpty && video.disposed);
      expect(find.text('private-fixture.mp4'), findsNothing);
      expect(find.text('アプリ内の保存'), findsOneWidget);
      expect(find.text('保存を開くには同じ接続とロック解除が必要です'), findsOneWidget);
      if (event == 'account') {
        expect(await tester.runAsync(() => app.offline.list()), isEmpty);
      }
      app.change(account: 'account-A', allow: true);
      await tester.pump();
      expect(video.plays, 1);
      expect(await tester.runAsync(() => app.offline.readBytes('lib', 'clip.mp4')), [1, 2, 3]);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('別アカウントと未所属のrefからは動画を初期化しない', (tester) async {
    final video = FakeVideo();
    app.change(account: 'account-B');
    await tester.pumpWidget(MaterialApp(home: OfflineViewer(
      app: app, item: item, playbackFiles: files, controllerFactory: (_) => video,
    )));
    await tester.pump();
    expect(video.plays, 0);
    expect(playback.listSync(), isEmpty);
    expect(find.text('private-fixture.mp4'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    app.change(account: 'account-A');
    await tester.pumpWidget(MaterialApp(home: OfflineViewer(
      app: app, item: OfflineRef(item.lib, item.key, item.entry),
      playbackFiles: files, controllerFactory: (_) => video,
    )));
    await tester.pump();
    expect(video.plays, 0);
    expect(playback.listSync(), isEmpty);
    expect(find.text('private-fixture.mp4'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await video.dispose();
  });

  testWidgets('新しい接続の読み込みを待つ間にも古い接続の一覧を見せない', (tester) async {
    await tester.pumpWidget(MaterialApp(home: OfflineListScreen(app: app)));
    await _io(tester, () => find.text('private-fixture.mp4').evaluate().isNotEmpty);
    expect(find.text('private-fixture.mp4'), findsOneWidget);
    kv.holdManifest = true;
    app.change(account: 'account-B');
    await tester.pump();
    expect(find.text('private-fixture.mp4'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    kv.release.complete(null);
    await _io(tester, () => find.text('オフライン保存はまだありません').evaluate().isNotEmpty);
    expect(find.text('オフライン保存はまだありません'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
