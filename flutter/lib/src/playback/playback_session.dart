import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

/// OS のメディア操作は再生器を持たず、同じ session の命令へ戻す。
abstract class PlaybackPort {
  Future<void> bind(PlaybackSession session);
  void update(PlaybackSession session);
  Future<void> clear(PlaybackSession session);
  Future<bool> activateAudio(bool active);
  Future<bool> enterPip(PlaybackSession session, Rect rect);
  Future<void> exitPip(PlaybackSession session);
  Future<void> visibility(PlaybackSession session);
}

/// 新しい native player を初期化する前に、古い所有者の解放を待つ。
class PlaybackCoordinator {
  PlaybackCoordinator(this.port);
  final PlaybackPort port;
  PlaybackSession? current;
  PlaybackSession? creating;
  ValueChanged<PlaybackSession?>? onCreating;
  Future<void> _handoff = Future<void>.value();
  Future<void> _audioTail = Future<void>.value();
  int _nextId = 0;
  final _prefix =
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${Random.secure().nextInt(0x7fffffff).toRadixString(36)}';

  Future<bool> audio(bool active) {
    // 遅いfocus取得が、後から完了した停止・次の所有者を追い越さないよう順序を揃える。
    final next = _audioTail.then((_) => port.activateAudio(active));
    _audioTail = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  Future<void> acquire(PlaybackSession next) {
    final ready = _handoff.then((_) async {
      final previous = current;
      if (identical(previous, next)) return;
      current = next;
      if (previous != null) await previous.close();
    });
    _handoff = ready.catchError((Object _) {});
    return ready;
  }

  PlaybackSession create({
    required VideoPlayerController controller,
    required Future<bool> Function() authorize,
    required Future<Duration?> Function() backgroundBudget,
    required VoidCallback onRelock,
    VoidCallback? onPipBackground,
    bool Function()? canEnterPip,
  }) => PlaybackSession._(
    this,
    'r2g-$_prefix-${++_nextId}',
    controller,
    authorize,
    backgroundBudget,
    onRelock,
    onPipBackground ?? () {},
    canEnterPip ?? () => true,
  );
}

class PlaybackSession extends ChangeNotifier {
  PlaybackSession._(
    this.coordinator,
    this.id,
    this.controller,
    this._authorize,
    this._backgroundBudget,
    this._onRelock,
    this._onPipBackground,
    this._canEnterPip,
  );

  final PlaybackCoordinator coordinator;
  final String id;
  final VideoPlayerController controller;
  final Future<bool> Function() _authorize;
  final Future<Duration?> Function() _backgroundBudget;
  final VoidCallback _onRelock;
  final VoidCallback _onPipBackground;
  final bool Function() _canEnterPip;
  int? nativePlayerId;
  bool foreground = true;
  bool _backgroundPaused = false;
  bool backgroundAllowed = false;
  bool pip = false;
  bool pipPending = false;
  bool pipSupported = false;
  bool backgroundSupported = false;
  bool closed = false;
  bool _closing = false;
  bool _bound = false;
  bool _resume = false;
  bool _playPending = false;
  bool _resumePending = false;
  bool _interrupted = false;
  bool _audioInterrupted = false;
  int _intent = 0;
  int _interruptedIntent = 0;
  int _visibilityGeneration = 0;
  Future<void>? _closeRun;
  Future<void>? _stopRun;
  Future<bool>? _focusRun;
  bool _notifierDisposed = false;
  Timer? _budgetTimer;
  Timer? _pipExitTimer;
  String? message;

  bool get live => !closed && !_closing && identical(coordinator.current, this);
  bool get mayPlayHere => foreground || backgroundAllowed || pip || pipPending;
  bool get hasPlayIntent => _playPending || _resumePending;
  PlaybackPort get _port => coordinator.port;

  Future<void> initialize() async {
    await coordinator.acquire(this);
    if (!live) return;
    coordinator.creating = this;
    coordinator.onCreating?.call(this);
    controller.addListener(_changed);
    try {
      await controller.initialize();
      if (!live) return;
      await _port.bind(this);
      if (!live) return;
      _bound = true;
      _changed();
    } finally {
      if (identical(coordinator.creating, this)) {
        coordinator.creating = null;
        coordinator.onCreating?.call(null);
      }
    }
  }

  Future<bool> _allowed(int intent) async {
    if (!live || _audioInterrupted || !mayPlayHere || intent != _intent) {
      return false;
    }
    if (!await _authorize()) return false;
    if ((!foreground || pip) && _backgroundPaused) {
      final budget = await _backgroundBudget();
      if (budget != null && budget <= Duration.zero) {
        _onRelock();
        await stop();
        return false;
      }
    }
    return live && !_audioInterrupted && mayPlayHere && intent == _intent;
  }

