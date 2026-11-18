import 'package:flutter/services.dart';

/// file_picker が選んだ全件を端末に写すのをやめ、content:// の URI だけを受け取る口。
/// 写しが1回（退避）で済み、写せなかった件は失敗の行になる。
/// 権利は画面が生きている間だけ有効なので、退避は積んだ直後に行う（#182 決めた事 8・9）。
class UploadPickerChannel {
  const UploadPickerChannel();

  static const _ch = MethodChannel('app.r2gallery/upload_picker');
  static const instance = UploadPickerChannel();

  /// 写真・動画の複数選択。返り値は {uri, name, size, mime} の並び。
  /// Android 以外・開けなかった時は空にせず null を返し、呼び出し側が従来のピッカーへ下げる。
  Future<List<Map<Object?, Object?>>?> pick() async {
    try {
      final r = await _ch.invokeMethod<List<Object?>>('pick');
      return r?.cast<Map<Object?, Object?>>() ?? const [];
    } on MissingPluginException {
      return null;
    }
  }

  /// content:// の URI から退避先ファイルへ写す。権利切れ・削除済みは失敗を投げる
  Future<void> copyToFile(String uri, String dest) =>
      _ch.invokeMethod<void>('copyToFile', {'uri': uri, 'dest': dest});

  /// 退避先の空きバイト。分からない時は null
  Future<int?> freeBytes(String path) async {
    try {
      return await _ch.invokeMethod<int>('freeBytes', {'path': path});
    } on MissingPluginException {
      return null;
    }
  }
}
