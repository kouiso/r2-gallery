import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/playback/mobile_playback.dart';
import 'package:r2_gallery/src/playback/playback_session.dart';
import 'package:r2_gallery/src/state/app_state.dart';
import 'package:r2_gallery/src/store/lock_platform.dart';

import 'support/fake_playback.dart';
import 'support/fake_video.dart';

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
  test('毎回ロックの接続ではOSへPiP開始を依頼しない', () async {
    final app = _App(_Clock())..connected = true..hasPin = true..relockGraceMs = 0;
    final port = FakePlaybackPort();
    final binding = PlaybackBinding.attach(controller: FakeVideo(), app: app,
        library: 'lib', coordinator: PlaybackCoordinator(port))!;
    try {
      await binding.session.initialize();
      await binding.session.play();
      expect(await binding.session.enterPip(const Rect.fromLTWH(0, 0, 320, 180)), isFalse);
      expect(port.pipRequests, 0);
    } finally { await binding.close(); app.dispose(); }
  });

  testWidgets('PiPの開始から猶予を数え、後のpaused通知で延長せず失効時に閉じる', (tester) async {
    final clock = _Clock();
    final app = _App(clock)..connected = true..hasPin = true..relockGraceMs = 1000;
    final port = FakePlaybackPort();
    final video = FakeVideo();
    final binding = PlaybackBinding.attach(controller: video, app: app,
        library: 'lib', coordinator: PlaybackCoordinator(port))!;
    final session = binding.session;
    try {
      await session.initialize();
      await session.play();
      expect(await session.enterPip(const Rect.fromLTWH(0, 0, 320, 180)), isTrue);
      session.pipChanged(true);
      await session.lifecycle(AppLifecycleState.inactive);
      clock.now = 700;
      app.onBackground();
      expect(await app.backgroundPlaybackBudget(), const Duration(milliseconds: 301));
      clock.now = 1001;
      await tester.pump(const Duration(milliseconds: 1001));
      await tester.pump();
      expect(app.locked, isTrue);
      expect(video.value.isPlaying, isFalse);
      expect(session.pip, isFalse);
      session.pipChanged(true);
      expect(session.pip, isFalse);
      await session.play();
      expect(video.value.isPlaying, isFalse);
    } finally { await binding.close(); app.dispose(); }
  });
}
