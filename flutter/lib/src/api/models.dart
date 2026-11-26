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

// ---- 見た目の照合（重複・似ている写真）----

/// 署名の方式名。Worker と食い違うと 409 alg_mismatch で弾かれ、アプリの更新が要ると分かる
const similarAlg = 'vs1';

// 数の欄は Worker が省いたり null を返したりしても画面を落とさず 0 として扱う
int _n(Map j, String k) => (j[k] as num?)?.toInt() ?? 0;
int? _optN(Map j, String k) => (j[k] as num?)?.toInt();
Map _obj(Object? v) => v is Map ? v : const {};

/// 見た目の照合がどこまで済んだか。照合の前に通信量を見積もって同意を取るのに使う
class SimilarStatus {
  final String alg;
  final String params;
  final int images;
  final int signed;
  final int failed;
  final int flat;
  final int pending;
  final int pendingWithThumb;
  final int pendingNoThumb;
  final int pendingBytesEstimate;

  /// Worker が 1 回に受ける署名の件数（SIMILAR_SIG_BATCH）。載っていなければ null（上限の 200 を使う）
  final int? sigBatch;

  /// Worker が 1 回に受けるゴミ箱・取り消しの件数（SIMILAR_TRASH_BATCH）。載っていなければ null（40）
  final int? trashBatch;
  const SimilarStatus({
    this.alg = similarAlg,
    this.params = '',
    this.images = 0,
    this.signed = 0,
    this.failed = 0,
    this.flat = 0,
    this.pending = 0,
    this.pendingWithThumb = 0,
    this.pendingNoThumb = 0,
    this.pendingBytesEstimate = 0,
    this.sigBatch,
    this.trashBatch,
  });

  factory SimilarStatus.fromJson(Map j) => SimilarStatus(
        alg: (j['alg'] as String?) ?? similarAlg,
        params: (j['params'] as String?) ?? '',
        images: _n(j, 'images'),
        signed: _n(j, 'signed'),
        failed: _n(j, 'failed'),
        flat: _n(j, 'flat'),
        pending: _n(j, 'pending'),
        pendingWithThumb: _n(j, 'pendingWithThumb'),
        pendingNoThumb: _n(j, 'pendingNoThumb'),
        pendingBytesEstimate: _n(j, 'pendingBytesEstimate'),
        sigBatch: _batch(j['sigBatch']),
        trashBatch: _batch(j['trashBatch']),
      );

  static int? _batch(Object? v) => v is num && v >= 1 ? v.toInt() : null;
}

/// まだ署名の無い画像1件。[etag] は署名を送る時に添え、Worker が入れ替わりを見分ける
class SimilarTodoItem {
  final MediaItem item;
  final String etag;
  final int size;
  final String ext;
  const SimilarTodoItem({
    required this.item,
    required this.etag,
    required this.size,
    required this.ext,
  });

  /// todo は画像しか返さず type や lib を省くことがあるので、既定をここで補う
  factory SimilarTodoItem.fromJson(Map<String, dynamic> j, {String? lib}) =>
      SimilarTodoItem(
        item: MediaItem.fromJson({'type': 'image', 'lib': ?lib, ...j}),
        etag: (j['etag'] as String?) ?? '',
        size: _n(j, 'size'),
        ext: (j['ext'] as String?) ?? '',
      );

  String get key => item.key;
}

/// todo の1ページ。[next] が null ならその shard は読み切った
class SimilarTodoPage {
  final int shard;
  final List<SimilarTodoItem> items;
  final String? next;
  final int pendingInShard;
  const SimilarTodoPage({
    required this.shard,
    required this.items,
    this.next,
    this.pendingInShard = 0,
  });

  factory SimilarTodoPage.fromJson(Map j, {String? lib}) => SimilarTodoPage(
        shard: _n(j, 'shard'),
        items: ((j['items'] as List?) ?? const [])
            .map((e) =>
                SimilarTodoItem.fromJson(e as Map<String, dynamic>, lib: lib))
            .toList(),
        next: j['next'] as String?,
        pendingInShard: _n(j, 'pendingInShard'),
      );
}

/// 署名1件ぶんの送信内容。読めなかった物も [fail] で送り、次回から取り直さないようにする
class SignatureUpload {
  final String key;
  final String etag;

