import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 動画プレイヤーのドラッグで触る端末側の値（音量・画面の明るさ）。どちらも 0.0〜1.0。
abstract class PlayerSystem {
  /// 取れない端末・環境では null（ジェスチャーを効かせない）。
  Future<double?> volume();

  /// 実際に設定できた値を返す（音量は段階があるので丸められる）。
  Future<double?> setVolume(double v);

  /// 端末がいま出している明るさ。実際の値を読めなければ null（自動調整中で古い Android など）。
  Future<double?> brightness();
  Future<double?> setBrightness(double v);

  /// 端末が明るさを自動調整しているか。[brightness] が null の理由を伝えるために使う。
  Future<bool> brightnessAuto();

  /// プレイヤーを閉じたら端末の設定どおりの明るさに戻す。
  Future<void> resetBrightness();
}

/// MainActivity の app.r2gallery/player チャネル。Android 以外は何もしない。
class PlatformPlayerSystem implements PlayerSystem {
  static const _ch = MethodChannel('app.r2gallery/player');

  bool get _on => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<T?> _call<T>(String method, [double? arg]) async {
    if (!_on) return null;
    try {
      final v = await _ch.invokeMethod<T>(method, arg);
      return v;
    } on PlatformException catch (e) {
      debugPrint('player $method failed: $e');
      return null;
    } on MissingPluginException catch (e) {
      debugPrint('player $method missing: $e');
      return null;
    }
  }

  @override
  Future<double?> volume() => _call<double>('getVolume');
  @override
  Future<double?> setVolume(double v) => _call<double>('setVolume', v);
  @override
  Future<double?> brightness() => _call<double>('getBrightness');
  @override
  Future<double?> setBrightness(double v) => _call<double>('setBrightness', v);
  @override
  Future<bool> brightnessAuto() async =>
      await _call<bool>('isAutoBrightness') ?? false;
  @override
  Future<void> resetBrightness() => _call<void>('resetBrightness');
}
