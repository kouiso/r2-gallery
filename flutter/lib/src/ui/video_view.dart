import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../viewer/level_gesture.dart';
import '../viewer/player_system.dart';
import 'app_lock_layer.dart';
import 'video_levels.dart';

typedef VideoControllerFactory = VideoPlayerController Function(String url);

VideoPlayerController _networkController(String url) =>
    VideoPlayerController.networkUrl(Uri.parse(url));

/// 何も触らなければ操作バーを隠すまでの時間（KMP版と同じ 3.5 秒）。
const controlsAutoHide = Duration(milliseconds: 3500);

/// ビューワー内の動画。KMP版 VideoSurface（Android）と同じ作法:
/// タップで操作バーの開閉、左右ダブルタップで±10秒、左半分の縦ドラッグで明るさ・右半分で音量、
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

  VideoView({
    super.key,
    required this.url,
    this.active = true,
    this.bottomInset = 0,
    this.onControlsVisibleChange,
    VideoControllerFactory? controllerFactory,
    PlayerSystem? system,
  })  : controllerFactory = controllerFactory ?? _networkController,
        system = system ?? PlatformPlayerSystem();

  @override
  State<VideoView> createState() => _VideoViewState();
}

enum _DragTarget { volume, brightness }

class _VideoViewState extends State<VideoView>
    with WidgetsBindingObserver, PauseOnLock {
  late VideoPlayerController _c;
  bool _initFailed = false;
  bool _started = false;
  bool _controls = true;
  bool _locked = false;
  Timer? _hideTimer;
  Object? _hideKey;

  bool _seeking = false;
  double _seekTarget = 0;

  _DragTarget? _drag;
  LevelGesture? _gesture;
  double _dragDy = 0;
  double _lastDragSet = -1;
  int? _volumePct;
  int? _brightPct;
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
        widget.onControlsVisibleChange?.call(_controls);
      }
    });
  }

  void _create() {
    final c = widget.controllerFactory(widget.url);
    _c = c;
    _initFailed = false;
    _started = false;
    c.addListener(_onTick);
    c.initialize().then((_) {
      if (!mounted || c != _c) return;
      setState(() {});
      _maybeStart();
    }).catchError((Object e) {
      debugPrint('video init failed: $e');
      if (!mounted || c != _c) return;
      setState(() => _initFailed = true);
      _setControls(true);
    });
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
    _c.play();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.detached) {
      _background = state != AppLifecycleState.resumed;
    }
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
        if (_wasPlaying && mounted && widget.active && !isAppLocked) _c.play();
        _wasPlaying = false;
      case AppLifecycleState.detached:
        break;
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
        if (!v) _closePanel();
      });
    }
    if (widget.active) widget.onControlsVisibleChange?.call(v);
    _scheduleHide();
  }

  /// 再生中に操作バーを出したままにしない。条件が変わった時だけ数え直す（位置更新のたびには延ばさない）。
  void _scheduleHide({bool restart = false}) {
    final playing = _c.value.isPlaying;
    final key = (_controls, playing, _ended, _locked, _panelOpen);
    if (!restart && key == _hideKey) return;
    _hideKey = key;
    _hideTimer?.cancel();
    if (_controls && playing && !_ended && !_locked && !_panelOpen) {
      _hideTimer = Timer(controlsAutoHide, () {
        if (mounted) _setControls(false);
      });
    }
  }

  @override
  void onLocked() {
    _c.pause();
    // 解除後に勝手に鳴り出さんよう、背面から戻った時の再開の印も消す
    _wasPlaying = false;
  }

  @override
  void didUpdateWidget(VideoView old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _disposeController();
      _create();
      return;
    }
    if (!widget.active && _c.value.isPlaying) _c.pause();
    if (widget.active && !old.active) {
      _maybeStart();
      _reportControlsAfterFrame();
    }
  }

  void _disposeController() {
    _c.removeListener(_onTick);
    _c.dispose();
  }

  @override
  void dispose() {
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
    _c.seekTo(t);
    _scheduleHide(restart: true);
  }

  void _skip(int seconds) =>
      _seekTo(_c.value.position + Duration(seconds: seconds));

  void _togglePlay() {
    if (_c.value.isPlaying) {
      _c.pause();
    } else {
      _started = true;
      _c.play();
    }
    _scheduleHide(restart: true);
  }

  void _replay() {
    _c.seekTo(Duration.zero);
    _c.play();
  }

  void _retry() {
    _disposeController();
    setState(_create);
  }

  void _lockControls() {
    setState(() => _locked = true);
    _setControls(false);
  }

  void _unlockControls() {
    setState(() => _locked = false);
    _setControls(true);
  }

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

  static const _brightnessUnavailable =
      'この環境では明るさを変えられません。端末の設定から変えてください';
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
    _syncTimer =
        Timer.periodic(const Duration(milliseconds: 500), (_) => _syncLevels());
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
    final next =
        v.clamp(LevelGesture.minVolume, LevelGesture.maxVolume).toDouble();
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
    setState(() {
      _volumePct = null;
      _brightPct = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final v = _c.value;
    final initialized = v.isInitialized;
    final playing = v.isPlaying;
    final failed = _failed;
    final ended = _ended;
    final buffering = _buffering;

    return LayoutBuilder(builder: (context, box) {
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
                    key: ValueKey('video-buffering'), color: Colors.white),
              ),
            ),
          if (initialized && !playing && !ended && !failed && !buffering)
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
                    label: '明るさ'),
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
                    label: '音量'),
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xCC000000),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(_notice!,
                      style:
                          const TextStyle(color: Colors.white, fontSize: 13)),
                ),
              ),
            ),
          if (_controls && initialized && !ended && !failed && !_locked)
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
    });
  }

  Widget _controlBar(VideoPlayerValue v) {
    final pos = v.position;
    final dur = v.duration;
    final shown = _seeking ? Duration(milliseconds: _seekTarget.round()) : pos;
    final max = dur.inMilliseconds.toDouble();
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xBF000000), Colors.transparent],
        ),
      ),
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
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
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13),
          child: Row(children: [
            Text(fmtDuration(shown),
                style: const TextStyle(color: Colors.white, fontSize: 12)),
            Expanded(
              child: Slider(
                value: (_seeking ? _seekTarget : pos.inMilliseconds.toDouble())
                    .clamp(0, max < 1 ? 1 : max),
                max: max < 1 ? 1 : max,
                activeColor: Colors.white,
                inactiveColor: Colors.white30,
                onChanged: (x) => setState(() {
                  _seeking = true;
                  _seekTarget = x;
                }),
                onChangeEnd: (x) {
                  _seekTo(Duration(milliseconds: x.round()));
                  setState(() => _seeking = false);
                },
              ),
            ),
            Text(fmtDuration(dur),
                style: const TextStyle(color: Colors.white, fontSize: 12)),
          ]),
        ),
        Row(children: [
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
            icon: Icon(v.isPlaying ? Icons.pause : Icons.play_arrow,
                color: Colors.white),
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
            icon: Icon(Icons.tune,
                color: _panelOpen ? const Color(0xFFFFAE00) : Colors.white),
            onPressed: _togglePanel,
          ),
        ]),
      ]),
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
  const _Overlay(
      {required this.text,
      required this.icon,
      required this.label,
      required this.onTap});

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
