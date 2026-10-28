import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../api/client.dart';
import '../api/models.dart';
import 'viewer_format.dart';

/// 端末への書き出しで、画面にそのまま出せる理由を持つ失敗。
class DeviceExportError implements Exception {
  final String message;
  const DeviceExportError(this.message);
  @override
  String toString() => message;
}

/// 端末の共有メディア（Android の MediaStore = ギャラリー/Photos）への登録口。
abstract class MediaStoreBridge {
  bool get supported;

  /// [path] の中身を [displayName] で登録する。[mime] で画像/動画の置き場を分ける。
  Future<void> save(String path, String displayName, String mime);
}

/// MainActivity の app.r2gallery/export チャネル。Android 以外では使えない。
class PlatformMediaStore implements MediaStoreBridge {
  static const _ch = MethodChannel('app.r2gallery/export');

  @override
  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<void> save(String path, String displayName, String mime) async {
    try {
      await _ch.invokeMethod<void>(
          'save', {'path': path, 'name': displayName, 'mime': mime});
    } on PlatformException catch (e) {
      // ネイティブ側は利用者向けの文言を message に入れて返す
      throw DeviceExportError(e.message ?? '端末への保存に失敗しました');
    } on MissingPluginException catch (e) {
      debugPrint('export channel missing: $e');
      throw const DeviceExportError('端末への保存に失敗しました');
    }
  }
}

/// R2 の写真・動画を端末のギャラリーへ書き出す。暗号化したアプリ内のオフライン保存とは別物。
/// KMP 版 AppViewModel.exportToDevice と同じ流れ（署名URL切れは一度だけ取り直す）。
class DeviceExporter {
  DeviceExporter({
    required this.api,
    MediaStoreBridge? store,
    Future<Directory> Function()? tempDir,
  })  : store = store ?? PlatformMediaStore(),
        _tempDir = tempDir ??
            (() => Directory.systemTemp.createTemp('r2g-export-'));

  final ApiClient api;
  final MediaStoreBridge store;
  final Future<Directory> Function() _tempDir;

  bool get supported => store.supported;

  /// [guardSave] は端末への登録だけを包む口。古い Android で許可ダイアログが出る所だけを外部画面として扱い、
  /// 長いダウンロードの間まで再ロックの猶予を延ばさないため。
  Future<void> export(MediaItem item, String lib,
      {Future<void> Function(Future<void> Function() body)? guardSave}) async {
    final mime = mimeFor(item.name);
    if (!mime.startsWith('image/') && !mime.startsWith('video/')) {
      throw const DeviceExportError('この形式は端末に保存できません');
    }
    final dir = await _tempDir();
    final file = '${dir.path}/export.bin';
    try {
      try {
        await api.downloadToFile(item.url, file);
      } on ApiError catch (e) {
        // 署名URLの期限切れ。一覧から署名し直したURLで一度だけ取り直す
        if (e.status != 403) rethrow;
        final fresh = await _resignedUrl(lib, item.key);
        if (fresh == null) throw const DeviceExportError('アイテムが見つかりません');
        await api.downloadToFile(fresh, file);
      }
      Future<void> save() => store.save(file, item.name, mime);
      await (guardSave == null ? save() : guardSave(save));
    } finally {
      try {
        await dir.delete(recursive: true);
      } on FileSystemException catch (e) {
        debugPrint('export temp cleanup failed: $e');
      }
    }
  }

  Future<String?> _resignedUrl(String lib, String key) async {
    final slash = key.lastIndexOf('/');
    final prefix = slash < 0 ? '' : key.substring(0, slash + 1);
    String? cursor;
    do {
      final page = await api.folder(lib, prefix: prefix, cursor: cursor);
      for (final it in page.items) {
        if (it.key == key) return it.url;
      }
      cursor = page.cursor;
    } while (cursor != null);
    return null;
  }
}
