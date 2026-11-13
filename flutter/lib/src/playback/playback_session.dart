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

  /// ホームへ出た時に自動で小窓へ入ってよいかを native へ知らせる。
  /// 幅・高さは整数で渡し、OS が受け付ける縦横比の範囲へ native で収める。
  void armPip(PlaybackSession session, bool armed, int width, int height);

  /// 端末の設定でこのアプリの小窓が許可されているか。
  Future<bool> pipPermitted(PlaybackSession session);

  /// このアプリの小窓の設定画面（無ければアプリ情報）を開く。
  Future<void> openPipSettings(PlaybackSession session);
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
    bool Function()? isLocked,
  }) => PlaybackSession._(
    this,
    'r2g-$_prefix-${++_nextId}',
    controller,
    authorize,
    backgroundBudget,
    onRelock,
    onPipBackground ?? () {},
    canEnterPip ?? () => true,
    isLocked ?? () => false,
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
    this._isLocked,
  );

  final PlaybackCoordinator coordinator;
  final String id;
  final VideoPlayerController controller;
  final Future<bool> Function() _authorize;
  final Future<Duration?> Function() _backgroundBudget;
  final VoidCallback _onRelock;
  final VoidCallback _onPipBackground;
  final bool Function() _canEnterPip;
  final bool Function() _isLocked;
  int? nativePlayerId;
  bool foreground = true;
  bool _backgroundPaused = false;
  bool backgroundAllowed = false;
  bool pip = false;
  bool pipPending = false;
  bool pipSupported = false;
  // 端末の設定で小窓が許可されていない時に true。メッセージと一緒に「設定を開く」を出す。
  bool pipSettingsNeeded = false;
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
  // native へ「ホームへ出たら自動で小窓に入ってよい」と知らせている間だけ true。
  bool _pipArmed = false;
  int _armedWidth = 0;
  int _armedHeight = 0;
  // 自動で入るつもりでホームへ出てから、小窓の開始通知が来るまでの待ち。
  bool _autoPipWait = false;
  bool _closePipRequested = false;
  Timer? _autoPipTimer;
  String? message;

  bool get live => !closed && !_closing && identical(coordinator.current, this);
  bool get mayPlayHere =>
      foreground || backgroundAllowed || pip || pipPending || _autoPipWait;
  bool get pipArmed => _pipArmed;
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
    // OS は inactive の通知より先に小窓へ入り始めるので、知らせ済みだったかをここで控える
    final wasArmed = _pipArmed;
    var suspendNow = false;
    foreground = state == AppLifecycleState.resumed;
    if (foreground) {
      _clearAutoPipWait();
    } else if (state != AppLifecycleState.inactive) {
      // 画面が止まったなら小窓には入っていない（小窓の間は inactive のまま）。待たずに従来の動きへ戻す。
      suspendNow = _autoPipWait && !pip && !pipPending;
      _clearAutoPipWait();
    } else if (wasForeground && wasArmed && !pip && !pipPending) {
      _startAutoPipWait();
    }
    _syncPipArm();
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
      if ((wasForeground || suspendNow) && !mayPlayHere) {
        await _suspendForBackground();
      }
      if (state == AppLifecycleState.detached) {
        await close();
      } else {
        await _scheduleBudget();
      }
    }
  }

  Future<void> _suspendForBackground() async {
    _resume = controller.value.isPlaying;
    ++_intent;
    await controller.pause();
    await _focusRun;
    if (!foreground && !mayPlayHere) await coordinator.audio(false);
  }

  void _startAutoPipWait() {
    _autoPipWait = true;
    _autoPipTimer?.cancel();
    // OS に自動の小窓を断られた端末は、従来どおりの背景再生の方針へ戻す。
    _autoPipTimer = Timer(const Duration(seconds: 2), () {
      _autoPipWait = false;
      if (!live || foreground || pip || pipPending || mayPlayHere) return;
      unawaited(_suspendForBackground());
    });
  }

  void _clearAutoPipWait() {
    _autoPipWait = false;
    _autoPipTimer?.cancel();
  }

  /// ホームへ出た時に OS が自動で小窓へ入ってよい状態かを native へ知らせる。
  /// 再生中・この画面・ロック中でない・毎回ロックでない時だけ true。
  void _syncPipArm() {
    final v = controller.value;
    final size = v.size;
    final width = size.width.isFinite ? size.width.round() : 0;
    final height = size.height.isFinite ? size.height.round() : 0;
    final armed =
        live &&
        _bound &&
        pipSupported &&
        foreground &&
        !pip &&
        !pipPending &&
        v.isInitialized &&
        v.isPlaying &&
        !v.isCompleted &&
        !v.hasError &&
        !_isLocked() &&
        _canEnterPip();
    if (armed == _pipArmed &&
        (!armed || (width == _armedWidth && height == _armedHeight))) {
      return;
    }
    _pipArmed = armed;
    _armedWidth = width;
    _armedHeight = height;
    _port.armPip(this, armed, width, height);
  }

  Future<void> _scheduleBudget() async {
    _budgetTimer?.cancel();
    if ((foreground && !pip) || !_backgroundPaused || !live || !mayPlayHere) {
      return;
    }
    final generation = _visibilityGeneration;
    final budget = await _backgroundBudget();
    if (!live || (foreground && !pip) || generation != _visibilityGeneration) {
      return;
    }
    if (budget == null) return;
    _budgetTimer = Timer(budget < Duration.zero ? Duration.zero : budget, () {
      if (!live || (foreground && !pip)) return;
      _onRelock();
      unawaited(stop());
    });
  }

  Future<bool> enterPip(Rect rect) async {
    final intent = _intent;
    pipSettingsNeeded = false;
    if (!pipSupported || !foreground) return false;
    // 入れない理由は原因ごとに伝える。汎用の文言だけでは次の一手が分からない。
    if (_isLocked()) {
      message = 'ロック中は小窓で再生できません';
      _notify();
      return false;
    }
    if (!_canEnterPip()) {
      message = '画面ロックの猶予が「毎回ロック」のため、小窓では再生できません';
      _notify();
      return false;
    }
    if (!await _allowed(intent)) return false;
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
        final permitted = await _pipPermitted();
        pipSettingsNeeded = !permitted;
        message = permitted
            ? '小窓再生はこの端末または設定では利用できません'
            : '端末の設定で、このアプリの小窓表示が許可されていません';
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

  Future<bool> _pipPermitted() async {
    try {
      return await _port.pipPermitted(this);
    } catch (_) {
      // 調べられない時は許可の問題と決めつけず、設定画面への誘導を出さない。
      return true;
    }
  }

  Future<void> openPipSettings() async {
    try {
      await _port.openPipSettings(this);
    } catch (_) {
      // 設定画面を開けない端末でも、再生は止めない。
    }
  }

  void _markPipBackground() {
    // PiPはpausedにならずinactiveのまま見え続ける端末でも、同じ猶予を数える。
    _onPipBackground();
    _backgroundPaused = true;
  }

  /// [restoring] は native が閉じた時点の画面の状態で決めた値。
  /// true=「元に戻す」、false=×で閉じた、null=古い経路で不明（時間差で見分ける）。
  void pipChanged(bool active, {bool? restoring, bool failed = false}) {
    if (!live) return;
    // 自動で入る設定の時は、OS が先に入るので Dart が頼んでいなくても受け入れる。
    if (active && !pipPending && !pip && !_autoPipWait && !_pipArmed) {
      unawaited(_port.exitPip(this));
      return;
    }
    pipPending = false;
    pip = active;
    _clearAutoPipWait();
    if (active) _syncPipArm();
    _pipExitTimer?.cancel();
    if (failed) message = '小窓を開始できませんでした';
    _notify();
    unawaited(_port.visibility(this));
    if (active) {
      _markPipBackground();
      unawaited(_scheduleBudget());
    }
    if (!active && restoring == false) {
      // ×で閉じたと native が決めた。時間差を待たずに止める。
      backgroundAllowed = false;
      unawaited(stop());
    } else if (!active) {
      // 古い経路でだけ、通常画面への復帰と小窓の閉鎖を、resumed通知が届く余地を置いて分ける。
      _pipExitTimer = Timer(
        restoring == true
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

  /// [closePip] が false の時は、再生が自然に終わった・失敗した場合で、小窓の中ならアプリごと閉じない。
  /// ロック・接続変更・利用者の停止は、小窓も一緒に閉じる。
  Future<void> stop({bool closePip = true}) {
    ++_intent;
    _resume = false;
    _playPending = false;
    _resumePending = false;
    _interrupted = false;
    _budgetTimer?.cancel();
    _pipExitTimer?.cancel();
    _clearAutoPipWait();
    // 閉じない停止が走っている間に閉じる要求が来ても取りこぼさない。
    if (closePip) _closePipRequested = true;
    return _stopRun ??= _stop().whenComplete(() {
      _stopRun = null;
      if (_closePipRequested) {
        _closePipRequested = false;
        unawaited(_port.exitPip(this));
      }
    });
  }

  Future<void> _stop() async {
    if (closed) return;
    _bound = false;
    _syncPipArm();
    if (_closePipRequested) {
      pip = false;
      pipPending = false;
    }
    await controller.pause();
    if (_closePipRequested) {
      _closePipRequested = false;
      await _port.exitPip(this);
    }
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
    _syncPipArm();
    if (controller.value.isCompleted || controller.value.hasError) {
      // 小窓の中で終わってもアプリは閉じず、戻した時に終了表示を出す
      if (_bound) unawaited(stop(closePip: false));
    }
  }

  Future<void> close() => _closeRun ??= _close();

  Future<void> _close() async {
    _closing = true;
    ++_intent;
    _budgetTimer?.cancel();
    _pipExitTimer?.cancel();
    _clearAutoPipWait();
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
