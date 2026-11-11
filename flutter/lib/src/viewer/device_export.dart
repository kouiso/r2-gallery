import 'dart:io';

import '../api/client.dart';
import '../api/models.dart';

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

/// 外部書き出しは本人依頼で廃止。古い呼び出しからも共有領域へ流さない。
class PlatformMediaStore implements MediaStoreBridge {
  @override
  bool get supported => false;

  @override
  Future<void> save(String path, String displayName, String mime) async {
    throw const DeviceExportError('外部への書き出しは利用できません。オフライン保存を使ってください');
  }
}

/// 旧 API の互換型。アプリの保存導線からは使わず、既定の共有領域への口も拒否する。
class DeviceExporter {
  DeviceExporter({
    required this.api,
    MediaStoreBridge? store,
    Future<Directory> Function()? tempDir,
  }) : store = store ?? PlatformMediaStore();

  final ApiClient api;
  final MediaStoreBridge store;

  // 互換引数や差し替えたbridgeを渡されても、保存方針を迂回して平文を作らない。
  bool get supported => false;

  Future<void> export(
    MediaItem item,
    String lib, {
    Future<void> Function(Future<void> Function() body)? guardSave,
  }) async {
    throw const DeviceExportError('外部への書き出しは利用できません。オフライン保存を使ってください');
  }
}
