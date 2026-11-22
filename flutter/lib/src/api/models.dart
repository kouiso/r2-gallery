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

  /// 起動を回線待ちにしないため、最後に見えた一覧を端末に控える用（#24 作業A）。
  Map<String, dynamic> toJson() =>
      {'id': id, 'title': title, 'readOnly': readOnly};
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

  /// HEIC を読めない環境向けの JPEG の写し（/v/ の署名 URL）。写しが無い形式は null。
  final String? viewUrl;

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
    this.viewUrl,
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
        viewUrl: j['viewUrl'] as String?,
      );

  /// 一覧の先頭ページを端末に残すため。fromJson で読み戻せる形にする
  Map<String, dynamic> toJson() => {
        'key': key,
        'type': type,
        'url': url,
        'thumbUrl': ?thumbUrl,
        'note': ?note,
        'createdAt': ?createdAt,
        'size': ?size,
        'lib': ?lib,
        'thumbStored': thumbStored,
        'viewUrl': ?viewUrl,
      };

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

class PageOf<T> {
  final List<T> items;
  final String? cursor;
  const PageOf(this.items, this.cursor);
}

/// ゴミ箱一覧の1ページ。保持日数は Worker の設定値（古い Worker は返さんので null）。
class TrashPage extends PageOf<TrashItem> {
  final int? retentionDays;
  const TrashPage(super.items, super.cursor, {this.retentionDays});
}

class FolderPage {
  final List<MediaItem> items;
  final String? cursor;
  final String prefix;
  final List<String> folders;

  /// Worker が実際に適用した並び順。古い Worker は返さないので null になり、
  /// その場合は端末側で並べ直す。
  final String? sort;

  /// 一覧全体のメディア件数。古い Worker は返さないので null。
  final int? total;
  const FolderPage({
    required this.items,
    this.cursor,
    this.prefix = '',
    this.folders = const [],
    this.sort,
    this.total,
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

  /// Worker が本文で返す `{"error": "..."}` の値。同じ 409 でも理由で次の動きが変わるため残す。
  final String? code;
  const ApiError(this.status, this.message, {this.code});

  @override
  String toString() => status > 0 ? 'HTTP $status: $message' : message;
}

/// 中身がバイト単位で同じ（SHA-256 一致）項目の組。[items] は古い順で、先頭が残す候補。
class DuplicateGroup {
  final String sha256;
  final int size;
  final List<MediaItem> items;
  const DuplicateGroup(
      {required this.sha256, required this.size, required this.items});

  factory DuplicateGroup.fromJson(Map<String, dynamic> j) => DuplicateGroup(
        sha256: j['sha256'] as String,
        size: (j['size'] as num?)?.toInt() ?? 0,
        items: ((j['items'] as List?) ?? const [])
            .map((e) => MediaItem.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// 重複の一覧の1ページ。[total]・[reclaimable] はライブラリ全体の値。
class DuplicatePage {
  final List<DuplicateGroup> groups;
  final String? cursor;
  final int total;
  final int reclaimable;
  final int pending;
  final int skipped;
  const DuplicatePage({
    required this.groups,
    this.cursor,
    this.total = 0,
    this.reclaimable = 0,
    this.pending = 0,
    this.skipped = 0,
  });
}

/// 重複確認のための計算（Worker 側のハッシュ）を1回分進めた結果。
class DuplicateScan {
  final int pending;
  final int hashed;
  final int skipped;
  const DuplicateScan(
      {required this.pending, required this.hashed, required this.skipped});
}

/// アップロード前の照合の1件分。[matches] は sha256 を送った時だけ埋まる。
class ObjectCheckResult {
  final int sizeMatches;
  final List<MediaItem> matches;
  const ObjectCheckResult({required this.sizeMatches, this.matches = const []});
}

class ObjectCheck {
  final List<ObjectCheckResult> results;
  final int pending;
  const ObjectCheck({required this.results, this.pending = 0});
}
