import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 既存の保存先を移動・削除せず、iOSでは書き込む前にbackup除外を確かめる。
class PrivateStoragePolicy {
  PrivateStoragePolicy({
    TargetPlatform? platform,
    this.channel = const MethodChannel('app.r2gallery/private-storage'),
  }) : _platform = platform ?? defaultTargetPlatform;
  static final shared = PrivateStoragePolicy();
  final TargetPlatform _platform;
  final MethodChannel channel;
  Future<void>? _pending;

  Future<void> prepare() async {
    if (kIsWeb || _platform != TargetPlatform.iOS) return;
    final pending = _pending ??= _prepare();
    try {
      await pending;
    } catch (_) {
      if (identical(_pending, pending)) _pending = null;
      rethrow;
    }
  }

  Future<void> _prepare() async {
    try {
      final protected = await channel.invokeMethod<bool>('prepare');
      if (protected == true) return;
    } catch (_) {
      // 私的なパスやKeychainの内容・例外をUIやログへ出さない。
    }
    throw const PrivateStorageError();
  }
}

class PrivateStorageError implements Exception {
  const PrivateStorageError();
  @override
  String toString() => 'アプリ専用保存の保護設定を確認できませんでした';
}

/// 永続領域と再生用cacheは別。OSがcacheを消しても保存済みの暗号文は失わない。
Future<Directory> privatePersistentDirectory(String name) async {
  if (kIsWeb) throw UnsupportedError('Web版はアプリ専用保存に対応していません');
  if (!const {'offline', 'transfers', 'web-stage'}.contains(name)) {
    throw ArgumentError.value(name, 'name');
  }
  await PrivateStoragePolicy.shared.prepare();
  return Directory('${(await getApplicationSupportDirectory()).path}/$name');
}

Future<Directory> privatePlaybackCacheDirectory() async {
  if (kIsWeb) throw UnsupportedError('Web版はアプリ専用保存に対応していません');
  await PrivateStoragePolicy.shared.prepare();
  return Directory('${(await getTemporaryDirectory()).path}/offline-playback');
}