  Future<void> play() async {
    final intent = ++_intent;
    _resume = false;
    _playPending = true;
    _notify();
    try {
      await _stopRun;
      if (!controller.value.isInitialized || !await _allowed(intent)) return;
      final focus = coordinator.audio(true);
      _focusRun = focus;
      final activated = await focus;
      if (identical(_focusRun, focus)) _focusRun = null;
      if (!activated) {
        message = '別の音声が使用中のため再生できません';
        _notify();
        return;
      }
      if (!await _allowed(intent)) return;
      if (!_bound) {
        await _port.bind(this);
        if (!await _allowed(intent)) return;
        _bound = true;
      }
      if (controller.value.isCompleted) {
        await controller.seekTo(Duration.zero);
        if (!await _allowed(intent)) return;
      }
      message = null;
      await controller.play();
    } finally {
      if (intent == _intent) {
        _playPending = false;
        _notify();
      }
    }
  }

  Future<void> pause() async {
    final intent = ++_intent;
    _resume = false;
    _playPending = false;
    _resumePending = false;
    _interrupted = false;
    if (!live) return;
    await controller.pause();
    await _focusRun;
    if (intent == _intent) await coordinator.audio(false);
    _notify();
  }

  Future<void> seek(Duration target) async {
    final intent = _intent;
    if (!controller.value.isInitialized || !await _allowed(intent)) return;
    final duration = controller.value.duration;
    final position = target < Duration.zero
        ? Duration.zero
        : target > duration
        ? duration
        : target;
    await controller.seekTo(position);
  }

  Future<void> setBackgroundAllowed(bool enabled) async {
    if (!live) return;
    if (enabled && !backgroundSupported) {
      message = 'この環境ではバックグラウンド再生を利用できません';
      _notify();
      return;
    }
    backgroundAllowed = enabled;
    _notify();
    await _scheduleBudget();
    if (!mayPlayHere) await pause();
  }

  Future<void> lifecycle(AppLifecycleState state) async {
    final generation = ++_visibilityGeneration;
    final wasForeground = foreground;
    foreground = state == AppLifecycleState.resumed;
    if (foreground) _backgroundPaused = false;
    if (state == AppLifecycleState.paused) _backgroundPaused = true;
    if (!foreground && (pip || pipPending)) _markPipBackground();
    _notify();
    if (!live) return;
    await _port.visibility(this);
    if (!live || generation != _visibilityGeneration) return;
    if (foreground) {
      _budgetTimer?.cancel();
      _pipExitTimer?.cancel();
      final resume = _resume || controller.value.isPlaying;
      _resume = false;
      _resumePending = resume;
      _notify();
      // 継続再生でも復帰時の認証判定が終わるまで音声を止める。
      final intent = _intent;
      if (controller.value.isPlaying) await controller.pause();
      final allowed = await _authorize();
      if (!live || generation != _visibilityGeneration || intent != _intent) {
        return;
      }
      _resumePending = false;
      if (!allowed) {
        await stop();
      } else if (resume) {
        await play();
      }
    } else {
      if (wasForeground && !mayPlayHere) {
        _resume = controller.value.isPlaying;
        ++_intent;
        await controller.pause();
        await _focusRun;
        if (!foreground && !mayPlayHere) await coordinator.audio(false);
      }
      if (state == AppLifecycleState.detached) {
        await close();
      } else {
        await _scheduleBudget();
      }
    }
  }

  Future<void> _scheduleBudget() async {
    _budgetTimer?.cancel();
    if ((foreground && !pip) || !_backgroundPaused || !live || !mayPlayHere) return;
    final generation = _visibilityGeneration;
    final budget = await _backgroundBudget();
    if (!live || (foreground && !pip) || generation != _visibilityGeneration) return;
    if (budget == null) return;
    _budgetTimer = Timer(budget < Duration.zero ? Duration.zero : budget, () {
      if (!live || (foreground && !pip)) return;
      _onRelock();
      unawaited(stop());
    });
  }

