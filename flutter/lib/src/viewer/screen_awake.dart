import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../state/app_state.dart';
import '../ui/app_lock_layer.dart';
import 'screen_awake_driver.dart';
import 'screen_awake_native.dart'
    if (dart.library.js_interop) 'screen_awake_web.dart' as platform;

export 'screen_awake_driver.dart';

/// ページ切替の古い解放が、新しい動画の保持を取り消さないよう窓ごとに要求をまとめる。
class ScreenAwakeCoordinator extends ChangeNotifier {
  ScreenAwakeCoordinator(this.driver) {
    _events = driver.events.listen((event) {
      if (_disposed) return;
      if (event == ScreenAwakeEvent.released) {
        _held = false;
        _releasePending = false;
        _setStatus(ScreenAwakeStatus.released);
        // OS や利用者が外した直後は取り返さない。再生の再開・可視化の機会でだけ再要求する。
      } else {
        _refreshWanted();
      }
    });
  }

  static final shared = ScreenAwakeCoordinator(platform.createScreenAwakeDriver());
  final ScreenAwakeDriver driver;
  final Set<Object> _requests = {};
  late final StreamSubscription<ScreenAwakeEvent> _events;
  Future<void> _tail = Future.value();
  ScreenAwakeStatus _status = ScreenAwakeStatus.idle;
  bool _wanted = false;
  bool _held = false;
  bool _releasePending = false;
  bool _disposed = false;
  bool _scheduled = false;

  ScreenAwakeStatus get status => _status;
  Future<void> get settled => _tail;

  ScreenAwakeLease lease() => ScreenAwakeLease._(this);

  void _setStatus(ScreenAwakeStatus value) {
    if (_status == value) return;
    _status = value;
    if (!_disposed) notifyListeners();
  }

  void _request(Object owner, bool enabled, {bool retryRelease = false}) {
    if (_disposed) return;
    if (enabled) {
      _requests.add(owner);
    } else {
      _requests.remove(owner);
    }
    _refreshWanted();
    if (retryRelease && !_wanted && _releasePending) _enqueue();
  }

  void _refreshWanted() {
    final next = !_disposed && _requests.isNotEmpty && driver.visible;
    if (next == _wanted) return;
    _wanted = next;
    _enqueue();
  }

  void _enqueue() {
    if (_scheduled) return;
    _scheduled = true;
    _tail = _tail.then((_) async {
      _scheduled = false;
      await _reconcile();
    }).catchError((Object _) {
      _setStatus(ScreenAwakeStatus.failed);
    });
  }

  Future<void> _reconcile() async {
    if (!_wanted || _disposed) {
      if (_held || _releasePending) {
        await _releaseHeld();
      }
      return;
    }
    if (_held) return;
    _setStatus(ScreenAwakeStatus.acquiring);
    final result = await driver.acquire();
    _held = result == ScreenAwakeStatus.held;
    if (_held) _releasePending = false;
    // 取得を待っている間に pause/退出した場合も、届いた保持を残さない。
    if (_held && (!_wanted || _disposed)) {
      await _releaseHeld();
    } else {
      _setStatus(result);
    }
  }

  Future<void> _releaseHeld() async {
    var result = ScreenAwakeStatus.released;
    try {
      await driver.release();
      _releasePending = false;
    } catch (_) {
      _releasePending = true;
      result = ScreenAwakeStatus.failed;
    } finally {
      _held = false;
      _setStatus(result);
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _wanted = false;
    _requests.clear();
    unawaited(_events.cancel());
    _enqueue();
    _tail = _tail.whenComplete(driver.dispose);
    super.dispose();
  }
}

class ScreenAwakeLease {
  ScreenAwakeLease._(this._coordinator);
  final ScreenAwakeCoordinator _coordinator;
  bool _disposed = false;
  bool _enabled = false;

  void setEnabled(bool enabled) {
    if (_disposed || _enabled == enabled) return;
    _enabled = enabled;
    _coordinator._request(this, enabled);
  }

  void release() {
    if (_disposed) return;
    _enabled = false;
    _coordinator._request(this, false, retryRelease: true);
  }

  void dispose() {
    if (_disposed) return;
    release();
    _disposed = true;
  }
}

/// 端末の自動消灯だけを抑える。電源ボタンやアプリのロックは優先して保持を解く。
class PlaybackScreenAwake extends StatefulWidget {
  final VideoPlayerController controller;
  final bool active;
  final Widget child;
  final ScreenAwakeCoordinator? coordinator;
  final ValueChanged<ScreenAwakeStatus>? onStatusChanged;

  const PlaybackScreenAwake({super.key, required this.controller,
    required this.child, this.active = true, this.coordinator, this.onStatusChanged});

  @override
  State<PlaybackScreenAwake> createState() => _PlaybackScreenAwakeState();
}

class _PlaybackScreenAwakeState extends State<PlaybackScreenAwake>
    with WidgetsBindingObserver {
  late final ScreenAwakeCoordinator _coordinator =
      widget.coordinator ?? ScreenAwakeCoordinator.shared;
  late final ScreenAwakeLease _lease = _coordinator.lease();
  AppState? _app;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    final life = WidgetsBinding.instance.lifecycleState;
    _foreground = life == null || life == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_sync);
    _coordinator.addListener(_reportStatus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppLockScope.maybeOf(context);
    if (app != _app) {
      _app?.removeListener(_sync);
      _app = app;
      app?.addListener(_sync);
    }
    _sync();
  }

  void _reportStatus() => widget.onStatusChanged?.call(_coordinator.status);

  void _sync() {
    final value = widget.controller.value;
    _lease.setEnabled(_foreground && widget.active && !(_app?.locked ?? false) &&
        value.isInitialized && value.isPlaying && !value.isCompleted &&
        !value.hasError);
  }

  @override
  void didUpdateWidget(PlaybackScreenAwake old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_sync);
      widget.controller.addListener(_sync);
    }
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) _lease.release();
    _sync();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_sync);
    _app?.removeListener(_sync);
    _coordinator.removeListener(_reportStatus);
    _lease.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
