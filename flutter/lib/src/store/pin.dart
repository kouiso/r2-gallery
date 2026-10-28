import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'kv.dart';

const _iterations = 210000;
const _failLimit = 5;
const _lockMs = 30000;

String _hex(List<int> b) =>
    b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

List<int> _unhex(String s) => [
      for (var i = 0; i < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16)
    ];

/// PBKDF2-HMAC-SHA256。crypto パッケージの HMAC だけで組む
///（KMP版 PureCrypto.kt と同じ RFC2898 手続き、ブロック長1で十分）。
List<int> pbkdf2Sha256(String password, List<int> salt, int iterations,
    {int dkLen = 32}) {
  final pw = Hmac(sha256, utf8.encode(password));
  final u = pw.convert([...salt, 0, 0, 0, 1]).bytes;
  final out = List<int>.from(u);
  for (var i = 1; i < iterations; i++) {
    final next = pw.convert(u).bytes;
    for (var j = 0; j < out.length; j++) {
      out[j] ^= next[j];
    }
    u.setAll(0, next);
  }
  return out.sublist(0, dkLen);
}

/// 21万回の HMAC は UI isolate で回すと数百ms 以上固まり、解除中のスピナーも止まる。
/// 反復回数と保存形式は変えずに別 isolate へ逃がす（web では compute が同じ isolate で回す）。
Future<List<int>> _pbkdf2Off(String pin, List<int> salt) => compute(
      _pbkdf2Entry,
      (pin: pin, salt: salt, iterations: _iterations),
    );

List<int> _pbkdf2Entry(({String pin, List<int> salt, int iterations}) a) =>
    pbkdf2Sha256(a.pin, a.salt, a.iterations);

class PinLock {
  static Future<bool> hasPin() async =>
      (await Kv.get(Keys.pinHash))?.isNotEmpty ?? false;

  static Future<void> setPin(String pin) async {
    final rng = Random.secure();
    final salt = List<int>.generate(16, (_) => rng.nextInt(256));
    await Kv.set(Keys.pinSalt, _hex(salt));
    await Kv.set(
        Keys.pinHash, _hex(await _pbkdf2Off(pin, salt)));
    await Kv.set(Keys.pinLen, pin.length.toString());
    await clearFailures();
  }

  static Future<int?> pinLength() async {
    final v = await Kv.get(Keys.pinLen);
    final n = int.tryParse(v ?? '');
    return (n != null && n > 0) ? n : null;
  }

  static Future<bool> verify(String pin) async {
    final hash = await Kv.get(Keys.pinHash);
    final saltHex = await Kv.get(Keys.pinSalt);
    if (hash == null || saltHex == null) return false;
    final candidate = _hex(await _pbkdf2Off(pin, _unhex(saltHex)));
    // タイミングを揃えるため短絡評価しない比較
    var diff = candidate.length ^ hash.length;
    final n = candidate.length < hash.length ? candidate.length : hash.length;
    for (var i = 0; i < n; i++) {
      diff |= candidate.codeUnitAt(i) ^ hash.codeUnitAt(i);
    }
    return diff == 0;
  }

  static Future<int> lockedRemaining() async {
    final until = int.tryParse(await Kv.get(Keys.pinLockedUntil) ?? '') ?? 0;
    final left = until - DateTime.now().millisecondsSinceEpoch;
    return left < 0 ? 0 : left;
  }

  static Future<int> recordFailure() async {
    final fails =
        (int.tryParse(await Kv.get(Keys.pinFailures) ?? '') ?? 0) + 1;
    if (fails >= _failLimit) {
      await Kv.set(Keys.pinFailures, '0');
      await Kv.set(Keys.pinLockedUntil,
          (DateTime.now().millisecondsSinceEpoch + _lockMs).toString());
      return _lockMs;
    }
    await Kv.set(Keys.pinFailures, fails.toString());
    return 0;
  }

  static Future<void> clearFailures() async {
    await Kv.remove(Keys.pinFailures);
    await Kv.remove(Keys.pinLockedUntil);
  }

  static Future<void> removePin() async {
    await Kv.remove(Keys.pinHash);
    await Kv.remove(Keys.pinSalt);
    await Kv.remove(Keys.pinLen);
    await clearFailures();
  }
}
