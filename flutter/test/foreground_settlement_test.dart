import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/state/app_state.dart';
import 'package:r2_gallery/src/store/device_auth.dart';
import 'package:r2_gallery/src/store/lock_platform.dart';

class _Clock implements LockClock {
  int now = 0;
  @override
  Future<ClockReading> read() => Future.value((boot: now, mono: now, wall: now));
}

class _Auth implements DeviceAuth {
  final firstSeen = Completer<void>();
  final releaseFirst = Completer<bool>();
  final secondSeen = Completer<void>();
  Completer<bool>? releaseSecond;
  int probes = 0;

  @override
  Future<bool> isAvailable() {
    probes++;
    if (probes == 1) {
      firstSeen.complete();
      return releaseFirst.future;
    }
    if (probes == 2) {
      secondSeen.complete();
      return releaseSecond?.future ?? Future.value(true);
    }
    return Future.value(true);
  }

  @override
  Future<bool> verify(String reason) async => true;
}

AppState _app(_Clock clock, _Auth auth) => AppState(
      clock: clock,
      deviceAuth: auth,
      bakedEndpoint: '',
      bakedToken: '',
    )
      ..connected = true
      ..hasPin = true
      ..relockGraceMs = 1000;

Future<void> _dispose(AppState app, _Auth auth) async {
  if (!auth.releaseFirst.isCompleted) auth.releaseFirst.complete(true);
  final second = auth.releaseSecond;
  if (second != null && !second.isCompleted) second.complete(true);
  await app.foregroundSettled;
  app.dispose();
}

void main() {
  test('復帰判定中の再離脱・再復帰も同じFutureで最新のロック判定まで待つ', () async {
    final clock = _Clock();
    final auth = _Auth()..releaseSecond = Completer<bool>();
    final app = _app(clock, auth);
    addTearDown(() => _dispose(app, auth));
    app.onBackground();
    clock.now = 10;
    final first = app.onForeground();
    await auth.firstSeen.future;
    expect(app.locked, isFalse);

    clock.now = 20;
    app.onBackground();
    clock.now = 2020;
    final second = app.onForeground();
    final settled = app.foregroundSettled;
    expect(identical(first, second), isTrue);
    expect(identical(first, settled), isTrue);
    var finished = false;
    settled.then((_) { finished = true; });
    auth.releaseFirst.complete(true);
    await Future<void>.delayed(Duration.zero);
    expect(auth.probes, 2);
    await auth.secondSeen.future;
    expect(app.locked, isTrue);
    expect(finished, isFalse);
    auth.releaseSecond!.complete(true);
    await settled;
    expect(auth.probes, 2);
    expect(app.locked, isTrue);
  });

  test('同じ復帰の重複通知では端末認証の問い合わせを増やさない', () async {
    final clock = _Clock();
    final auth = _Auth();
    final app = _app(clock, auth);
    addTearDown(() => _dispose(app, auth));
    app.onBackground();
    clock.now = 10;
    final first = app.onForeground();
    await auth.firstSeen.future;
    final duplicate = app.onForeground();
    expect(identical(first, duplicate), isTrue);
    auth.releaseFirst.complete(true);
    await duplicate;
    expect(auth.probes, 1);
    expect(app.locked, isFalse);
  });

  test('まだ背景にいる間は新しい時刻を消費せず、次に戻った時に判定する', () async {
    final clock = _Clock();
    final auth = _Auth();
    final app = _app(clock, auth);
    addTearDown(() => _dispose(app, auth));
    app.onBackground();
    clock.now = 10;
    final first = app.onForeground();
    await auth.firstSeen.future;
    clock.now = 20;
    app.onBackground();
    clock.now = 2020;
    auth.releaseFirst.complete(true);
    await first;
    expect(app.locked, isFalse);
    expect(auth.probes, 1);

    await app.onForeground();
    expect(app.locked, isTrue);
    expect(auth.probes, 2);
  });

  test('復帰判定中に画面が閉じられて戻った場合も、起動時と同じロックをかける', () async {
    final clock = _Clock();
    final auth = _Auth();
    final app = _app(clock, auth);
    addTearDown(() => _dispose(app, auth));
    app.onBackground();
    clock.now = 10;
    final first = app.onForeground();
    await auth.firstSeen.future;
    app.onDetached();
    final second = app.onForeground();
    expect(identical(first, second), isTrue);
    auth.releaseFirst.complete(true);
    await second;
    expect(app.locked, isTrue);
    expect(auth.probes, 2);
  });
}
