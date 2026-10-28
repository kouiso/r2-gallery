import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 再ロック猶予を測るための時刻の読み取り。
/// boot は端末起動からの経過（スリープ中も進み、時計の変更で戻らない）。取れない環境では null。
typedef ClockReading = ({int? boot, int mono, int wall});

/// 2回の読み取りの間に経ったミリ秒。
/// boot が両方あればそれだけを信じる。無い時は mono（時計変更に強いがスリープ中に止まる）と
/// wall（スリープ中も進むが時計を戻されると縮む）の長い方を取り、どちらの弱点でも猶予が延びんようにする。
int elapsedBetween(ClockReading from, ClockReading to) {
  final fb = from.boot, tb = to.boot;
  if (fb != null && tb != null) return tb - fb;
  final mono = to.mono - from.mono;
  final wall = to.wall - from.wall;
  return mono > wall ? mono : wall;
}

abstract class LockClock {
  Future<ClockReading> read();
}

const _channel = MethodChannel('app.r2gallery/lock');

bool get _isAndroid => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// Android は SystemClock.elapsedRealtime を使う。Dart の Stopwatch は Android だと
/// スリープ中に止まるので、端末を寝かせておくだけで猶予を延ばせてしまう。
class PlatformLockClock implements LockClock {
  final _mono = Stopwatch()..start();

  @override
  Future<ClockReading> read() async {
    int? boot;
    if (_isAndroid) {
      try {
        boot = await _channel.invokeMethod<int>('elapsedRealtime');
      } on PlatformException {
        boot = null;
      } on MissingPluginException {
        boot = null;
      }
    }
    return (
      boot: boot,
      mono: _mono.elapsedMilliseconds,
      wall: DateTime.now().millisecondsSinceEpoch,
    );
  }
}

/// 最近使ったアプリの一覧やスクリーンショットに中身を残さないための窓の保護（Android の FLAG_SECURE）。
abstract class SecureWindow {
  Future<void> setSecure(bool on);
}

class PlatformSecureWindow implements SecureWindow {
  @override
  Future<void> setSecure(bool on) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<void>('setSecure', on);
    } on MissingPluginException {
      // 古い MainActivity の上で動いた時。保護は付かんが、画面のロック自体は効いとる
      debugPrint('setSecure is not available on this build');
    } on PlatformException catch (e) {
      debugPrint('setSecure failed: ${e.message}');
    }
  }
}
