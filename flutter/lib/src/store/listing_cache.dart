import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/models.dart';

/// 一覧の先頭ページを端末に残す単位。接続先まで含めるのは、別の接続先に繋ぎ直した時に
/// 前の接続先の一覧を出さないため（オフライン保存で起きた #149 と同じ取り違えを避ける）。
class ListingScope {
  final String endpoint;
  final String lib;
  final String prefix;
  final bool recursive;
  final String sort;
  // 種別の絞り込み（写真/動画）も控えの単位に含める。混ぜると「全部」の控えが
  // 「動画のみ」の一覧に出てしまう（#26）
  final String type;
  const ListingScope({
    required this.endpoint,
    required this.lib,
    required this.prefix,
    required this.recursive,
    required this.sort,
    this.type = 'all',
  });

  /// ファイル名・保存キーに使う。中身（ライブラリ名やフォルダ名）をそのまま名前に出さない
  String get id => sha256
      .convert(utf8.encode(jsonEncode(
          [endpoint, lib, prefix, recursive ? 1 : 0, sort, type])))
      .toString();
}

/// 残しておいた先頭ページ。[serverSort] は Worker が実際に並べた順（古い Worker は null）。
class CachedListing {
  final List<MediaItem> items;
  final List<String> folders;
  final String? serverSort;
  final int? total;
  final int savedAt;
  const CachedListing({
    required this.items,
    this.folders = const [],
    this.serverSort,
    this.total,
    required this.savedAt,
  });

  Map<String, dynamic> toJson() => {
        'v': 1,
        'items': [for (final it in items) it.toJson()],
        'folders': folders,
        'sort': serverSort,
        'total': total,
        'savedAt': savedAt,
      };

  static CachedListing? fromJson(Object? j) {
    if (j is! Map || j['v'] != 1) return null;
    final items = j['items'];
    if (items is! List) return null;
    return CachedListing(
      items: [
        for (final e in items)
          if (e is Map<String, dynamic>) MediaItem.fromJson(e),
      ],
      folders: [
        for (final f in (j['folders'] as List?) ?? const [])
          if (f is String) f,
      ],
      serverSort: j['sort'] as String?,
      total: (j['total'] as num?)?.toInt(),
      savedAt: (j['savedAt'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 一覧の先頭ページの置き場。読み書きの失敗は一覧の表示を止めないよう、ここで飲み込んで記録だけする。
abstract class ListingCache {
  /// 端末ごとの既定。web は localStorage、それ以外はキャッシュ用のディレクトリに置く。
  factory ListingCache.platform() =>
      kIsWeb ? PrefsListingCache() : FileListingCache();

  Future<CachedListing?> read(ListingScope scope);
  Future<void> write(ListingScope scope, CachedListing listing);
  Future<void> clear();
}

/// 生の文字列を出し入れする部分だけを置き場ごとに変える。
abstract class _RawListingCache implements ListingCache {
  /// 置いておく件数の上限。ライブラリ×並び順×フォルダで増えるので、古い物から捨てる
  int get maxEntries;

  Future<String?> readRaw(String id);
  Future<void> writeRaw(String id, String body);
  Future<void> clearRaw();

  @override
  Future<CachedListing?> read(ListingScope scope) async {
    try {
      final raw = await readRaw(scope.id);
      if (raw == null) return null;
      return CachedListing.fromJson(jsonDecode(raw));
    } on Object catch (e) {
      debugPrint('listing cache read failed: $e');
      return null;
    }
  }

  @override
  Future<void> write(ListingScope scope, CachedListing listing) async {
    try {
      await writeRaw(scope.id, jsonEncode(listing.toJson()));
    } on Object catch (e) {
      debugPrint('listing cache write failed: $e');
    }
  }

  @override
  Future<void> clear() async {
    try {
      await clearRaw();
    } on Object catch (e) {
      debugPrint('listing cache clear failed: $e');
    }
  }
}

/// テストと、置き場を使えない時のためのメモリ上の置き場。
class MemoryListingCache extends _RawListingCache {
  MemoryListingCache({this.maxEntries = 24});

  @override
  final int maxEntries;

  /// 挿入順 = 古い順。上書きは末尾へ回す
  final Map<String, String> entries = {};

  @override
  Future<String?> readRaw(String id) async => entries[id];

  @override
  Future<void> writeRaw(String id, String body) async {
    entries.remove(id);
    entries[id] = body;
    while (entries.length > maxEntries) {
      entries.remove(entries.keys.first);
    }
  }

  @override
  Future<void> clearRaw() async => entries.clear();
}

/// モバイル・デスクトップ: キャッシュ用ディレクトリに1件1ファイル。
/// OS に消されても次の取得で作り直すだけなので、消えてよい場所に置く。
class FileListingCache extends _RawListingCache {
  @override
  int get maxEntries => 24;

  Directory? _dir;

  Future<Directory> _root() async {
    final d = _dir ??=
        Directory('${(await getApplicationCacheDirectory()).path}/listing');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  @override
  Future<String?> readRaw(String id) async {
    final f = File('${(await _root()).path}/$id.json');
    return await f.exists() ? f.readAsString() : null;
  }

  @override
  Future<void> writeRaw(String id, String body) async {
    final dir = await _root();
    // 書きかけのファイルを次の起動で読まんよう、別名に書いてから差し替える
    final tmp = File('${dir.path}/$id.tmp');
    await tmp.writeAsString(body, flush: true);
    await tmp.rename('${dir.path}/$id.json');
    final files = [
      for (final e in dir.listSync())
        if (e is File && e.path.endsWith('.json')) e,
    ];
    if (files.length <= maxEntries) return;
    files.sort((a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()));
    for (final f in files.take(files.length - maxEntries)) {
      await f.delete();
    }
  }

  @override
  Future<void> clearRaw() async {
    final d = await _root();
    if (await d.exists()) await d.delete(recursive: true);
  }
}

/// web: localStorage。容量が小さい（数MB）ので件数を絞り、古い順の目録で追い出す。
class PrefsListingCache extends _RawListingCache {
  @override
  int get maxEntries => 8;

  static const _prefix = 'r2g.listing.';
  static const _index = 'r2g.listing.index';

  @override
  Future<String?> readRaw(String id) async =>
      (await SharedPreferences.getInstance()).getString('$_prefix$id');

  @override
  Future<void> writeRaw(String id, String body) async {
    final p = await SharedPreferences.getInstance();
    final order = [...?p.getStringList(_index)]
      ..remove(id)
      ..add(id);
    while (order.length > maxEntries) {
      await p.remove('$_prefix${order.removeAt(0)}');
    }
    await p.setString('$_prefix$id', body);
    await p.setStringList(_index, order);
  }

  @override
  Future<void> clearRaw() async {
    final p = await SharedPreferences.getInstance();
    for (final id in p.getStringList(_index) ?? const <String>[]) {
      await p.remove('$_prefix$id');
    }
    await p.remove(_index);
  }
}

/// 署名URLの期限（e= の UNIX 秒）が過ぎているか。期限が読めないURLは切れていない扱い
/// （署名の無い URL は期限で弾かれないため）。
bool signedUrlExpired(String url, {DateTime? now}) {
  final e = int.tryParse(Uri.tryParse(url)?.queryParameters['e'] ?? '');
  if (e == null) return false;
  final t = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
  return e <= t;
}
