import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'net_state.dart';

/// 転送を裏でも続けるための端末側の口。テストでは差し替える。
abstract class TransferPlatform {
  /// 動いている転送がある間、フォアグラウンドサービス（通知つき）でプロセスを生かしておく。
  Future<void> setKeepAlive(bool active);

  /// 既定の回線の様子。変わるたびに流す。分からん環境では何も流さない（常に繋がっている扱い）。
  Stream<NetState> get network;
}

/// EventChannel の生の値を NetState に読む。読めない値は unknownOnline にする。
/// 理由: 読めない値を捨てたりオフライン扱いにしたりすると、端末側の取り違え1つで
/// 配った版の転送が止まったままになる。続けて同じ様子は流さない（回線の性能の変化だけでも届くため）
@visibleForTesting
Stream<NetState> netStatesOf(Stream<Object?> raw) => raw
    .map((e) => NetState.fromEvent(e) ?? NetState.unknownOnline)
    .distinct();

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
  Stream<NetState> get network {
    if (!_isAndroid) return const Stream.empty();
    return netStatesOf(_events.receiveBroadcastStream()).handleError((Object e) {
      debugPrint('connectivity feed failed: $e');
    });
  }
}