  Future<bool> enterPip(Rect rect) async {
    final intent = _intent;
    if (!pipSupported || !foreground || !_canEnterPip() || !await _allowed(intent)) return false;
    if (!_bound) {
      await _port.bind(this);
      if (!await _allowed(intent)) return false;
      _bound = true;
    }
    pipPending = true;
    _notify();
    try {
      final accepted = await _port.enterPip(this, rect);
      if (!live) return false;
      if (!await _allowed(intent)) {
        pipPending = false;
        await _port.exitPip(this);
        return false;
      }
      if (!accepted) {
        pipPending = false;
        message = '小窓再生はこの端末または設定では利用できません';
        if (!mayPlayHere) await pause();
      }
      // 開始通知が来ない場合は待機状態を残さず、背景再生の方針へ戻す。
      _pipExitTimer?.cancel();
      if (accepted) {
        _pipExitTimer = Timer(const Duration(seconds: 3), () {
          if (!live || !pipPending) return;
          pipPending = false;
          message = '小窓を開始できませんでした';
          unawaited(_port.exitPip(this));
          if (!mayPlayHere) unawaited(pause());
          _notify();
        });
      }
      _notify();
      return accepted;
    } catch (_) {
      pipPending = false;
      message = '小窓を開始できませんでした';
      if (!mayPlayHere) await pause();
      if (live) _notify();
      return false;
    }
  }

  void _markPipBackground() {
    // PiPはpausedにならずinactiveのまま見え続ける端末でも、同じ猶予を数える。
    _onPipBackground();
    _backgroundPaused = true;
  }

  void pipChanged(bool active, {bool restoring = false, bool failed = false}) {
    if (!live) return;
    if (active && !pipPending && !pip) {
      unawaited(_port.exitPip(this));
      return;
    }
    pipPending = false;
    pip = active;
    _pipExitTimer?.cancel();
    if (failed) message = '小窓を開始できませんでした';
    _notify();
    unawaited(_port.visibility(this));
    if (active) {
      _markPipBackground();
      unawaited(_scheduleBudget());
    }
    if (!active) {
      // 通常画面への復帰と小窓の閉鎖を、resumed通知が届く余地を置いて分ける。
      _pipExitTimer = Timer(
        restoring
            ? const Duration(seconds: 3)
            : const Duration(milliseconds: 250),
        () {
          if (live && !foreground && !pip) {
            backgroundAllowed = false;
            unawaited(stop());
          }
        },
      );
    }
  }

  Future<void> interrupt({required bool begin, bool resume = false}) async {
    if (!live) return;
    if (begin) {
      _audioInterrupted = true;
      _interrupted = controller.value.isPlaying || hasPlayIntent;
      _interruptedIntent = ++_intent;
      _playPending = false;
      _resumePending = false;
      await controller.pause();
      await _focusRun;
      if (_audioInterrupted) await coordinator.audio(false);
    } else {
      _audioInterrupted = false;
      final allowed = resume && _interrupted && _interruptedIntent == _intent;
      _interrupted = false;
      if (allowed) await play();
    }
  }

  Future<void> stop() {
    ++_intent;
    _resume = false;
    _playPending = false;
    _resumePending = false;
    _interrupted = false;
    _budgetTimer?.cancel();
    _pipExitTimer?.cancel();
    return _stopRun ??= _stop().whenComplete(() => _stopRun = null);
  }

  Future<void> _stop() async {
    if (closed) return;
    _bound = false;
    pip = false;
    pipPending = false;
    await controller.pause();
    await _port.exitPip(this);
    await _port.clear(this);
    await _focusRun;
    await coordinator.audio(false);
    if (!closed) _notify();
  }

  void authorizationChanged({
    required bool connectionChanged,
    required bool locked,
  }) {
    if (!live) return;
    if (connectionChanged) {
      message = '接続が変わったため再生を停止しました';
      unawaited(close());
    } else if (locked) {
      unawaited(stop());
    }
  }

  void systemUnavailable() {
    message = 'システムの再生操作を利用できないため停止しました';
    backgroundAllowed = false;
    backgroundSupported = false;
    pipSupported = false;
    unawaited(stop());
  }

  void _changed() {
    if (!live) return;
    if (_bound) _port.update(this);
    if (controller.value.isCompleted || controller.value.hasError) {
      if (_bound) unawaited(stop());
    }
  }

  Future<void> close() => _closeRun ??= _close();

  Future<void> _close() async {
    _closing = true;
    ++_intent;
    _budgetTimer?.cancel();
    _pipExitTimer?.cancel();
    controller.removeListener(_changed);
    try {
      await stop();
    } finally {
      await controller.dispose();
      closed = true;
      if (identical(coordinator.current, this)) coordinator.current = null;
      _notify();
    }
  }

  void _notify() {
    if (!_notifierDisposed) notifyListeners();
  }

  @override
  void dispose() {
    _notifierDisposed = true;
    unawaited(close());
    super.dispose();
  }
}
