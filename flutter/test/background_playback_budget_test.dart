import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/state/app_state.dart';
import 'package:r2_gallery/src/store/lock_platform.dart';

class _Clock implements LockClock {
  int now = 0;
  @override
  Future<ClockReading> read() async => (boot: now, mono: now, wall: now);
}

void main() {
  test('背景再生も既存の再ロック境界を使い、猶予ちょうどの1ms後に失効する', () async {
    final clock = _Clock();
    final app = AppState(clock: clock, bakedEndpoint: '', bakedToken: '')
      ..connected = true
      ..hasPin = true
      ..relockGraceMs = 1000;
    addTearDown(app.dispose);
    expect(await app.backgroundPlaybackBudget(), Duration.zero);
    app.onBackground();
    clock.now = 1000;
    expect(
      await app.backgroundPlaybackBudget(),
      const Duration(milliseconds: 1),
    );
    clock.now = 1001;
    expect(await app.backgroundPlaybackBudget(), Duration.zero);
    clock.now = 1002;
    expect((await app.backgroundPlaybackBudget())!.isNegative, isTrue);
    app.locked = true;
    expect(await app.backgroundPlaybackBudget(), Duration.zero);
  });

  test('同じ背面期間の重複通知で猶予の起点を後ろへ延ばさない', () async {
    final clock = _Clock();
    final app = AppState(clock: clock, bakedEndpoint: '', bakedToken: '')
      ..connected = true ..hasPin = true ..relockGraceMs = 1000;
    addTearDown(app.dispose);
    app.onBackground();
    clock.now = 700;
    app.onBackground();
    clock.now = 1001;
    expect(await app.backgroundPlaybackBudget(), Duration.zero);
  });

  test('接続なしは拒否し、ロック手段のない接続は無期限とする', () async {
    final app = AppState(bakedEndpoint: '', bakedToken: '')
      ..deviceLockEnabled = false
      ..hasPin = false;
    addTearDown(app.dispose);
    expect(await app.backgroundPlaybackBudget(), Duration.zero);
    app.connected = true;
    expect(await app.backgroundPlaybackBudget(), isNull);
  });
}
