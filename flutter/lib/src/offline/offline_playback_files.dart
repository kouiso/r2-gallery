import 'dart:io';

import 'package:flutter/foundation.dart';
import '../store/private_storage.dart';

/// 復号した動画は公開領域へ出さず、再生中だけアプリ専用キャッシュへ置く。
class OfflinePlaybackFiles {
  OfflinePlaybackFiles({Future<Directory> Function()? root})
      : _root = root ?? _defaultRoot;

  final Future<Directory> Function() _root;
  final Set<String> _active = {};
  Future<void>? _sweep;

  static final shared = OfflinePlaybackFiles();

  static Future<Directory> _defaultRoot() => privatePlaybackCacheDirectory();

  Future<Directory> _directory() async {
    final root = await _root();
    await root.create(recursive: true);
    return root;
  }

  /// 前の異常終了で残った、この機能専用のセッションだけを片付ける。
  Future<void> cleanOrphans() => _sweep ??= _cleanOrphans();

  Future<void> _cleanOrphans() async {
    final root = await _directory();
    await for (final entry in root.list(followLinks: false)) {
      if (entry is! Directory ||
          !entry.uri.pathSegments.where((s) => s.isNotEmpty).last
              .startsWith('session-') ||
          _active.contains(entry.path)) {
        continue;
      }
      await _delete(entry);
    }
  }

  Future<OfflinePlaybackFile> create(Uint8List plain) async {
    await cleanOrphans();
    final dir = await (await _directory()).createTemp('session-');
    _active.add(dir.path);
    try {
      final file = File('${dir.path}/play.mp4');
      await file.writeAsBytes(plain, flush: true);
      return OfflinePlaybackFile._(file, () async {
        _active.remove(dir.path);
        await _delete(dir);
      });
    } catch (_) {
      _active.remove(dir.path);
      await _delete(dir);
      rethrow;
    }
  }

  Future<void> _delete(Directory directory) async {
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } on FileSystemException {
      // パスや作品名をログに出さず、次の起動でも再生専用領域を掃除できるよう残す。
      debugPrint('offline playback cache cleanup failed');
    }
  }
}

class OfflinePlaybackFile {
  OfflinePlaybackFile._(this.file, this._remove);
  final File file;
  final Future<void> Function() _remove;
  Future<void>? _disposed;

  Future<void> dispose() => _disposed ??= _remove();
}