  /// "t" は保存済みサムネ、"o" は原本から作った物
  final String src;

  /// 297 バイトの署名を base64url（パディング無し）にした物
  final String? sig;

  /// "decode" か "too_large"
  final String? fail;

  const SignatureUpload._(this.key, this.etag, this.src, this.sig, this.fail);
  const SignatureUpload.signed({
    required String key,
    required String etag,
    required String src,
    required String sig,
  }) : this._(key, etag, src, sig, null);
  const SignatureUpload.failed({
    required String key,
    required String etag,
    required String src,
    required String fail,
  }) : this._(key, etag, src, null, fail);

  Map<String, dynamic> toJson() => {
        'key': key,
        'etag': etag,
        'src': src,
        'sig': ?sig,
        'fail': ?fail,
      };
}

/// 署名の送信結果。[stale] は送る間に中身が入れ替わって捨てられた件数
class SignaturePostResult {
  final int stored;
  final int stale;
  final int failRecorded;
  const SignaturePostResult(
      {this.stored = 0, this.stale = 0, this.failRecorded = 0});

  factory SignaturePostResult.fromJson(Map j) => SignaturePostResult(
        stored: _n(j, 'stored'),
        stale: _n(j, 'stale'),
        failRecorded: _n(j, 'failRecorded'),
      );
}

/// 組の中の1件。[match] は keeper / identical / same / mirror / similar のどれか
class SimilarMember {
  final MediaItem item;
  final int size;
  final String match;
  final int? ph;
  final int? dh;

  /// 原本の大きさと形式が同じで、細かい差分があるかもしれない（差分かも）
  final bool variant;
  final int? ow;
  final int? oh;
  const SimilarMember({
    required this.item,
    required this.size,
    required this.match,
    this.ph,
    this.dh,
    this.variant = false,
    this.ow,
    this.oh,
  });

  factory SimilarMember.fromJson(Map<String, dynamic> j) => SimilarMember(
        item: MediaItem.fromJson(j),
        size: _n(j, 'size'),
        // 欠けた時は一括選択に拾われない一番弱い札にして、誤って消す側へ倒さない
        match: (j['match'] as String?) ?? 'similar',
        ph: _optN(j, 'ph'),
        dh: _optN(j, 'dh'),
        variant: (j['variant'] as bool?) ?? false,
        ow: _optN(j, 'ow'),
        oh: _optN(j, 'oh'),
      );

  String get key => item.key;
  bool get isKeeper => match == 'keeper';
}

/// 残す1件（keeper）を中心にした組。[id] は keeper のキーで、[more] は応答に載らなかった件数
class SimilarGroup {
  final String id;

  /// "dup" か "similar"
  final String tier;
  final int reclaim;
  final List<SimilarMember> members;
  final int more;
  const SimilarGroup({
    required this.id,
    required this.tier,
    required this.members,
    this.reclaim = 0,
    this.more = 0,
  });

  factory SimilarGroup.fromJson(Map<String, dynamic> j) => SimilarGroup(
        id: j['id'] as String,
        tier: (j['tier'] as String?) ?? 'dup',
        reclaim: _n(j, 'reclaim'),
        members: ((j['items'] as List?) ?? const [])
            .map((e) => SimilarMember.fromJson(e as Map<String, dynamic>))
            .toList(),
        more: _n(j, 'more'),
      );
}

/// 1つの段（重複／似ている）の合計。[reclaimable] は重複の段にだけ入る
class SimilarTierSummary {
  final int groups;
  final int items;
  final int reclaimable;
  const SimilarTierSummary(
      {this.groups = 0, this.items = 0, this.reclaimable = 0});

  factory SimilarTierSummary.fromJson(Map j) => SimilarTierSummary(
        groups: _n(j, 'groups'),
        items: _n(j, 'items'),
        reclaimable: _n(j, 'reclaimable'),
      );
}

/// 照合が届いた範囲。見つからなかった理由を画面で言い分けるために残す
class SimilarCoverage {
  final int images;
  final int signed;
  final int pending;
  final int failed;
  final int flat;
  const SimilarCoverage({
    this.images = 0,
    this.signed = 0,
    this.pending = 0,
    this.failed = 0,
    this.flat = 0,
  });

