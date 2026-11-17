import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/state/app_state.dart';
import 'package:r2_gallery/src/ui/app_lock_layer.dart';
import 'package:r2_gallery/src/ui/video_view.dart';
import 'package:r2_gallery/src/viewer/screen_awake.dart';
import 'package:r2_gallery/src/viewer/screen_awake_native.dart';

import 'support/fake_video.dart';

class _Driver implements ScreenAwakeDriver {
  final changes = StreamController<ScreenAwakeEvent>.broadcast(sync: true);
  final operations = <String>[];
  ScreenAwakeStatus result = ScreenAwakeStatus.held;
  Completer<ScreenAwakeStatus>? acquireGate;
  Completer<void>? releaseGate;
  bool failRelease = false;
  @override
  bool visible = true;
  @override
  Stream<ScreenAwakeEvent> get events => changes.stream;
  int get acquires => operations.where((v) => v == 'acquire').length;
  int get releases => operations.where((v) => v == 'release').length;

  @override
  Future<ScreenAwakeStatus> acquire() async {
    operations.add('acquire');
    return acquireGate?.future ?? Future.value(result);
  }
  @override
  Future<void> release() async {
    operations.add('release');
    if (failRelease) throw StateError('fixture release failure');
    await releaseGate?.future;
  }
  void visibility(bool value) {
    visible = value;
    changes.add(ScreenAwakeEvent.visibilityChanged);
  }
  void revoke() => changes.add(ScreenAwakeEvent.released);
  @override
  void dispose() { unawaited(changes.close()); }
}

