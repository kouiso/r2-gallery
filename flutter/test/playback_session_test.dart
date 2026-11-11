import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/playback/playback_session.dart';

import 'support/fake_video.dart';

class _Port implements PlaybackPort {
  final calls = <String>[];
  PlaybackSession? bound;
  Completer<bool>? focusGate;
  Completer<bool>? pipGate;
  final entering = Completer<void>();
  final focusRequested = Completer<void>();
  bool focus = false;
  bool pipResult = true;
  @override
  Future<void> bind(PlaybackSession session) async {
    bound = session;
    session.pipSupported = true;
    session.backgroundSupported = true;
    calls.add('bind:${session.id}');
  }

  @override
  void update(PlaybackSession session) => calls.add('state:${session.id}');
  @override
  Future<void> clear(PlaybackSession session) async {
    if (identical(bound, session)) bound = null;
    calls.add('clear:${session.id}');
  }

  @override
  Future<bool> activateAudio(bool active) async {
    if (active && !focusRequested.isCompleted) focusRequested.complete();
    if (active && focusGate != null) await focusGate!.future;
    focus = active;
    calls.add('focus:$active');
    return true;
  }

  @override
  Future<bool> enterPip(PlaybackSession session, Rect rect) async {
    if (!entering.isCompleted) entering.complete();
    return pipGate?.future ?? pipResult;
  }

  @override
  Future<void> exitPip(PlaybackSession session) async =>
      calls.add('exit:${session.id}');
  @override
  Future<void> visibility(PlaybackSession session) async =>
      calls.add('visible:${session.foreground}');
}

class _Video extends FakeVideo {
  _Video(this.rig);
  final _Rig rig;
  bool allocated = false;
  @override
  Future<void> initialize() async {
    allocated = true;
    rig.alive++;
    if (rig.alive > rig.maximum) rig.maximum = rig.alive;
    await super.initialize();
  }

  @override
  Future<void> dispose() async {
    if (disposed) return;
    if (allocated) rig.alive--;
    await super.dispose();
  }
}

class _Rig {
  final port = _Port();
  late final owner = PlaybackCoordinator(port);
  int alive = 0;
  int maximum = 0;
  final sessions = <PlaybackSession>[];
  PlaybackSession create({
    Future<bool> Function()? authorize,
    Future<Duration?> Function()? budget,
    VoidCallback? relock,
  }) {
    final session = owner.create(
      controller: _Video(this),
      authorize: authorize ?? () async => true,
      backgroundBudget: budget ?? () async => null,
      onRelock: relock ?? () {},
    );
    sessions.add(session);
    return session;
  }

  Future<void> close() async {
    for (final session in sessions) {
      await session.close();
      session.dispose();
    }
  }
}

