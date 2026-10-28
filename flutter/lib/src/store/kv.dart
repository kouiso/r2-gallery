import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 小さい文字列KVの抽象。web は localStorage（`r2g.*` キーを従来Web版と共有）、
/// モバイルは flutter_secure_storage（Keychain/Keystore 経由）に分ける。
class Kv {
  static const _secure = FlutterSecureStorage();

  static Future<String?> get(String key) async {
    if (kIsWeb) {
      final p = await SharedPreferences.getInstance();
      return p.getString(key);
    }
    return _secure.read(key: key);
  }

  static Future<void> set(String key, String value) async {
    if (kIsWeb) {
      final p = await SharedPreferences.getInstance();
      await p.setString(key, value);
      return;
    }
    await _secure.write(key: key, value: value);
  }

  static Future<void> remove(String key) async {
    if (kIsWeb) {
      final p = await SharedPreferences.getInstance();
      await p.remove(key);
      return;
    }
    await _secure.delete(key: key);
  }
}

class Keys {
  static const endpoint = 'r2g.endpoint';
  static const token = 'r2g.token';
  static const pinHash = 'r2g.pin.hash';
  static const pinSalt = 'r2g.pin.salt';
  static const pinLen = 'r2g.pin.len';
  static const pinFailures = 'r2g.pin.fails';
  static const pinLockedUntil = 'r2g.pin.lockedUntil';
  static const deviceLock = 'r2g.deviceLock';
  static const lockGraceMs = 'r2g.lockGraceMs';
  static const library = 'r2g.library';
  static const webHistory = 'r2g.webHistory';
}