  factory SimilarCoverage.fromJson(Map j) => SimilarCoverage(
        images: _n(j, 'images'),
        signed: _n(j, 'signed'),
        pending: _n(j, 'pending'),
        failed: _n(j, 'failed'),
        flat: _n(j, 'flat'),
      );
}

/// ライブラリ全体の合計。ページに依らず同じ値が返る
class SimilarSummary {
  final SimilarTierSummary dup;
  final SimilarTierSummary similar;
  final int crowded;
  final SimilarCoverage coverage;
  final int hashPending;
  final int hashSkipped;
  const SimilarSummary({
    this.dup = const SimilarTierSummary(),
    this.similar = const SimilarTierSummary(),
    this.crowded = 0,
    this.coverage = const SimilarCoverage(),
    this.hashPending = 0,
    this.hashSkipped = 0,
  });

  factory SimilarSummary.fromJson(Map j) => SimilarSummary(
        dup: SimilarTierSummary.fromJson(_obj(j['dup'])),
        similar: SimilarTierSummary.fromJson(_obj(j['similar'])),
        crowded: _n(j, 'crowded'),
        coverage: SimilarCoverage.fromJson(_obj(j['coverage'])),
        hashPending: _n(j, 'hashPending'),
        hashSkipped: _n(j, 'hashSkipped'),
      );
}

/// 組の一覧の1ページ。[cursor] は「この組の後ろから」の意味で、削除しても位置がずれない
class SimilarPage {
  final List<SimilarGroup> groups;
  final String? cursor;
  final int total;
  final SimilarSummary summary;
  const SimilarPage({
    required this.groups,
    this.cursor,
    this.total = 0,
    this.summary = const SimilarSummary(),
  });

  factory SimilarPage.fromJson(Map j) => SimilarPage(
        groups: ((j['groups'] as List?) ?? const [])
            .map((e) => SimilarGroup.fromJson(e as Map<String, dynamic>))
            .toList(),
        cursor: j['cursor'] as String?,
        total: _n(j, 'total'),
        summary: SimilarSummary.fromJson(_obj(j['summary'])),
      );
}

/// オリジナルを選び直した時の1件ぶんの付け直し結果。[match] が null なら新しいオリジナルとは別物
class SimilarLabel {
  final String? match;
  final int? ph;
  final int? dh;
  final bool variant;
  const SimilarLabel({this.match, this.ph, this.dh, this.variant = false});

  factory SimilarLabel.fromJson(Map j) => SimilarLabel(
        match: j['match'] as String?,
        ph: _optN(j, 'ph'),
        dh: _optN(j, 'dh'),
        variant: (j['variant'] as bool?) ?? false,
      );
}

/// 一括ゴミ箱の1件ぶん。失敗は [error] の理由で再読み込みの要否を決める
class SimilarTrashItemResult {
  final String key;
  final bool ok;
  final String? trashKey;

  /// 成功時、Worker が確かめ直した種類（identical / same / mirror / similar）
  final String? kind;
  final String? error;
  const SimilarTrashItemResult({
    required this.key,
    required this.ok,
    this.trashKey,
    this.kind,
    this.error,
  });

  factory SimilarTrashItemResult.fromJson(Map j) => SimilarTrashItemResult(
        key: (j['key'] as String?) ?? '',
        ok: (j['ok'] as bool?) ?? false,
        trashKey: j['trashKey'] as String?,
        kind: j['kind'] as String?,
        error: j['error'] as String?,
      );
}

/// 一括の取り消しの1件ぶん
class SimilarUndoItemResult {
  final String trashKey;
  final bool ok;
  final String? key;
  final String? error;
  final int? status;
  const SimilarUndoItemResult({
    required this.trashKey,
    required this.ok,
    this.key,
    this.error,
    this.status,
  });

  factory SimilarUndoItemResult.fromJson(Map j) => SimilarUndoItemResult(
        trashKey: (j['trashKey'] as String?) ?? '',
        ok: (j['ok'] as bool?) ?? false,
        key: j['key'] as String?,
        error: j['error'] as String?,
        status: _optN(j, 'status'),
      );
}
