import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../viewer/level_gesture.dart';
import '../viewer/player_system.dart';
import '../viewer/screen_awake.dart';
import 'app_lock_layer.dart';
<<<<<<< HEAD
import 'video_levels.dart';
import 'video_seek_bar.dart';
=======
import '../playback/mobile_playback.dart';
import '../playback/playback_session.dart';
import '../playback/playback_menu.dart';
>>>>>>> archive/integration/video-ux-main-20261022

typedef VideoControllerFactory = VideoPlayerController Function(String url);

VideoPlayerController _networkController(String url) =>
    VideoPlayerController.networkUrl(Uri.parse(url), videoPlayerOptions: MobilePlayback.options());

/// 何も触らなければ操作バーを隠すまでの時間（KMP版と同じ 3.5 秒）。
const controlsAutoHide = Duration(milliseconds: 3500);

/// ビューワー内の動画。KMP版 VideoSurface（Android）と同じ作法:
/// タップで操作バーの開閉、左右ダブルタップで±10秒、明示したパネルから明るさ・動画の音量、
/// 操作ロック、読み込み中の表示、一時停止中の中央アイコン、終了時のリプレイ、失敗時のリトライ。
/// 明るさ・音量は隠れたジェスチャーだけに頼らず、操作バーの「明るさ・音量」からスライダーでも変えられる（#198）。
class VideoView extends StatefulWidget {
  final String url;

  /// ページ送りで隣のページも組み立てられる。いま見ているページだけ音を出す。
  final bool active;

  /// 下に重なるビューワーの操作バーの高さ。再生バーをその上に出す。
  final double bottomInset;

  /// 操作バーの表示が変わった時（タップでも自動で隠れた時も）。ビューワーの上下バーを追従させる。
  final ValueChanged<bool>? onControlsVisibleChange;

  final VideoControllerFactory controllerFactory;
  final PlayerSystem system;
  final ScreenAwakeCoordinator? screenAwake;
  final PlaybackCoordinator? playbackCoordinator;
  final String? playbackLibrary;

  VideoView({
    super.key,
    required this.url,
    this.active = true,
    this.bottomInset = 0,
    this.onControlsVisibleChange,
    VideoControllerFactory? controllerFactory,
    PlayerSystem? system,
<<<<<<< HEAD
  }) : controllerFactory = controllerFactory ?? _networkController,
       system = system ?? PlatformPlayerSystem();
=======
    this.screenAwake,
    this.playbackCoordinator,
    this.playbackLibrary,
  })  : controllerFactory = controllerFactory ?? _networkController,
        system = system ?? PlatformPlayerSystem();
>>>>>>> archive/integration/video-ux-main-20261022

  @override
  State<VideoView> createState() => _VideoViewState();
}