void main() {
  group('画面保持の要求と Web の解放・再取得', () {
    late _Driver driver;
    late ScreenAwakeCoordinator coordinator;
    setUp(() {
      driver = _Driver();
      coordinator = ScreenAwakeCoordinator(driver);
    });
    tearDown(() async {
      coordinator.dispose();
      await coordinator.settled;
    });

    test('再生要求がある時だけ一度取得し、反復通知では取り直さない', () async {
      final lease = coordinator.lease();
      lease.setEnabled(true);
      await coordinator.settled;
      for (var n = 0; n < 20; n++) { lease.setEnabled(true); }
      await coordinator.settled;
      expect(coordinator.status, ScreenAwakeStatus.held);
      expect(driver.acquires, 1);
      lease.setEnabled(false);
      await coordinator.settled;
      expect(driver.releases, 1);
      expect(coordinator.status, ScreenAwakeStatus.released);
    });

    for (final result in [ScreenAwakeStatus.unsupported, ScreenAwakeStatus.denied,
        ScreenAwakeStatus.failed]) {
      test('$result を成功と扱わず、拒否後に進捗通知で要求を連打しない', () async {
        driver.result = result;
        final lease = coordinator.lease();
        lease.setEnabled(true);
        await coordinator.settled;
        expect(coordinator.status, result);
        for (var n = 0; n < 20; n++) { lease.setEnabled(true); }
        await coordinator.settled;
        expect(driver.acquires, 1);
        lease.setEnabled(false);
        lease.setEnabled(true);
        await coordinator.settled;
        expect(driver.acquires, 2);
      });
    }

    test('OS による解放は尊重し、非表示から表示へ戻った時に新しく取得する', () async {
      final lease = coordinator.lease()..setEnabled(true);
      await coordinator.settled;
      driver.revoke();
      await coordinator.settled;
      expect(coordinator.status, ScreenAwakeStatus.released);
      expect(driver.acquires, 1);
      lease.setEnabled(true);
      await coordinator.settled;
      expect(driver.acquires, 1);
      driver.visibility(false);
      await coordinator.settled;
      driver.visibility(true);
      await coordinator.settled;
      expect(driver.acquires, 2);
      expect(coordinator.status, ScreenAwakeStatus.held);
    });

    test('一時停止したまま可視化しても再取得しない', () async {
      final lease = coordinator.lease()..setEnabled(true);
      await coordinator.settled;
      driver.visibility(false);
      await coordinator.settled;
      lease.setEnabled(false);
      driver.visibility(true);
      await coordinator.settled;
      expect(driver.acquires, 1);
      expect(driver.releases, 1);
    });

    test('取得待ちの間に退出したら、遅れて届いた保持を直ちに解放する', () async {
      final gate = Completer<ScreenAwakeStatus>();
      driver.acquireGate = gate;
      final lease = coordinator.lease()..setEnabled(true);
      await Future<void>.value();
      expect(driver.acquires, 1);
      lease.dispose();
      gate.complete(ScreenAwakeStatus.held);
      await coordinator.settled;
      expect(driver.releases, 1);
      expect(coordinator.status, ScreenAwakeStatus.released);
    });

    test('新しい動画の要求を、古い画面の dispose で解除しない', () async {
      final first = coordinator.lease()..setEnabled(true);
      await coordinator.settled;
      final second = coordinator.lease()..setEnabled(true);
      first.dispose();
      await coordinator.settled;
      expect(driver.operations, ['acquire']);
      second.dispose();
      await coordinator.settled;
      expect(driver.operations, ['acquire', 'release']);
    });

    test('古い解放が処理中でも、新しい取得はその後に行う', () async {
      final first = coordinator.lease()..setEnabled(true);
      await coordinator.settled;
      final gate = Completer<void>();
      driver.releaseGate = gate;
      first.dispose();
      await Future<void>.value();
      final second = coordinator.lease()..setEnabled(true);
      gate.complete();
      await coordinator.settled;
      expect(driver.operations, ['acquire', 'release', 'acquire']);
      expect(coordinator.status, ScreenAwakeStatus.held);
      second.dispose();
    });

    test('解放失敗を成功と扱わず、次の再生要求が内部の held に取り残されない', () async {
      final lease = coordinator.lease()..setEnabled(true);
      await coordinator.settled;
      driver.failRelease = true;
      lease.setEnabled(false);
      await coordinator.settled;
      expect(coordinator.status, ScreenAwakeStatus.failed);
      driver.failRelease = false;
      lease.setEnabled(true);
      await coordinator.settled;
      expect(driver.acquires, 2);
      lease.setEnabled(false);
      await coordinator.settled;
      expect(coordinator.status, ScreenAwakeStatus.released);
    });

    test('停止中の解放失敗は進捗通知で連打せず、退出時に保持不明分を再解放する', () async {
      final lease = coordinator.lease()..setEnabled(true);
      await coordinator.settled;
      driver.failRelease = true;
      lease.setEnabled(false);
      await coordinator.settled;
      expect(coordinator.status, ScreenAwakeStatus.failed);
      expect(driver.releases, 1);
      for (var n = 0; n < 20; n++) { lease.setEnabled(false); }
      await coordinator.settled;
      expect(driver.releases, 1);
      driver.failRelease = false;
      lease.dispose();
      await coordinator.settled;
      expect(driver.releases, 2);
      expect(coordinator.status, ScreenAwakeStatus.released);
    });
  });

  group('再生画面への接続', () {
    late _Driver driver;
    late ScreenAwakeCoordinator coordinator;
    late FakeVideo video;
    void prepare() {
      // Future・stream を widget と同じ仮想時間内で作り、別の zone の完了待ちを残さない。
      driver = _Driver();
      coordinator = ScreenAwakeCoordinator(driver);
      video = FakeVideo();
      addTearDown(() {
        coordinator.dispose();
        if (!video.disposed) unawaited(video.dispose());
      });
    }

    Future<void> finish(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      coordinator.dispose();
      await tester.pump();
      await coordinator.settled;
      if (!video.disposed) await video.dispose();
    }

    Future<void> host(WidgetTester tester, {bool active = true, AppState? app}) async {
      Widget child = PlaybackScreenAwake(controller: video, coordinator: coordinator,
        active: active, child: const SizedBox.expand());
      if (app != null) child = AppLockScope(app: app, child: child);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
      await tester.pump();
      await coordinator.settled;
    }

    testWidgets('前景で初期化済みの再生中だけ保持し、pause/end/error/退出で解放する', (tester) async {
      prepare();
      await host(tester);
      expect(driver.acquires, 0);
      await video.initialize();
      await host(tester);
      expect(driver.acquires, 0);
      await video.play();
      await tester.pump();
      await coordinator.settled;
      expect(driver.acquires, 1);
      video.value = video.value.copyWith(isBuffering: true);
      await tester.pump();
      await coordinator.settled;
      expect(driver.releases, 0);
      video.value = video.value.copyWith(isBuffering: false);
      await video.pause();
      await tester.pump();
      await coordinator.settled;
      expect(driver.releases, 1);
      await video.play();
      await tester.pump();
      await coordinator.settled;
      video.value = video.value.copyWith(isCompleted: true);
      await tester.pump();
      await coordinator.settled;
      expect(driver.releases, 2);
      await video.play();
      await tester.pump();
      await coordinator.settled;
      video.value = video.value.copyWith(errorDescription: 'fixture error');
      await tester.pump();
      await coordinator.settled;
      expect(driver.releases, 3);
      expect(coordinator.status, ScreenAwakeStatus.released);
      await tester.pumpWidget(const SizedBox.shrink());
      await coordinator.settled;
      expect(driver.releases, 3);
      await finish(tester);
    });

    testWidgets('背面移行と手動電源ロック相当の paused で解放し、前景の再生にだけ戻す', (tester) async {
      prepare();
      addTearDown(() => tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));
      await video.initialize();
      await video.play();
      await host(tester);
      expect(driver.acquires, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      await coordinator.settled;
      expect(driver.releases, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await coordinator.settled;
      expect(driver.acquires, 2);
      await tester.pumpWidget(const SizedBox.shrink());
      await coordinator.settled;
      expect(driver.releases, 2);
      await finish(tester);
    });

    testWidgets('裏の動画とアプリロック中は保持しない', (tester) async {
      prepare();
      final app = AppState(bakedEndpoint: '', bakedToken: '')..hasPin = true;
      await video.initialize();
      await video.play();
      await host(tester, active: false, app: app);
      expect(driver.acquires, 0);
      await host(tester, app: app);
      expect(driver.acquires, 1);
      app.lockNow();
      await tester.pump();
      await coordinator.settled;
      expect(driver.releases, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await finish(tester);
      app.dispose();
    });

    testWidgets('VideoView の pause と退出から共通保持を解放する', (tester) async {
      prepare();
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: VideoView(
        url: 'https://fixture.invalid/video.mp4', controllerFactory: (_) => video,
        screenAwake: coordinator))));
      await tester.pump();
      await coordinator.settled;
      expect(driver.acquires, 1);
      await tester.tap(find.byTooltip('一時停止'));
      await tester.pump();
      await coordinator.settled;
      expect(driver.releases, 1);
      await tester.tap(find.byKey(const ValueKey('video-center-play')));
      await tester.pump();
      await coordinator.settled;
      expect(driver.acquires, 2);
      await tester.pumpWidget(const SizedBox.shrink());
      await coordinator.settled;
      expect(driver.releases, 2);
      await finish(tester);
    });
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
  test('$platform の橋渡しは既存チャネルへ true/false だけを送る', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    debugDefaultTargetPlatformOverride = platform;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('app.r2gallery/player');
    final calls = <MethodCall>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.arguments;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final native = NativeScreenAwakeDriver();
    expect(await native.acquire(), ScreenAwakeStatus.held);
    await native.release();
    expect(calls.map((c) => c.method), ['setKeepScreenOn', 'setKeepScreenOn']);
    expect(calls.map((c) => c.arguments), [true, false]);
  });
  }

  for (final missing in [true, false]) {
    test('Android チャネルの ${missing ? '未実装' : '取得拒否'} を区別する', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      const channel = MethodChannel('app.r2gallery/player');
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (_) async {
        if (missing) throw MissingPluginException();
        throw PlatformException(code: 'denied');
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      expect(await NativeScreenAwakeDriver().acquire(),
          missing ? ScreenAwakeStatus.unsupported : ScreenAwakeStatus.denied);
    });
  }
}
