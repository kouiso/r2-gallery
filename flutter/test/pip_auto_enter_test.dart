import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/playback/mobile_playback.dart';
import 'package:r2_gallery/src/playback/playback_session.dart';
import 'package:r2_gallery/src/state/app_state.dart';
import 'package:r2_gallery/src/store/lock_platform.dart';
import 'package:r2_gallery/src/ui/theme.dart';
import 'package:r2_gallery/src/ui/video_view.dart';

import 'support/fake_playback.dart';
import 'support/fake_video.dart';

const _rect = Rect.fromLTWH(0, 0, 320, 180);

PlaybackSession _make(
  FakePlaybackPort port,
  FakeVideo video, {
  bool Function()? locked,
  bool Function()? canEnter,
}) => PlaybackCoordinator(port).create(
  controller: video,
  authorize: () async => true,
  backgroundBudget: () async => null,
  onRelock: () {},
  canEnterPip: canEnter,
  isLocked: locked,
);

bool _everArmed(FakePlaybackPort port) => port.arms.any((a) => a.$1);

class _Clock implements LockClock {
  int now = 0;
  @override
  Future<ClockReading> read() async => (boot: now, mono: now, wall: now);
}

class _App extends AppState {
  _App(_Clock clock) : super(clock: clock, bakedEndpoint: '', bakedToken: '');
  @override
  String? get offlineAccountId => 'synthetic';
  @override
  bool canReadOffline(String lib) => connected && !locked && lib == 'lib';
}