class _VideoViewState extends State<VideoView>
    with WidgetsBindingObserver, PauseOnLock {
  late VideoPlayerController _c;
  PlaybackBinding? _playback;
  final _surfaceKey = GlobalKey();
  PlaybackSession? get _session => _playback?.session;
  bool get _pipMode => (_session?.pip ?? false) || (_session?.pipPending ?? false);
  bool _initFailed = false;
  bool _started = false;
  bool _initializing = false;
  Duration _resumePosition = Duration.zero;
  bool _controls = true;
  bool _locked = false;
  Timer? _hideTimer;
  Object? _hideKey;

  bool _seeking = false;

<<<<<<< HEAD
  _DragTarget? _drag;
  LevelGesture? _gesture;
  double _dragDy = 0;
  double _lastDragSet = -1;
  int? _volumePct;
  int? _brightPct;
=======
  bool _adjustments = false;
  bool _brightnessLoading = false;
  bool _brightnessBusy = false;
  double? _brightness;
  String? _brightnessError;
  int _brightnessRead = 0;
>>>>>>> archive/integration/video-ux-main-20261022
  bool _touchedBrightness = false;
  // 画面に出す明るさ・音量。端末から読めた実値だけを入れる（読めなければ null）
  double? _volume;
  double? _brightness;
  // 端末の音量が読めない環境（web）では、この動画だけの音量を動かす
  bool _volumeViaPlayer = false;
  // 読めた / 読めなかった。読む前は null
  bool? _brightnessReadable;
  bool? _volumeReadable;
  // 明るさが読めない理由が端末の自動調整か。読めない時だけ意味を持つ
  bool _brightnessAuto = false;
  bool _panelOpen = false;
  bool _sliding = false;
  Timer? _syncTimer;
  String? _notice;
  Timer? _noticeTimer;
  // 背面へ回った時に端末の明るさへ戻し、前に戻ったらこの値を付け直す
  double? _userBrightness;
  Offset? _doubleTapAt;
  // 背面に回る前に再生中だったか。戻った時にだけ再開するための印（#141）
  bool _wasPlaying = false;
  // 初期化が終わる前に背面へ回ることがあるので、コントローラの状態と別に覚えておく
  bool _background = false;
  int _resumeGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final life = WidgetsBinding.instance.lifecycleState;
    _background = life != null && life != AppLifecycleState.resumed;
    _create();
    // 送った先のページで操作が出ているなら、ビューワーの上下バーも出し直す
    _reportControlsAfterFrame();
  }

  // 親の組み立て中に呼ばれる所から使うので、親の setState は描き終わってから
  void _reportControlsAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.active) {
        widget.onControlsVisibleChange?.call(_controls && !_pipMode && !(_session?.closed ?? false));
      }
    });
  }

  void _create() {
    _seeking = false;
    final c = widget.controllerFactory(widget.url);
    _c = c;
    _playback = PlaybackBinding.attach(controller: c,
      app: AppLockScope.maybeOf(context), library: widget.playbackLibrary,
      coordinator: widget.playbackCoordinator);
    _session?.addListener(_onPlaybackChanged);
    _initFailed = false;
    _started = false;
    _initializing = false;
    c.addListener(_onTick);
<<<<<<< HEAD
    c
        .initialize()
        .then((_) {
          if (!mounted || c != _c) return;
          setState(() {});
          _maybeStart();
        })
        .catchError((Object e) {
          debugPrint('video init failed: $e');
          if (!mounted || c != _c) return;
          setState(() => _initFailed = true);
          _setControls(true);
        });
=======
    // PageViewの隣ページは準備だけに留め、可視動画のdecoder所有権を奪わない。
    if (_session == null || widget.active) _initializeController(c);
  }

  void _initializeController(VideoPlayerController c) {
    if (_initializing) return;
    _initializing = true;
    (_session?.initialize() ?? c.initialize()).then<void>((_) async {
      if (!mounted || c != _c) return;
      if (_resumePosition > Duration.zero) {
        await c.seekTo(_resumePosition);
      }
    }).then((_) {
      if (!mounted || c != _c) return;
      setState(() {});
      _maybeStart();
    }).catchError((Object _) {
      debugPrint('video initialization failed');
      if (!mounted || c != _c) return;
      setState(() => _initFailed = true);
      _setControls(true);
    });
>>>>>>> archive/integration/video-ux-main-20261022
  }

  void _onPlaybackChanged() {
    if (!mounted) return;
    setState(() {});
    if (widget.active) {
      widget.onControlsVisibleChange?.call(_controls && !_pipMode && !(_session?.closed ?? false));
    }
  }

  // ロック中や裏のページで読み込みが終わった時は、見えない所で音だけ流さないよう始めない
  void _maybeStart() {
    if (_started || !widget.active || isAppLocked) return;
    if (!_c.value.isInitialized) return;
    _started = true;
    // 読み込み中に背面へ回っていたら、ここで鳴らさず戻った時に再生する
    if (_background) {
      _wasPlaying = true;
      return;
    }
    unawaited(_resumeAfterForeground(_c, ++_resumeGeneration));
  }

  Future<void> _resumeAfterForeground(VideoPlayerController controller, int generation,
      {bool replay = false}) async {
    bool mayPlay() {
      if (!mounted || controller != _c || generation != _resumeGeneration ||
          !widget.active || _background || isAppLocked ||
          !controller.value.isInitialized) {
        return false;
      }
      final life = WidgetsBinding.instance.lifecycleState;
      return life == null || life == AppLifecycleState.resumed;
    }

    if (!mayPlay()) return;
    final app = AppLockScope.maybeOf(context);
    try {
      if (app != null) {
        // 同じ復帰通知を受ける外側の監視役が、ロック判定を始めるまで待つ。
        await Future<void>.value();
        await app.foregroundSettled;
      }
      // 手動の再生・リプレイも、復帰時の認証判定を追い越さない。
      if (!mayPlay()) return;
      if (replay) {
        await controller.seekTo(Duration.zero);
        if (!mayPlay()) return;
      }
      final session = _session;
      if (session != null) {
        await session.play();
      } else {
        await controller.play();
      }
    } catch (_) {
      // 再生開始の非同期失敗を外へ漏らさず、現在のプレイヤーにだけ再試行を出す。
      if (mayPlay()) {
        try {
          await controller.pause();
        } catch (_) {
          // 再生器自身が壊れている場合も、再試行の表示へ戻す。
        }
        if (!mayPlay()) return;
        setState(() => _initFailed = true);
        _setControls(true);
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final session = _session;
    if (session != null) {
      _background = state != AppLifecycleState.resumed;
      _resumeGeneration++;
      unawaited(session.lifecycle(state));
      return;
    }
<<<<<<< HEAD
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _releaseBrightness();
      case AppLifecycleState.resumed:
        _restoreBrightness();
        _syncLevels();
      case AppLifecycleState.detached:
        break;
    }
=======
    _background = state != AppLifecycleState.resumed;
    if (_background) _resumeGeneration++;
>>>>>>> archive/integration/video-ux-main-20261022
    if (!_c.value.isInitialized) return;
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        // inactive → paused と続けて来るので、2 回目で false に上書きしない
        if (_c.value.isPlaying) {
          _wasPlaying = true;
          _c.pause();
        }
      case AppLifecycleState.resumed:
        // ロック中に戻った時は鳴らさない（解除後に自分で再生する）
        if (_wasPlaying && mounted && widget.active && !isAppLocked) {
          unawaited(_resumeAfterForeground(_c, ++_resumeGeneration));
        }
        _wasPlaying = false;
      case AppLifecycleState.detached:
        _wasPlaying = false;
        _c.pause();
    }
  }

  bool get _failed => _initFailed || _c.value.hasError;

  bool get _ended {
    final v = _c.value;
    if (!v.isInitialized || v.isPlaying) return false;
    return v.isCompleted ||
        (v.duration > Duration.zero && v.position >= v.duration);
  }

  bool get _buffering =>
      !_failed && !_ended && (!_c.value.isInitialized || _c.value.isBuffering);

  void _onTick() {
    if (!mounted) return;
    setState(() {});
    // 終わった・失敗した時は操作を出し直す（リプレイ・リトライに気づけるように）
    if ((_ended || _c.value.hasError) && !_controls) _setControls(true);
    _scheduleHide();
  }

  void _setControls(bool v) {
    if (_controls != v) {
      setState(() {
        _controls = v;
<<<<<<< HEAD
        if (!v) {
          _seeking = false;
          _closePanel();
        }
      });
    }
    if (widget.active) widget.onControlsVisibleChange?.call(v);
=======
        if (!v) _adjustments = false;
      });
    }
    if (widget.active) widget.onControlsVisibleChange?.call(v && !_pipMode);
