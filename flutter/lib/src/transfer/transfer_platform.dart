import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 転送を裏でも続けるための端末側の口。テストでは差し替える。
abstract class TransferPlatform {
  /// 動いている転送がある間、フォアグラウンドサービス（通知つき）でプロセスを生かしておく。
  Future<void> setKeepAlive(bool active);

  /// 既定の回線が使えるか。変わるたびに流す。分からん環境では何も流さない（常に繋がっている扱い）。
  Stream<bool> get online;
}

bool get _isAndroid => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

class PlatformTransferBridge implements TransferPlatform {
  static const _channel = MethodChannel('app.r2gallery/transfer');
  static const _events = EventChannel('app.r2gallery/connectivity');

  @override
  Future<void> setKeepAlive(bool active) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<void>(active ? 'start' : 'stop');
    } on MissingPluginException {
      // 古い MainActivity の上で動いた時。前面にいる間の転送は今まで通り続く
      debugPrint('transfer keep-alive is not available on this build');
    } on PlatformException catch (e) {
      // Android 12 以降は裏からサービスを始められないことがある。前面に戻れば次の切り替えで張り直す
      debugPrint('transfer keep-alive failed: ${e.message}');
    }
  }

  @override
  Stream<bool> get online {
    if (!_isAndroid) return const Stream.empty();
    return _events
        .receiveBroadcastStream()
        .where((e) => e is bool)
        .map((e) => e == true)
        .handleError((Object e) {
      debugPrint('connectivity feed failed: $e');
    });
  }
}
