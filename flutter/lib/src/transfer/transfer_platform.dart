import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'net_state.dart';

/// 転送を裏でも続けるための端末側の口。テストでは差し替える。
abstract class TransferPlatform {
  /// 動いている転送がある間、フォアグラウンドサービス（通知つき）でプロセスを生かしておく。
  /// [waiting] は Wi‑Fi などの設定で待っている件数（通知の文言に使う）。
  /// 待っているだけの行があってもサービスは外さない。外すと、タスク一覧から消された後に
  /// Wi‑Fi へ繋がっても再開できない（#27）
  Future<void> setKeepAlive(bool active, {int waiting = 0});

  /// サービスを張ったまま待機の件数だけ変わった時の知らせ。通知だけを替える。
  /// 理由: 裏から startForegroundService を呼び直すと Android 12 以降の起動制限に当たり得る
  Future<void> updateWaiting(int waiting);

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
  Future<void> setKeepAlive(bool active, {int waiting = 0}) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<void>(
          active ? 'start' : 'stop', active ? {'waiting': waiting} : null);
    } on MissingPluginException {
      // 古い MainActivity の上で動いた時。前面にいる間の転送は今まで通り続く
      debugPrint('transfer keep-alive is not available on this build');
    } on PlatformException catch (e) {
      // Android 12 以降は裏からサービスを始められないことがある。前面に戻れば次の切り替えで張り直す
      debugPrint('transfer keep-alive failed: ${e.message}');
    }
  }

  @override
  Future<void> updateWaiting(int waiting) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<void>('update', {'waiting': waiting});
    } on MissingPluginException {
      // 通知の文言を替える口が無い端末側（27-D より前の版）。転送自体には影響しない
      debugPrint('transfer notification update is not available on this build');
    } on PlatformException catch (e) {
      debugPrint('transfer notification update failed: ${e.message}');
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
