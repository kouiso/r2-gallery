import 'dart:async';
import 'dart:js_interop';

import 'screen_awake_driver.dart';

@JS('navigator')
external _Navigator get _navigator;
@JS('document')
external _Document get _document;
@JS('isSecureContext')
external bool get _secureContext;

extension type _Navigator(JSObject _) implements JSObject {
  external _WakeLock? get wakeLock;
}
extension type _WakeLock(JSObject _) implements JSObject {
  external JSPromise<_Sentinel> request(String type);
}
extension type _Sentinel(JSObject _) implements JSObject {
  external bool get released;
  external JSPromise<JSAny?> release();
  external void addEventListener(String type, JSFunction callback);
  external void removeEventListener(String type, JSFunction callback);
}
extension type _Document(JSObject _) implements JSObject {
  external String get visibilityState;
  external void addEventListener(String type, JSFunction callback);
  external void removeEventListener(String type, JSFunction callback);
}

ScreenAwakeDriver createScreenAwakeDriver() => WebScreenAwakeDriver();

class WebScreenAwakeDriver implements ScreenAwakeDriver {
  final _events = StreamController<ScreenAwakeEvent>.broadcast(sync: true);
  _Sentinel? _sentinel;
  JSFunction? _releaseListener;
  bool _disposed = false;
  late final JSFunction _visibilityListener = ((JSAny? _) {
    if (!_disposed) _events.add(ScreenAwakeEvent.visibilityChanged);
  }).toJS;

  WebScreenAwakeDriver() {
    _document.addEventListener('visibilitychange', _visibilityListener);
  }

  @override
  bool get visible => _document.visibilityState == 'visible';
  @override
  Stream<ScreenAwakeEvent> get events => _events.stream;

  @override
  Future<ScreenAwakeStatus> acquire() async {
    if (_disposed || !visible) return ScreenAwakeStatus.released;
    final lock = _navigator.wakeLock;
    if (!_secureContext || lock == null) return ScreenAwakeStatus.unsupported;
    final current = _sentinel;
    if (current != null && !current.released) return ScreenAwakeStatus.held;
    final JSPromise<_Sentinel> pending;
    try {
      pending = lock.request('screen');
    } catch (_) {
      return ScreenAwakeStatus.failed;
    }
    final _Sentinel sentinel;
    try {
      sentinel = await pending.toDart;
    } catch (_) {
      // 電池・利用者設定・Permissions Policy 等による拒否を、取得成功と扱わない。
      return ScreenAwakeStatus.denied;
    }
    if (_disposed || !visible || sentinel.released) {
      if (!sentinel.released) await sentinel.release().toDart;
      return ScreenAwakeStatus.released;
    }
    final listener = ((JSAny? _) {
      if (_disposed || _sentinel != sentinel) return;
      _detachReleaseListener();
      _sentinel = null;
      _events.add(ScreenAwakeEvent.released);
    }).toJS;
    _sentinel = sentinel;
    _releaseListener = listener;
    sentinel.addEventListener('release', listener);
    return ScreenAwakeStatus.held;
  }

  void _detachReleaseListener() {
    final sentinel = _sentinel;
    final listener = _releaseListener;
    if (sentinel != null && listener != null) sentinel.removeEventListener('release', listener);
    _releaseListener = null;
  }

  @override
  Future<void> release() async {
    final sentinel = _sentinel;
    if (sentinel == null) return;
    // 解放が拒まれた時は handle を捨てず、次の明示的な停止でもう一度解放できるよう残す。
    if (!sentinel.released) await sentinel.release().toDart;
    if (_sentinel == sentinel) {
      _detachReleaseListener();
      _sentinel = null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _document.removeEventListener('visibilitychange', _visibilityListener);
    unawaited(release().catchError((Object _) {}));
    unawaited(_events.close());
  }
}
