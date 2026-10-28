/// worker API の応答モデル。KMP版 Models.kt と対応させている。
library;

class Library {
  final String id;
  final String title;
  final bool readOnly;
  const Library({required this.id, required this.title, this.readOnly = false});

  factory Library.fromJson(Map<String, dynamic> j) => Library(
        id: j['id'] as String,
        title: (j['title'] as String?) ?? j['id'] as String,
        readOnly: (j['readOnly'] as bool?) ?? false,
      );
}

class Album {
  final String id;
  final String title;
  final String? subtitle;
  final int count;
  final String? coverUrl;
  final bool readOnly;
  const Album({
    required this.id,
    required this.title,
    this.subtitle,
    this.count = 0,
    this.coverUrl,
    this.readOnly = true,
  });

  factory Album.fromJson(Map<String, dynamic> j) => Album(
        id: j['id'] as String,
        title: (j['title'] as String?) ?? j['id'] as String,
        subtitle: j['subtitle'] as String?,
        count: (j['count'] as num?)?.toInt() ?? 0,
        coverUrl: j['coverUrl'] as String?,
        readOnly: (j['readOnly'] as bool?) ?? true,
      );
}

class MediaItem {
  final String key;
  final String type;
  final String url;
  final String? thumbUrl;
  final String? note;
  final int? createdAt;
  final int? size;
  final String? lib;

  /// META に縮小サムネが保存済みか。false はクライアント側バックフィル対象。
  final bool thumbStored;

  const MediaItem({
    required this.key,
    required this.type,
    required this.url,
    this.thumbUrl,
    this.note,
    this.createdAt,
    this.size,
    this.lib,
    this.thumbStored = true,
  });

  factory MediaItem.fromJson(Map<String, dynamic> j) => MediaItem(
        key: j['key'] as String,
        type: (j['type'] as String?) ?? 'file',
        url: j['url'] as String,
        thumbUrl: j['thumbUrl'] as String?,
        note: j['note'] as String?,
        createdAt: (j['createdAt'] as num?)?.toInt(),
        size: (j['size'] as num?)?.toInt(),
        lib: j['lib'] as String?,
        thumbStored: (j['thumbStored'] as bool?) ?? true,
      );

  bool get isVideo => type == 'video';
  bool get isImage => type == 'image';
  String get name => key.split('/').last;
}

class TrashItem {
  final String trashKey;
  final String key;
  final int deletedAt;
  final int size;
  const TrashItem({
    required this.trashKey,
    required this.key,
    required this.deletedAt,
    required this.size,
  });

  factory TrashItem.fromJson(Map<String, dynamic> j) => TrashItem(
        trashKey: j['trashKey'] as String,
        key: j['key'] as String,
        deletedAt: (j['deletedAt'] as num?)?.toInt() ?? 0,
        size: (j['size'] as num?)?.toInt() ?? 0,
      );

  String get name => key.split('/').last;
}

class Page_<T> {
  final List<T> items;
  final String? cursor;
  const Page_(this.items, this.cursor);
}

/// ゴミ箱一覧の1ページ。保持日数は Worker の設定値（古い Worker は返さんので null）。
class TrashPage extends Page_<TrashItem> {
  final int? retentionDays;
  const TrashPage(super.items, super.cursor, {this.retentionDays});
}

class FolderPage {
  final List<MediaItem> items;
  final String? cursor;
  final String prefix;
  final List<String> folders;
  const FolderPage({
    required this.items,
    this.cursor,
    this.prefix = '',
    this.folders = const [],
  });
}

class AlbumPage {
  final List<MediaItem> items;
  final String? cursor;
  final String title;
  final int count;
  final bool readOnly;
  const AlbumPage({
    required this.items,
    this.cursor,
    this.title = '',
    this.count = 0,
    this.readOnly = true,
  });
}

class ApiError implements Exception {
  final int status;
  final String message;
  const ApiError(this.status, this.message);

  @override
  String toString() => status > 0 ? 'HTTP $status: $message' : message;
}