void main() {
  late _Rig rig;
  setUp(() => rig = _Rig());
  tearDown(() => rig.close());

  test('次の動画は古いdecoderの破棄を待ち、再生器を二重に作らない', () async {
    final first = rig.create();
    await first.initialize();
    await first.play();
    final next = rig.create();
    await next.initialize();
    expect(first.closed, isTrue);
    expect((first.controller as _Video).disposed, isTrue);
    expect(rig.maximum, 1);
    expect(rig.alive, 1);
    await first.play();
    expect((first.controller as _Video).plays, 1);
    expect(rig.owner.current, same(next));
  });

  test('認証判定待ちのplayを、手動pauseが取り消す', () async {
    final gate = Completer<bool>();
    final session = rig.create(authorize: () => gate.future);
    await session.initialize();
    final play = session.play();
    await session.pause();
    gate.complete(true);
    await play;
    expect((session.controller as _Video).plays, 0);
    expect(session.controller.value.isPlaying, isFalse);
  });

  test('背景再生は明示許可時だけ継続し、手動pauseとpositionを復帰で失わない', () async {
    final session = rig.create();
    await session.initialize();
    await session.play();
    await session.setBackgroundAllowed(true);
    await session.lifecycle(AppLifecycleState.inactive);
    await session.lifecycle(AppLifecycleState.paused);
    expect(session.controller.value.isPlaying, isTrue);
    await session.seek(const Duration(seconds: 32));
    await session.pause();
    await session.lifecycle(AppLifecycleState.resumed);
    expect((session.controller as _Video).plays, 1);
    expect(session.controller.value.isPlaying, isFalse);
    expect(session.controller.value.position, const Duration(seconds: 32));
    await session.play();
    expect(session.controller.value.position, const Duration(seconds: 32));
    expect(rig.maximum, 1);
  });

  test('背景再生を許可しない動画は背面で止まり、復帰時に認証後だけ再開する', () async {
    final session = rig.create();
    await session.initialize();
    await session.play();
    await session.lifecycle(AppLifecycleState.paused);
    expect(session.controller.value.isPlaying, isFalse);
    await session.play();
    expect(session.controller.value.isPlaying, isFalse);
    await session.lifecycle(AppLifecycleState.resumed);
    // 背面からの拒否された手動playも、古い自動再開の意図を消す。
    expect(session.controller.value.isPlaying, isFalse);
  });

  test('前景へ戻る判定中にも一旦停止し、途中のpauseを自動再開で上書きしない', () async {
    Completer<bool>? gate;
    final session = rig.create(
      authorize: () => gate?.future ?? Future.value(true),
    );
    await session.initialize();
    await session.play();
    await session.setBackgroundAllowed(true);
    await session.lifecycle(AppLifecycleState.paused);
    gate = Completer<bool>();
    final returning = session.lifecycle(AppLifecycleState.resumed);
    await Future<void>.value();
    await session.pause();
    expect(session.controller.value.isPlaying, isFalse);
    gate.complete(true);
    await returning;
    expect((session.controller as _Video).plays, 1);
  });

  test('PiP開始中のinactiveでも同じdecoderを保ち、通常画面へ同じpositionで戻る', () async {
    final session = rig.create();
    await session.initialize();
    await session.play();
    await session.seek(const Duration(seconds: 42));
    rig.port.pipGate = Completer<bool>();
    final request = session.enterPip(const Rect.fromLTWH(0, 0, 320, 180));
    await rig.port.entering.future;
    await session.lifecycle(AppLifecycleState.inactive);
    expect(session.controller.value.isPlaying, isTrue);
    session.pipChanged(true);
    rig.port.pipGate!.complete(true);
    expect(await request, isTrue);
    await session.lifecycle(AppLifecycleState.resumed);
    session.pipChanged(false);
    expect(session.controller.value.position, const Duration(seconds: 42));
    expect(rig.maximum, 1);
  });

  test('PiPのinactiveだけでも猶予が尽きたら停止して再生操作を拒否する', () async {
    var locks = 0;
    var allowed = true;
    final session = rig.create(
      authorize: () async => allowed,
      budget: () async => const Duration(milliseconds: 5),
      relock: () { locks++; allowed = false; },
    );
    try {
      await session.initialize();
      await session.play();
      await session.enterPip(const Rect.fromLTWH(0, 0, 320, 180));
      session.pipChanged(true);
      await session.lifecycle(AppLifecycleState.inactive);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(locks, 1);
      expect(session.controller.value.isPlaying, isFalse);
      await session.play();
      expect(session.controller.value.isPlaying, isFalse);
    } finally { await session.close(); }
  });

  test('PiP拒否を成功とせず、別playerを起動しない', () async {
    final session = rig.create();
    await session.initialize();
    rig.port.pipResult = false;
    expect(
      await session.enterPip(const Rect.fromLTWH(0, 0, 320, 180)),
      isFalse,
    );
    expect(session.pipPending, isFalse);
    expect(session.pip, isFalse);
    expect(session.message, contains('利用できません'));
    expect(rig.maximum, 1);
  });

  test('音声割込み後の再開は、手動pauseが無い時にだけ許す', () async {
    final session = rig.create();
    await session.initialize();
    await session.play();
    await session.interrupt(begin: true);
    await session.pause();
    await session.interrupt(begin: false, resume: true);
    expect(session.controller.value.isPlaying, isFalse);
    await session.play();
    await session.interrupt(begin: true);
    await session.interrupt(begin: false, resume: true);
    expect(session.controller.value.isPlaying, isTrue);
  });

  test('再ロック猶予が尽きたら背景側でも停止・OS操作解放する', () async {
    final locked = Completer<void>();
    var authorized = true;
    final session = rig.create(
      authorize: () async => authorized,
      budget: () async => const Duration(milliseconds: 5),
      relock: () {
        authorized = false;
        if (!locked.isCompleted) locked.complete();
      },
    );
    await session.initialize();
    await session.play();
    await session.setBackgroundAllowed(true);
    await session.lifecycle(AppLifecycleState.paused);
    await locked.future.timeout(const Duration(seconds: 2));
    await session.stop();
    expect(session.controller.value.isPlaying, isFalse);
    expect(rig.port.bound, isNull);
    expect(rig.port.focus, isFalse);
    await session.play();
    expect(session.controller.value.isPlaying, isFalse);
  });

  test('通知シェードのinactiveを背景時刻未取得の即時ロックと取り違えない', () async {
    var locks = 0;
    final session = rig.create(
      budget: () async => Duration.zero,
      relock: () => locks++,
    );
    await session.initialize();
    await session.play();
    await session.setBackgroundAllowed(true);
    await session.lifecycle(AppLifecycleState.inactive);
    await Future<void>.delayed(Duration.zero);
    expect(locks, 0);
    expect(session.controller.value.isPlaying, isTrue);
  });

  test('遅い音声focus取得よりも後に停止の解放を終える', () async {
    final session = rig.create();
    await session.initialize();
    rig.port.focusGate = Completer<bool>();
    final play = session.play();
    await rig.port.focusRequested.future;
    final stop = session.stop();
    rig.port.focusGate!.complete(true);
    await Future.wait([play, stop]);
    expect((session.controller as _Video).plays, 0);
    expect(rig.port.focus, isFalse);
  });

  test('focus取得中の割込みは遅いplayを止め、割込み終了まで再生しない', () async {
    final session = rig.create();
    await session.initialize();
    rig.port.focusGate = Completer<bool>();
    final play = session.play();
    await rig.port.focusRequested.future;
    final interrupted = session.interrupt(begin: true);
    rig.port.focusGate!.complete(true);
    await Future.wait([play, interrupted]);
    expect((session.controller as _Video).plays, 0);
    expect(rig.port.focus, isFalse);
    await session.play();
    expect((session.controller as _Video).plays, 0);
    await session.interrupt(begin: false, resume: true);
    // 割込み中の手動操作は、割込み開始前の自動再開の意図を消す。
    expect((session.controller as _Video).plays, 0);
    await session.play();
    expect(session.controller.value.isPlaying, isTrue);
  });

  test('完了はOS操作とfocusを解放し、明示replayだけ先頭から始める', () async {
    final session = rig.create();
    await session.initialize();
    await session.play();
    session.controller.value = session.controller.value.copyWith(
      isPlaying: false,
      isCompleted: true,
      position: const Duration(seconds: 60),
    );
    await session.stop();
    expect(rig.port.bound, isNull);
    expect(rig.port.focus, isFalse);
    expect(session.controller.value.position, const Duration(seconds: 60));
    await session.play();
    expect(session.controller.value.position, Duration.zero);
    expect(session.controller.value.isPlaying, isTrue);
  });

  test('接続の取消し・画面破棄は同じ停止経路でdecoderを破棄する', () async {
    final session = rig.create();
    await session.initialize();
    await session.play();
    session.authorizationChanged(connectionChanged: true, locked: false);
    await session.close();
    expect(session.closed, isTrue);
    expect(rig.alive, 0);
    expect(rig.port.bound, isNull);
    expect(rig.owner.current, isNull);
  });
}
