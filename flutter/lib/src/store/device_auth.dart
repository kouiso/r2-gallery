import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:local_auth/local_auth.dart';

/// 端末の画面ロック（PIN/パターン/指紋/顔）で本人確認する口。
/// テストや web で差し替えられるように抽象にしてある。
abstract class DeviceAuth {
  /// 端末に使える認証手段（生体 or 画面ロック）があるか。
  /// 分からなかった時（端末側のエラー）は false ではなく例外にする。「無い」と混ぜると、
  /// 呼び出し側がロックを外す側に倒してしまう。
  Future<bool> isAvailable();

  /// 本人確認できたら true。キャンセルや失敗は false で、例外は投げない。
  Future<bool> verify(String reason);
}

class LocalDeviceAuth implements DeviceAuth {
  final _auth = LocalAuthentication();

  @override
  Future<bool> isAvailable() async {
    // web は local_auth の実装が無い。PIN だけで守る
    if (kIsWeb) return false;
    try {
      return await _auth.isDeviceSupported();
    } on MissingPluginException {
      // プラグインが載っていない環境では端末認証は本当に使えない
      return false;
    }
  }

  @override
  Future<bool> verify(String reason) async {
    if (kIsWeb) return false;
    try {
      // biometricOnly:false なので、生体が無い・外れた時も画面ロックで解除できる
      return await _auth.authenticate(localizedReason: reason);
    } on Exception {
      // ユーザーキャンセル・ロックアウト等。画面側で再試行ボタンと PIN を出す
      return false;
    }
  }
}