>>>>>>> archive/integration/video-ux-main-20261022
    _scheduleHide();
  }

  /// 再生中に操作バーを出したままにしない。条件が変わった時だけ数え直す（位置更新のたびには延ばさない）。
  void _scheduleHide({bool restart = false}) {
    final playing = _c.value.isPlaying;
<<<<<<< HEAD
    final key = (_controls, playing, _ended, _locked, _panelOpen, _seeking);
    if (!restart && key == _hideKey) return;
    _hideKey = key;
    _hideTimer?.cancel();
    if (_controls &&
        playing &&
        !_ended &&
        !_locked &&
        !_panelOpen &&
        !_seeking) {
=======
    final key = (_controls, playing, _ended, _locked, _adjustments, _seeking);
    if (!restart && key == _hideKey) return;
    _hideKey = key;
    _hideTimer?.cancel();
    if (_controls && playing && !_ended && !_locked && !_adjustments && !_seeking) {
>>>>>>> archive/integration/video-ux-main-20261022
      _hideTimer = Timer(controlsAutoHide, () {
        if (mounted) _setControls(false);
      });
    }
  }

  @override
  void onLocked() {
    _resumeGeneration++;
    if (_session != null) {
      unawaited(_session!.stop());
    } else {
      _c.pause();
    }
    // 解除後に勝手に鳴り出さんよう、背面から戻った時の再開の印も消す
    _wasPlaying = false;
  }

  @override
  void didUpdateWidget(VideoView old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _resumeGeneration++;
      _resumePosition = Duration.zero;
      _disposeController();
      _create();
      return;
    }
    if (_session != null && old.active != widget.active) {
      _resumeGeneration++;
      if (!widget.active) {
        _resumePosition = _c.value.position;
        _disposeController();
        _create();
      } else {
        if (_session!.closed) {
          _disposeController();
          _create();
        } else {
          _initializeController(_c);
        }
        _reportControlsAfterFrame();
      }
      return;
    }
    if (!widget.active) {
      _resumeGeneration++;
      if (_c.value.isPlaying) {
        if (_session != null) { unawaited(_session!.pause()); } else { _c.pause(); }
      }
    }
    if (widget.active && !old.active) {
      _maybeStart();
      _reportControlsAfterFrame();
    }
  }

  void _disposeController() {
    _c.removeListener(_onTick);
    final playback = _playback;
    _playback = null;
    if (playback != null) {
      playback.session.removeListener(_onPlaybackChanged);
      unawaited(playback.close());
    } else {
      _c.dispose();
    }
  }

  @override
  void dispose() {
    _resumeGeneration++;
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _syncTimer?.cancel();
    _noticeTimer?.cancel();
    _disposeController();
    if (_touchedBrightness) widget.system.resetBrightness();
    super.dispose();
  }

  void _seekTo(Duration d) {
    if (!_c.value.isInitialized) return;
    final dur = _c.value.duration;
    final t = d < Duration.zero ? Duration.zero : (d > dur ? dur : d);
    if (_session != null) { unawaited(_session!.seek(t)); } else { _c.seekTo(t); }
    _scheduleHide(restart: true);
  }

  void _skip(int seconds) =>
      _seekTo(_c.value.position + Duration(seconds: seconds));

  void _togglePlay() {
    final generation = ++_resumeGeneration;
    _wasPlaying = false;
    if (_c.value.isPlaying || (_session?.hasPlayIntent ?? false)) {
      if (_session != null) { unawaited(_session!.pause()); } else { _c.pause(); }
    } else {
      _started = true;
      unawaited(_resumeAfterForeground(_c, generation));
    }
    _scheduleHide(restart: true);
  }

  void _replay() {
    final generation = ++_resumeGeneration;
    _wasPlaying = false;
    _started = true;
    unawaited(_resumeAfterForeground(_c, generation, replay: true));
  }

  void _retry() {
    _disposeController();
    setState(_create);
  }

  void _lockControls() {
    _resumeGeneration++;
    _wasPlaying = false;
    setState(() => _locked = true);
    _setControls(false);
  }

  void _unlockControls() {
    setState(() => _locked = false);
    _setControls(true);
  }