void main() {
  group('自動で小窓に入る条件（native へ知らせる armed）', () {
    test('再生中だけ入る設定になり、一時停止で外れ、再生でまた入る', () async {
      final port = FakePlaybackPort();
      final video = FakeVideo();
      final session = _make(port, video);
      await session.initialize();
      expect(_everArmed(port), isFalse, reason: '読み込み後・再生前は入らない');
      await session.play();
      expect(port.arms.last, (true, 16, 9));
      await session.pause();
      expect(port.arms.last.$1, isFalse);
      await session.play();
      expect(port.arms.last, (true, 16, 9));
      await session.close();
    });

    test('ロック中は入る設定にならない', () async {
      final port = FakePlaybackPort();
      final session = _make(port, FakeVideo(), locked: () => true);
      await session.initialize();
      await session.play();
      expect(_everArmed(port), isFalse);
      await session.close();
    });

    test('毎回ロックは入る設定にならない', () async {
      final port = FakePlaybackPort();
      final session = _make(port, FakeVideo(), canEnter: () => false);
      await session.initialize();
      await session.play();
      expect(_everArmed(port), isFalse);
      await session.close();
    });

    test('非対応の端末は入る設定にならない', () async {
      final port = FakePlaybackPort()..supported = false;
      final session = _make(port, FakeVideo());
      await session.initialize();
      await session.play();
      expect(_everArmed(port), isFalse);
      await session.close();
    });

    test('終了後・失敗後は入る設定が外れる', () async {
      for (final failed in [false, true]) {
        final port = FakePlaybackPort();
        final video = FakeVideo();
        final session = _make(port, video);
        await session.initialize();
        await session.play();
        expect(port.arms.last.$1, isTrue);
        video.value = failed
            ? video.value.copyWith(isPlaying: false, errorDescription: 'x')
            : video.value.copyWith(isPlaying: false, isCompleted: true);
        await Future<void>.delayed(Duration.zero);
        expect(port.arms.last.$1, isFalse, reason: failed ? '失敗後' : '終了後');
        await session.close();
      }
    });

    test('画面が裏に回ると外れ、戻って再生中ならまた入る', () async {
      final port = FakePlaybackPort();
      final session = _make(port, FakeVideo());
      await session.initialize();
      await session.play();
      await session.lifecycle(AppLifecycleState.inactive);
      expect(port.arms.last.$1, isFalse);
      await session.lifecycle(AppLifecycleState.resumed);
      expect(port.arms.last.$1, isTrue);
      await session.close();
    });

    test('一時停止中にボタンで入っても、勝手に再生を始めない', () async {
      final port = FakePlaybackPort();
      final video = FakeVideo();
      final session = _make(port, video);
      await session.initialize();
      await session.play();
      await session.pause();
      final plays = video.plays;
      expect(await session.enterPip(_rect), isTrue);
      session.pipChanged(true);
      expect(video.value.isPlaying, isFalse);
      expect(video.plays, plays);
      await session.close();
    });
  });

  group('ホームへ出た時', () {
    testWidgets('自動で入る設定なら、小窓の通知より先に inactive が来ても止めない', (tester) async {
      final port = FakePlaybackPort();
      final video = FakeVideo();
      final session = _make(port, video);
      await session.initialize();
      await session.play();
      await session.lifecycle(AppLifecycleState.inactive);
      expect(video.value.isPlaying, isTrue);
      session.pipChanged(true);
      expect(session.pip, isTrue);
      expect(video.value.isPlaying, isTrue);
      expect(port.exits, 0, reason: '頼んでいない小窓でも、入る設定の間は閉じない');
      await tester.pump(const Duration(seconds: 3));
      expect(video.value.isPlaying, isTrue);
      await session.close();
    });

    testWidgets('OS に断られたら 2 秒後に従来の動き（一時停止）へ戻り、エラーは出さない', (tester) async {
      final port = FakePlaybackPort();
      final video = FakeVideo();
      final session = _make(port, video);
      await session.initialize();
      await session.play();
      await session.lifecycle(AppLifecycleState.inactive);
      expect(video.value.isPlaying, isTrue);
      await tester.pump(const Duration(seconds: 3));
      expect(video.value.isPlaying, isFalse);
      expect(session.message, isNull);
      expect(session.pip, isFalse);
      await session.close();
    });

    test('入る設定でない時（毎回ロック）は従来どおりすぐ止まる', () async {
      final port = FakePlaybackPort();
      final video = FakeVideo();
      final session = _make(port, video, canEnter: () => false);
      await session.initialize();
      await session.play();
      await session.lifecycle(AppLifecycleState.inactive);
      expect(video.value.isPlaying, isFalse);
      await session.close();
    });

    test('頼んでいない小窓は、入る設定でなければ閉じる', () async {
      final port = FakePlaybackPort();
      final session = _make(port, FakeVideo());
      await session.initialize();
      await session.play();
      await session.pause();
      session.pipChanged(true);
      expect(session.pip, isFalse);
      expect(port.exits, 1);
      await session.close();
    });

    testWidgets('自動で入った小窓でも、猶予は入った時点から数えて超過で停止し再生を拒否する', (tester) async {
      final clock = _Clock();
      final app = _App(clock)
        ..connected = true
        ..hasPin = true
        ..relockGraceMs = 1000;
      final port = FakePlaybackPort();
      final video = FakeVideo();
      final binding = PlaybackBinding.attach(
        controller: video,
        app: app,
        library: 'lib',
        coordinator: PlaybackCoordinator(port),
      )!;
      final session = binding.session;
      try {
        await session.initialize();
        await session.play();
        await session.lifecycle(AppLifecycleState.inactive);
        session.pipChanged(true);
        clock.now = 700;
        app.onBackground();
        clock.now = 1001;
        await tester.pump(const Duration(milliseconds: 1001));
        await tester.pump();
        expect(app.locked, isTrue);
        expect(video.value.isPlaying, isFalse);
        expect(session.pip, isFalse);
        await session.play();
        expect(video.value.isPlaying, isFalse);
      } finally {
        await binding.close();
        app.dispose();
      }
    });
  });

  group('小窓が閉じた理由（項目11）', () {
    test('native が「元に戻す」と決めたら、時間差を待たず止めない', () async {
      final port = FakePlaybackPort();
      final video = FakeVideo();
      final session = _make(port, video);
      await session.initialize();
      await session.play();
      await session.lifecycle(AppLifecycleState.inactive);
      session.pipChanged(true);
      session.pipChanged(false, restoring: true);
      await session.lifecycle(AppLifecycleState.resumed);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(video.value.isPlaying, isTrue);
      expect(session.pip, isFalse);
      await session.close();
    });

    test('native が「×」と決めたら、すぐ止めて背景再生も切る', () async {
      final port = FakePlaybackPort();
      final video = FakeVideo();
      final session = _make(port, video);
      await session.initialize();
      await session.play();
      await session.lifecycle(AppLifecycleState.inactive);
      session.pipChanged(true);
      session.pipChanged(false, restoring: false);
      await Future<void>.delayed(Duration.zero);
      expect(video.value.isPlaying, isFalse);
      expect(port.bound, isNull);
      await session.close();
    });

    testWidgets('古い経路（値が無い）は従来の 250ms 判定を保険に残す', (tester) async {
      final port = FakePlaybackPort();
      final video = FakeVideo();
      final session = _make(port, video);
      await session.initialize();
      await session.play();
      await session.lifecycle(AppLifecycleState.inactive);
      session.pipChanged(true);
      session.pipChanged(false);
      await tester.pump(const Duration(milliseconds: 300));
      expect(video.value.isPlaying, isFalse);
      await session.close();
    });
  });

  group('入れない理由（項目13・23）', () {
    test('ロック中・毎回ロック・その他で文言が分かれる', () async {
      final locked = _make(FakePlaybackPort(), FakeVideo(), locked: () => true);
      await locked.initialize();
      await locked.play();
      expect(await locked.enterPip(_rect), isFalse);
      expect(locked.message, 'ロック中は小窓で再生できません');
      await locked.close();

      final every = _make(
        FakePlaybackPort(),
        FakeVideo(),
        canEnter: () => false,
      );
      await every.initialize();
      await every.play();
      expect(await every.enterPip(_rect), isFalse);
      expect(every.message, '画面ロックの猶予が「毎回ロック」のため、小窓では再生できません');
      await every.close();

      final port = FakePlaybackPort()..refuse = true;
      final other = _make(port, FakeVideo());
      await other.initialize();
      await other.play();
      expect(await other.enterPip(_rect), isFalse);
      expect(other.message, '小窓再生はこの端末または設定では利用できません');
      expect(other.pipSettingsNeeded, isFalse);
      await other.close();
    });

    test('設定で未許可なら理由と「設定を開く」の元を持つ', () async {
      final port = FakePlaybackPort()..pipAllowed = false;
      final session = _make(port, FakeVideo());
      await session.initialize();
      await session.play();
      expect(await session.enterPip(_rect), isFalse);
      expect(session.message, '端末の設定で、このアプリの小窓表示が許可されていません');
      expect(session.pipSettingsNeeded, isTrue);
      await session.openPipSettings();
      expect(port.settingsOpened, 1);
      await session.close();
    });
  });

  group('小窓の中で終わる（項目24）', () {
    test('終わってもアプリごと閉じず、入る設定は外れ、小窓は残る', () async {
      final port = FakePlaybackPort();
      final video = FakeVideo();
      final session = _make(port, video);
      await session.initialize();
      await session.play();
      await session.lifecycle(AppLifecycleState.inactive);
      session.pipChanged(true);
      video.value = video.value.copyWith(isPlaying: false, isCompleted: true);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(port.exits, 0);
      expect(port.arms.last.$1, isFalse);
      expect(session.pip, isTrue);
      await session.close();
    });

    test('ロックでは小窓ごと閉じる', () async {
      final port = FakePlaybackPort();
      final session = _make(port, FakeVideo());
      await session.initialize();
      await session.play();
      await session.lifecycle(AppLifecycleState.inactive);
      session.pipChanged(true);
      session.authorizationChanged(connectionChanged: false, locked: true);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(port.exits, greaterThanOrEqualTo(1));
      expect(session.pip, isFalse);
      await session.close();
    });

    test('閉じない停止が走っている間にロックされても、小窓を閉じ忘れない', () async {
      final port = FakePlaybackPort();
      final session = _make(port, FakeVideo());
      await session.initialize();
      await session.play();
      await session.lifecycle(AppLifecycleState.inactive);
      session.pipChanged(true);
      final soft = session.stop(closePip: false);
      final hard = session.stop();
      await Future.wait([soft, hard]);
      expect(port.exits, 1);
      await session.close();
    });
  });

  group('画面の動き', () {
    Future<(PlaybackCoordinator, FakePlaybackPort, FakeVideo)> pumpView(
      WidgetTester tester,
    ) async {
      final port = FakePlaybackPort();
      final owner = PlaybackCoordinator(port);
      final video = FakeVideo();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: VideoView(
              url: 'https://fixture.invalid/a.mp4',
              controllerFactory: (_) => video,
              playbackCoordinator: owner,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      return (owner, port, video);
    }

    testWidgets('小窓に入ると上のシート・ダイアログが畳まれる', (tester) async {
      final (owner, _, video) = await pumpView(tester);
      final context = tester.element(find.byType(VideoView));
      showModalBottomSheet<void>(
        context: context,
        builder: (_) => const SizedBox(height: 80, child: Text('sheet-a')),
      );
      await tester.pumpAndSettle();
      showDialog<void>(
        context: context,
        builder: (_) => const AlertDialog(content: Text('dialog-b')),
      );
      await tester.pumpAndSettle();
      expect(find.text('sheet-a'), findsOneWidget);
      expect(find.text('dialog-b'), findsOneWidget);
      owner.current!.pipChanged(true);
      await tester.pumpAndSettle();
      expect(find.text('sheet-a'), findsNothing);
      expect(find.text('dialog-b'), findsNothing);
      expect(find.byType(VideoView), findsOneWidget);
      expect(video.value.isPlaying, isTrue);
    });

    testWidgets('小窓の中では終了表示を出さず、戻すと出る', (tester) async {
      final (owner, _, video) = await pumpView(tester);
      final session = owner.current!;
      session.pipChanged(true);
      await tester.pump();
      video.value = video.value.copyWith(isPlaying: false, isCompleted: true);
      await tester.pump();
      await tester.pump();
      expect(find.text('再生が終了しました'), findsNothing);
      session.pipChanged(false, restoring: true);
      await session.lifecycle(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.text('再生が終了しました'), findsOneWidget);
    });

    testWidgets('許可が無い時は理由と「設定を開く」を出し、押すと設定へ行く', (tester) async {
      final (_, port, _) = await pumpView(tester);
      port.pipAllowed = false;
      await tester.tap(find.byTooltip('再生方法'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('小窓で再生'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.text('端末の設定で、このアプリの小窓表示が許可されていません'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('設定を開く'));
      await tester.pump();
      expect(port.settingsOpened, 1);
    });

    testWidgets('許可の問題でない失敗では「設定を開く」を出さない', (tester) async {
      final (_, port, _) = await pumpView(tester);
      port.refuse = true;
      await tester.tap(find.byTooltip('再生方法'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('小窓で再生'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.text('小窓再生はこの端末または設定では利用できません'),
        ),
        findsOneWidget,
      );
      expect(find.text('設定を開く'), findsNothing);
    });
  });
}
