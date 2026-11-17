import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'screen_awake_driver.dart';

ScreenAwakeDriver createScreenAwakeDriver() => NativeScreenAwakeDriver();

/// OS の保存設定や CPU の WakeLock は触らず、前景の窓だけを対象にする。
class NativeScreenAwakeDriver implements ScreenAwakeDriver {
  static const _channel = MethodChannel('app.r2gallery/player');
  bool get _supported => !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  @override
  bool get visible => true;
  @override
  Stream<ScreenAwakeEvent> get events => const Stream.empty();

  @override
  Future<ScreenAwakeStatus> acquire() async {
    if (!_supported) return ScreenAwakeStatus.unsupported;
    try {
      final held = await _channel.invokeMethod<bool>('setKeepScreenOn', true);
      return held == true ? ScreenAwakeStatus.held : ScreenAwakeStatus.released;
    } on MissingPluginException {
      return ScreenAwakeStatus.unsupported;
    } on PlatformException catch (error) {
      return error.code == 'denied' ? ScreenAwakeStatus.denied : ScreenAwakeStatus.failed;
    }
  }

  @override
  Future<void> release() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<bool>('setKeepScreenOn', false);
    } on MissingPluginException {
      // 対応していないビルドでは取得自体もしていない。
    }
  }

  @override
  void dispose() {}
}