<<<<<<< HEAD
  // ---- 明るさ・音量（ドラッグとスライダー） ----

  /// 端末の値を読む。音量が端末から読めない環境ではこの動画の音量を使う。
  Future<double?> _readVolume() async {
    final v = await widget.system.volume();
    if (v != null) {
      _volumeViaPlayer = false;
      return v;
    }
    _volumeViaPlayer = true;
    return _c.value.isInitialized ? _c.value.volume : null;
  }

  Future<void> _writeVolume(double v) async {
    if (_volumeViaPlayer) {
      await _c.setVolume(v);
      return;
    }
    await widget.system.setVolume(v);
  }

  Future<void> _writeBrightness(double v) async {
    _touchedBrightness = true;
    _userBrightness = v;
    await widget.system.setBrightness(v);
  }

  // 背面へ回る間は端末の明るさに戻す。他のアプリや小窓の裏で明るさを残さない（#198）
  void _releaseBrightness() {
    if (_touchedBrightness) widget.system.resetBrightness();
  }

  void _restoreBrightness() {
    final b = _userBrightness;
    if (_touchedBrightness && b != null) widget.system.setBrightness(b);
  }

  void _showNotice(String text) {
    _noticeTimer?.cancel();
    setState(() => _notice = text);
    _noticeTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _notice = null);
    });
  }

  static const _brightnessUnavailable = 'この環境では明るさを変えられません。端末の設定から変えてください';
  static const _brightnessAutoUnavailable =
      '端末が明るさを自動調整中で、いまの明るさを読めません。端末の設定で自動調整をオフにすると変えられます';
  static const _volumeUnavailable = 'この環境では音量を変えられません。端末の音量ボタンを使ってください';

  /// パネルの値を端末の実値に合わせる（音量ボタンや設定での変更、復帰後の変化に追従する）。
  Future<void> _syncLevels() async {
    if (!mounted || _sliding || _drag != null) return;
    final vol = await _readVolume();
    final bright = await widget.system.brightness();
    final auto = bright == null && await widget.system.brightnessAuto();
    if (!mounted || _sliding || _drag != null) return;
    setState(() {
      _volume = vol;
      _volumeReadable = vol != null;
      _brightness = bright;
      _brightnessReadable = bright != null;
      _brightnessAuto = auto;
    });
  }

  void _openPanel() {
    setState(() => _panelOpen = true);
    _scheduleHide(restart: true);
    _syncLevels();
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _syncLevels(),
    );
  }

  void _closePanel() {
    _panelOpen = false;
    _syncTimer?.cancel();
    _syncTimer = null;
  }

  void _togglePanel() {
    if (_panelOpen) {
      setState(_closePanel);
      _scheduleHide(restart: true);
    } else {
      _openPanel();
    }
  }

  void _slideBrightness(double v) {
    final next = v
        .clamp(LevelGesture.minBrightness, LevelGesture.maxBrightness)
        .toDouble();
    setState(() => _brightness = next);
    _writeBrightness(next);
  }

  void _slideVolume(double v) {
    final next = v
        .clamp(LevelGesture.minVolume, LevelGesture.maxVolume)
        .toDouble();
    setState(() => _volume = next);
    _writeVolume(next);
  }

  void _dragStart(DragStartDetails d, double width) {
    if (!_c.value.isInitialized) return;
    final target = d.localPosition.dx > width / 2
        ? _DragTarget.volume
        : _DragTarget.brightness;
    _drag = target;
    _gesture = null;
    _dragDy = 0;
    _lastDragSet = -1;
    final read = target == _DragTarget.volume
        ? _readVolume()
        : widget.system.brightness();
    read.then((v) async {
      if (!mounted || _drag != target) return;
      if (v == null) {
        // 読めない値から動かすと値が飛ぶので、動かさずに理由を出す
        if (target == _DragTarget.volume) {
          _showNotice(_volumeUnavailable);
          return;
        }
        final auto = await widget.system.brightnessAuto();
        if (!mounted || _drag != target) return;
        _brightnessAuto = auto;
        _showNotice(auto ? _brightnessAutoUnavailable : _brightnessUnavailable);
        return;
      }
      final isVolume = target == _DragTarget.volume;
      final g = LevelGesture(
        base: v,
        min: isVolume ? LevelGesture.minVolume : LevelGesture.minBrightness,
        max: isVolume ? LevelGesture.maxVolume : LevelGesture.maxBrightness,
      );
      _gesture = g;
      // 触った時点の実値をすぐ見せる。動かす前から何を変える操作か分かる
      setState(() {
        if (isVolume) {
          _volume = g.level;
          _volumePct = percentOf(g.level);
        } else {
          _brightness = g.level;
          _brightnessReadable = true;
          _brightPct = percentOf(g.level);
        }
      });
      // 読み込み待ちの間に動いた分を反映する
      if (_dragDy != 0) _applyDrag(g, _dragDy, _lastHeight);
    });
  }

  double _lastHeight = 0;

  void _dragUpdate(DragUpdateDetails d, double height) {
    _lastHeight = height;
    final g = _gesture;
    if (g == null) {
      _dragDy += d.delta.dy;
      return;
    }
    _applyDrag(g, d.delta.dy, height);
  }

  void _applyDrag(LevelGesture g, double dy, double height) {
    final next = g.update(dy, height);
    // 一度も動かしていない間は書かない。動かした後に起点へ戻した時は、戻した値を書く
    if (next == _lastDragSet || (_lastDragSet < 0 && !g.moved)) return;
    _lastDragSet = next;
    if (_drag == _DragTarget.volume) {
      setState(() {
        _volume = next;
        _volumePct = percentOf(next);
      });
      _writeVolume(next);
    } else {
      setState(() {
        _brightness = next;
        _brightPct = percentOf(next);
      });
      _writeBrightness(next);
    }
  }

  void _dragEnd() {
    _drag = null;
    _gesture = null;
=======
  // ---- 明示したパネルからだけ明るさ・音量を調整する ----

  void _toggleAdjustments() {
    setState(() => _adjustments = !_adjustments);
    _scheduleHide(restart: true);
    if (_adjustments) unawaited(_readBrightness());
  }

  Future<void> _readBrightness() async {
    // 設定の確定前に取り直すと、遅い旧値で表示と次の変更の起点が戻る。
    if (_brightnessBusy) return;
    final request = ++_brightnessRead;
    setState(() {
      _brightnessLoading = true;
      _brightnessError = null;
    });
    double? value;
    try {
      value = await widget.system.brightness();
    } catch (_) {
      // 読めない明るさを推測して上書きすると、操作前より突然明るくなる。
    }
    if (!mounted || request != _brightnessRead) return;
    final current = value;
    setState(() {
      _brightnessLoading = false;
      _brightness = current != null && current.isFinite && current >= 0 && current <= 1
          ? current : null;
      if (_brightness == null) {
        _brightnessError = '現在の明るさを確認できません。端末側で調整してください（自動調整中など）。';
      }
    });
  }

  Future<void> _setBrightness(double target) async {
    final base = _brightness;
    if (base == null || _brightnessLoading || _brightnessBusy) return;
    // トラックの遠い所を押しても一度に跳ね上げず、確認済みの値から5ポイントずつ動かす。
    final next = target.clamp(base - 0.05, base + 0.05).clamp(0.02, 1.0).toDouble();
    setState(() => _brightnessBusy = true);
    _touchedBrightness = true;
    double? actual;
    try {
      actual = await widget.system.setBrightness(next);
    } catch (_) {
      // 設定できなかった値を、設定済みとして画面に出さない。
    }
    if (!mounted) return;
    final current = actual;
>>>>>>> archive/integration/video-ux-main-20261022
    setState(() {
      _brightnessBusy = false;
      if (current != null && current.isFinite && current >= 0 && current <= 1) {
        _brightness = current;
      } else {
        _brightness = null;
        _brightnessError = '明るさを変更できませんでした。端末側で調整してください。';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_session?.closed ?? false) {
      return const ColoredBox(color: Colors.black,
        child: Center(child: Text('再生を終了しました。接続を確認して一覧から開き直してください。')));
    }
    final v = _c.value;
    final initialized = v.isInitialized;
    final playing = v.isPlaying;
    final failed = _failed;
    final ended = _ended;
    final buffering = _buffering;

<<<<<<< HEAD
    return LayoutBuilder(
      builder: (context, box) {
        return Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(
              color: Colors.black,
              child: initialized
                  ? Center(
                      child: AspectRatio(
                        aspectRatio: v.aspectRatio,
                        child: VideoPlayer(_c),
                      ),
                    )
                  : const SizedBox.expand(),
            ),
            if (!_locked)
              GestureDetector(
                key: const ValueKey('video-gestures'),
                behavior: HitTestBehavior.opaque,
                onTap: () => _setControls(!_controls),
                onDoubleTapDown: (d) => _doubleTapAt = d.localPosition,
                onDoubleTap: () {
                  final at = _doubleTapAt;
                  if (at == null) return;
                  _skip(at.dx > box.maxWidth / 2 ? 10 : -10);
                },
                onVerticalDragStart: (d) => _dragStart(d, box.maxWidth),
                onVerticalDragUpdate: (d) => _dragUpdate(d, box.maxHeight),
                onVerticalDragEnd: (_) => _dragEnd(),
                onVerticalDragCancel: _dragEnd,
              ),
            if (buffering)
              const Center(
                child: SizedBox(
                  width: 50,
                  height: 50,
                  child: CircularProgressIndicator(
                    key: ValueKey('video-buffering'),
                    color: Colors.white,
                  ),
                ),
              ),
            if (initialized && !playing && !ended && !failed && !buffering)
              Center(
                child: IconButton(
                  key: const ValueKey('video-center-play'),
                  tooltip: '再生',
                  iconSize: 72,
                  icon: Icon(
                    Icons.play_arrow,
                    color: Colors.white.withValues(alpha: 0.9),
                  ),
                  onPressed: _togglePlay,
                ),
              ),
            if (failed)
              _Overlay(
                text: '再生できませんでした',
                icon: Icons.replay,
                label: 'リトライ',
                onTap: _retry,
              ),
            if (ended && !failed)
              _Overlay(
                text: '再生が終了しました',
                icon: Icons.replay,
                label: 'リプレイ',
                onTap: _replay,
              ),
            if (_brightPct != null)
              Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.only(top: 96),
                  child: LevelBadge(
                    key: const ValueKey('brightness-indicator'),
                    icon: Icons.wb_sunny,
                    label: '明るさ',
                    percent: _brightPct!,
                  ),
                ),
              ),
            if (_volumePct != null)
              Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.only(top: 96),
                  child: LevelBadge(
                    key: const ValueKey('volume-indicator'),
                    icon: Icons.volume_up,
                    label: '音量',
                    percent: _volumePct!,
                  ),
                ),
              ),
            if (_controls && initialized && !ended && !failed && !_locked) ...[
              const Positioned(
                left: 8,
                top: 0,
                bottom: 0,
                child: Center(
                  child: LevelEdgeHint(
                    key: ValueKey('edge-hint-brightness'),
                    icon: Icons.wb_sunny,
                    label: '明るさ',
                  ),
                ),
              ),
              const Positioned(
                right: 8,
                top: 0,
                bottom: 0,
                child: Center(
                  child: LevelEdgeHint(
                    key: ValueKey('edge-hint-volume'),
                    icon: Icons.volume_up,
                    label: '音量',
                  ),
                ),
              ),
            ],
            if (_notice != null)
              Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 96, 24, 0),
                  child: Container(
                    key: const ValueKey('level-notice'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xCC000000),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      _notice!,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ),
                ),
              ),
            if (_controls &&
                initialized &&
                (!ended || _seeking) &&
                !failed &&
                !_locked)
              Positioned(
                left: 0,
                right: 0,
                bottom: widget.bottomInset,
                child: _controlBar(v),
              ),
            if (_locked)
              Positioned(
                left: 10,
                bottom: widget.bottomInset + 10,
                child: IconButton(
                  tooltip: '解除',
                  icon: const Icon(Icons.lock, color: Colors.white),
                  onPressed: _unlockControls,
                ),
              ),
          ],
        );
      },
=======
    final content = LayoutBuilder(builder: (context, box) {
      return Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(
            color: Colors.black,
            child: initialized
                ? Center(
                    child: AspectRatio(
                      aspectRatio: v.aspectRatio,
                      child: VideoPlayer(_c),
                    ),
                  )
                : const SizedBox.expand(),
          ),
          if (!_locked && !_pipMode)
            GestureDetector(
              key: const ValueKey('video-gestures'),
              behavior: HitTestBehavior.opaque,
              onTap: () => _setControls(!_controls),
              onDoubleTapDown: (d) => _doubleTapAt = d.localPosition,
              onDoubleTap: () {
                final at = _doubleTapAt;
                if (at == null) return;
                _skip(at.dx > box.maxWidth / 2 ? 10 : -10);
              },
            ),
          if (buffering)
            const Center(
              child: SizedBox(
                width: 50,
                height: 50,
                child: CircularProgressIndicator(
                    key: ValueKey('video-buffering'), color: Colors.white),
              ),
            ),
          if (initialized && !playing && !ended && !failed && !buffering && !_pipMode && !(_session?.hasPlayIntent ?? false))
            Center(
              child: IconButton(
                key: const ValueKey('video-center-play'),
                tooltip: '再生',
                iconSize: 72,
                icon: Icon(Icons.play_arrow,
                    color: Colors.white.withValues(alpha: 0.9)),
                onPressed: _togglePlay,
              ),
            ),
          if (failed)
            _Overlay(
              text: '再生できませんでした',
              icon: Icons.replay,
              label: 'リトライ',
              onTap: _retry,
            ),
          if (ended && !failed)
            _Overlay(
              text: '再生が終了しました',
              icon: Icons.replay,
              label: 'リプレイ',
              onTap: _replay,
            ),
          if (_controls && initialized && !ended && !failed && !_locked && !_pipMode)
            Positioned(
              left: 0,
              right: 0,
              bottom: widget.bottomInset,
              child: SafeArea(
                top: false,
                // 親の作品操作バーがある時は、その高さに下端の安全領域も含まれる。
                bottom: widget.bottomInset == 0,
                child: _controlBar(v),
              ),
            ),
          if (_locked && !_pipMode)
            Positioned(
              left: 0,
              right: 0,
              bottom: widget.bottomInset,
              child: SafeArea(
                top: false,
                bottom: widget.bottomInset == 0,
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: IconButton(
                      tooltip: '解除',
                      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                      icon: const Icon(Icons.lock, color: Colors.white),
                      onPressed: _unlockControls,
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    });
    return PlaybackScreenAwake(
      key: _surfaceKey,
      controller: _c,
      active: widget.active && !_background && !isAppLocked,
      coordinator: widget.screenAwake,
      child: content,
    );
  }

  Widget _controlButton(String label, IconData icon, VoidCallback onPressed,
      {double iconSize = 24}) => SizedBox.square(
        dimension: 48,
        child: IconButton(
          tooltip: label,
          iconSize: iconSize,
          padding: const EdgeInsets.all(4),
          icon: Icon(icon, color: Colors.white),
          onPressed: onPressed,
        ),
      );

  Widget _adjustmentPanel(VideoPlayerValue v) {
    final media = MediaQuery.of(context);
    final height = (media.size.height - widget.bottomInset - media.padding.top - 300)
        .clamp(64.0, 240.0).toDouble();
    final brightness = _brightness;
    final volume = v.volume.clamp(0.0, 1.0).toDouble();
    const text = TextStyle(color: Colors.white, fontSize: 12);
    return Container(
      key: const ValueKey('video-adjustments'),
      color: const Color(0xE6000000),
      constraints: BoxConstraints(maxHeight: height),
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              const Expanded(child: Text('明るさ・音量', style: text)),
              _controlButton('調整を閉じる', Icons.close, _toggleAdjustments),
            ]),
            Text('この動画の音量 ${(volume * 100).round()}%', style: text),
            Semantics(
              label: 'この動画の音量',
              child: Slider(
                key: const ValueKey('video-volume-slider'),
                value: volume,
                divisions: 100,
                semanticFormatterCallback: (x) => '${(x * 100).round()}%',
                onChanged: (x) => unawaited(_c.setVolume(x)),
              ),
            ),
            Text(_brightnessLoading
                ? 'この画面の明るさを確認中…'
                : 'この画面の明るさ ${brightness == null ? '不明' : '${(brightness * 100).round()}%'}',
                style: text),
            Semantics(
              label: 'この画面の明るさ',
              child: Slider(
                key: const ValueKey('video-brightness-slider'),
                value: brightness?.clamp(0.02, 1.0).toDouble() ?? 0.02,
                min: 0.02,
                divisions: 98,
                semanticFormatterCallback: (x) => _brightnessLoading
                    ? '確認中'
                    : brightness == null ? '現在値不明' : '${(x * 100).round()}%',
                onChanged: brightness == null || _brightnessLoading || _brightnessBusy
                    ? null : (x) => unawaited(_setBrightness(x)),
              ),
            ),
            Text(_brightnessError ?? '明るさは少しずつ変更します。動画を閉じると元に戻ります。',
                style: text),
          ],
        ),
      ),
>>>>>>> archive/integration/video-ux-main-20261022
    );
  }

  Widget _controlBar(VideoPlayerValue v) {
    final pos = v.position;
    final dur = v.duration;
    return Container(
      key: const ValueKey('video-controls'),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xBF000000), Colors.transparent],
        ),
      ),
      padding: const EdgeInsets.only(bottom: 6),
<<<<<<< HEAD
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_panelOpen)
            LevelPanel(
              brightness: _brightness,
              brightnessReadable: _brightnessReadable,
              brightnessAuto: _brightnessAuto,
              volume: _volume,
              volumeReadable: _volumeReadable,
              onBrightness: _slideBrightness,
              onVolume: _slideVolume,
              onSliding: (v) => _sliding = v,
            ),
          VideoSeekBar(
            position: pos,
            duration: dur,
            format: fmtDuration,
            onSeek: _seekTo,
            onScrubbing: (value) {
              setState(() => _seeking = value);
              _scheduleHide(restart: true);
            },
          ),
          Row(
            children: [
              IconButton(
                tooltip: 'ロック',
                icon: const Icon(Icons.lock_open, color: Colors.white),
                onPressed: _lockControls,
              ),
              const Spacer(),
              IconButton(
                tooltip: '-10秒',
                icon: const Icon(Icons.replay_10, color: Colors.white),
                onPressed: () => _skip(-10),
              ),
              IconButton(
                tooltip: v.isPlaying ? '一時停止' : '再生',
                iconSize: 40,
                icon: Icon(
                  v.isPlaying ? Icons.pause : Icons.play_arrow,
                  color: Colors.white,
                ),
                onPressed: _togglePlay,
              ),
              IconButton(
                tooltip: '+10秒',
                icon: const Icon(Icons.forward_10, color: Colors.white),
                onPressed: () => _skip(10),
              ),
              const Spacer(),
              IconButton(
                key: const ValueKey('level-toggle'),
                tooltip: '明るさ・音量',
                icon: Icon(
                  Icons.tune,
                  color: _panelOpen ? const Color(0xFFFFAE00) : Colors.white,
                ),
                onPressed: _togglePanel,
              ),
            ],
          ),
        ],
      ),
=======
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (_session?.message != null)
          Padding(padding: const EdgeInsets.all(8), child: Text(_session!.message!,
            style: const TextStyle(color: Colors.white, fontSize: 12))),
        if (_adjustments) _adjustmentPanel(v),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: 8,
            children: [
              Text(fmtDuration(shown),
                  style: const TextStyle(color: Colors.white, fontSize: 12)),
              Text(fmtDuration(dur),
                  style: const TextStyle(color: Colors.white, fontSize: 12)),
            ],
          ),
        ),
        Slider(
          value: (_seeking ? _seekTarget : pos.inMilliseconds.toDouble())
              .clamp(0, max < 1 ? 1 : max),
          max: max < 1 ? 1 : max,
          activeColor: Colors.white,
          inactiveColor: Colors.white30,
          onChanged: (x) {
            setState(() {
              _seeking = true;
              _seekTarget = x;
            });
            _scheduleHide();
          },
          onChangeEnd: (x) {
            _seekTo(Duration(milliseconds: x.round()));
            setState(() => _seeking = false);
            _scheduleHide(restart: true);
          },
        ),
        LayoutBuilder(builder: (context, box) {
          final adjustmentWidth = box.maxWidth < 272
              ? (box.maxWidth - 48).clamp(80.0, 180.0).toDouble() : 80.0;
          final buttons = <Widget>[
            _controlButton('ロック', Icons.lock_open, _lockControls),
            _controlButton('-10秒', Icons.replay_10, () => _skip(-10)),
            _controlButton(v.isPlaying || (_session?.hasPlayIntent ?? false) ? '一時停止' : '再生',
                v.isPlaying || (_session?.hasPlayIntent ?? false) ? Icons.pause : Icons.play_arrow, _togglePlay,
                iconSize: 40),
            _controlButton('+10秒', Icons.forward_10, () => _skip(10)),
            SizedBox(
              width: adjustmentWidth,
              child: TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white,
                  minimumSize: const Size(48, 48),
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                ),
                onPressed: _toggleAdjustments,
                child: const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.tune, size: 18),
                    Text('明るさ・音量', textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            ),
            if (_session != null) SizedBox.square(dimension: 48,
              child: PlaybackMenu(session: _session!, surfaceKey: _surfaceKey)),
          ];
          if (box.maxWidth < (_session == null ? 272 : 320)) {
            return Wrap(alignment: WrapAlignment.center, children: buttons);
          }
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: buttons,
          );
        }),
      ]),
>>>>>>> archive/integration/video-ux-main-20261022
    );
  }
}

String fmtDuration(Duration d) {
  if (d <= Duration.zero) return '00:00';
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

class _Overlay extends StatelessWidget {
  final String text;
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _Overlay({
    required this.text,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: ColoredBox(
        color: const Color(0x33000000),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(text, style: const TextStyle(color: Colors.white)),
            const SizedBox(height: 8),
            Icon(icon, color: Colors.white, size: 48, semanticLabel: label),
          ],
        ),
      ),
    );
  }
}
