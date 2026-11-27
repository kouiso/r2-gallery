import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/client.dart';
import '../api/models.dart';
import 'media_selection.dart';
import '../state/load_more_backoff.dart';
import '../state/trash_ops.dart';
import '../store/listing_cache.dart';

/// 画面を閉じた後に通信が返っても落ちないようにする共通部分。
mixin _SafeNotify on ChangeNotifier {
  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// フォルダ名の表示。worker は "a/b/" の形で返すので最後の段だけ出す。
String folderName(String prefix) {
  final t = prefix.endsWith('/') ? prefix.substring(0, prefix.length - 1) : prefix;
  final i = t.lastIndexOf('/');
  return i < 0 ? t : t.substring(i + 1);
}

/// アルバムタブ: アルバム一覧と、ライブラリ直下のフォルダ一覧。
class AlbumsHomeState extends ChangeNotifier with _SafeNotify {
  final ApiClient api;
  AlbumsHomeState(this.api);

  String? lib;
  List<Album> albums = [];
  List<String> folders = [];
  bool loading = false;
  String? error;
  int _epoch = 0;

  Future<void> load(String lib) async {
    final e = ++_epoch;
    if (this.lib != lib) {
      // 別のライブラリの一覧を出したまま操作させない
      albums = [];
      folders = [];
    }
    this.lib = lib;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final got = await Future.wait([
        api.albums(lib),
        api.folder(lib, prefix: ''),
      ]);
      if (e != _epoch) return;
      final a = got[0];
      final f = got[1];
      if (a is List<Album>) albums = a;
      if (f is FolderPage) folders = f.folders;
    } on ApiError catch (err) {
      if (e != _epoch) return;
      error = err.toString();
    }
    loading = false;
    notifyListeners();
  }

  /// 前面へ戻った時の復帰。表紙URLが切れている時だけ取り直す（#24 作業B）。
  /// フォルダ名にURLは無いので、表紙だけ見れば十分。
  Future<void> refreshIfExpired(String lib) {
    if (loading) return Future.value();
    if (albums.any(
        (a) => a.coverUrl != null && signedUrlExpired(a.coverUrl!))) {
      return load(lib);
    }
    return Future.value();
  }

  /// 失敗時は画面に出す文言を返す。成功したら一覧を取り直す。
  Future<String?> _run(String lib, Future<void> Function() op) async {
    try {
      await op();
    } on ApiError catch (e) {
      return e.toString();
    }
    await load(lib);
    return null;
  }

  /// 作成中で、まだサーバーの id が来ていないアルバム。開く・書き換えるのは id が来てから
  final Set<String> pending = {};
  int _tempSeq = 0;

  bool isPending(String albumId) => pending.contains(albumId);

  /// 結果を待たずに一覧へ足し、失敗したら外す。作成は id が要るので仮の id で出して差し替える。
  Future<String?> create(String lib, String title) async {
    final tempId = 'pending:${++_tempSeq}';
    pending.add(tempId);
    albums = [...albums, Album(id: tempId, title: title, readOnly: false)];
    notifyListeners();
    String? err;
    try {
      final id = await api.albumCreate(lib, title);
      albums = [
        for (final a in albums)
          if (a.id == tempId)
            Album(id: id, title: a.title, count: a.count, readOnly: false)
          else
            a,
      ];
    } on ApiError catch (e) {
      albums = albums.where((a) => a.id != tempId).toList();
      err = e.toString();
    }
    pending.remove(tempId);
    notifyListeners();
    return err;
  }

  /// 名前はすぐ書き換え、失敗したら元の名前へ戻す。
  Future<String?> rename(String lib, String albumId, String title) async {
    final before = albums.where((a) => a.id == albumId).firstOrNull;
    if (before == null) return null;
    _replace(albumId, _withTitle(before, title));
    try {
      await api.albumRename(lib, albumId, title);
      return null;
    } on ApiError catch (e) {
      // 送る間に別の名前へ変えていたら、そちらを潰さない
      if (albums.any((a) => a.id == albumId && a.title == title)) {
        _replace(albumId, before);
      }
      return e.toString();
    }
  }

  /// 一覧からすぐ外し、失敗したら元の位置へ戻す。
  Future<String?> delete(String lib, String albumId) async {
    final at = albums.indexWhere((a) => a.id == albumId);
    if (at < 0) return null;
    final removed = albums[at];
    albums = [...albums]..removeAt(at);
    notifyListeners();
    try {
      await api.albumDelete(lib, albumId);
      return null;
    } on ApiError catch (e) {
      if (!albums.any((a) => a.id == albumId)) {
        albums = [...albums]..insert(at.clamp(0, albums.length), removed);
        notifyListeners();
      }
      return e.toString();
    }
  }

  void _replace(String albumId, Album next) {
    albums = [for (final a in albums) a.id == albumId ? next : a];
    notifyListeners();
  }

  static Album _withTitle(Album a, String title) => Album(
      id: a.id,
      title: title,
      subtitle: a.subtitle,
      count: a.count,
      coverUrl: a.coverUrl,
      readOnly: a.readOnly);

  Future<String?> mkdir(String lib, String name) =>
      _run(lib, () => api.mkdir(lib, name));
}

/// アルバム・フォルダの中身に共通の、ページ送りと選択。
abstract class _PagedMediaState extends ChangeNotifier with _SafeNotify {
  final ApiClient api;
  final String lib;
  _PagedMediaState(this.api, this.lib,
      {this.loadMoreBackoff = const Duration(seconds: 3)});

  /// 続きの失敗の後に空ける待ちの1回目。失敗のたびに倍にして 60 秒で止める。
  /// 写真タブ（GalleryState）と同じ規則にするため共有の loadMoreBackoffAfter を使う（#25 作業3）
  final Duration loadMoreBackoff;

  List<MediaItem> items = [];
  String? cursor;
  bool loading = false;
  bool loadingMore = false;

  /// 最初の1ページが取れたか。読み込み前の一瞬に「空」を出さないための印
  bool loaded = false;
  String? error;
  int _epoch = 0;

  /// 続きの失敗が続いた回数。待ちの長さ（[loadMoreBackoffAfter]）に使う
  int _moreFailures = 0;
  Duration get _backoff => loadMoreBackoffAfter(loadMoreBackoff, _moreFailures);
  Timer? _backoffTimer;

  /// 最後に出した失敗が続きのものか。帯の「再試行」が先頭ではなく続きをやり直すための印
  bool _lastErrorFromMore = false;
  final MediaSelection selection = MediaSelection();
  bool bulkBusy = false;

  /// 1ページ取り、見出し等の付随情報もここで反映する。
  Future<({List<MediaItem> items, String? cursor})> fetchPage(String? cursor);

  Future<void> refresh() async {
    final e = ++_epoch;
    loading = true;
    // 取り直しの間に返ってきた古い続きページを積まないよう、ページ送りも打ち切る
    loadingMore = false;
    // 取り直しは続きの失敗の待ちと数を一旦消す
    _backoffTimer?.cancel();
    _backoffTimer = null;
    _moreFailures = 0;
    _lastErrorFromMore = false;
    error = null;
    notifyListeners();
    try {
      final p = await fetchPage(null);
      if (e != _epoch) return;
      items = p.items;
      cursor = p.cursor;
      loaded = true;
    } on ApiError catch (err) {
      if (e != _epoch) return;
      error = err.toString();
    }
    loading = false;
    notifyListeners();
  }

  Future<void> loadMore() async {
    if (cursor == null || loadingMore || loading || _backoffTimer != null) {
      return;
    }
    final e = _epoch;
    loadingMore = true;
    notifyListeners();
    try {
      final p = await fetchPage(cursor);
      if (e != _epoch) return;
      final seen = {for (final it in items) '${it.lib ?? lib}:${it.key}'};
      items = [
        ...items,
        ...p.items.where((it) => seen.add('${it.lib ?? lib}:${it.key}')),
      ];
      cursor = p.cursor;
      _moreFailures = 0;
      // 続きが取れたなら、続きの失敗の帯は消す
      if (_lastErrorFromMore) {
        error = null;
        _lastErrorFromMore = false;
      }
    } on ApiError catch (err) {
      if (e != _epoch) return;
      error = err.toString();
      _noteMoreFailure();
    }
    loadingMore = false;
    notifyListeners();
  }

  /// 続きの失敗を1回数えて、次を試すまでの待ちを始める。
  /// 明けたら通知し、末尾に居るグリッドに頼み直させる（写真タブと同じ規則）
  void _noteMoreFailure() {
    _moreFailures++;
    _lastErrorFromMore = true;
    _backoffTimer?.cancel();
    _backoffTimer = Timer(_backoff, () {
      _backoffTimer = null;
      notifyListeners();
    });
  }

  /// 帯の「再試行」。最後の失敗が続きなら、待ちを消して続きを頼み直す。
  /// それ以外（起動・引っ張って更新の失敗）は先頭から取り直す
  Future<void> retry() {
    if (_lastErrorFromMore) {
      _backoffTimer?.cancel();
      _backoffTimer = null;
      return loadMore();
    }
    return refresh();
  }

  /// 読み込み済みの行のどれかで署名URL（原本またはサムネ）が切れているか。
  bool get hasExpiredUrls => items.any((it) =>
      signedUrlExpired(it.url) ||
      (it.thumbUrl != null && signedUrlExpired(it.thumbUrl!)));

  /// 前面へ戻った時の復帰。載っている行のURLが切れている時だけ、先頭から
  /// 載っている分を覆える所まで取り直して各行を新しいURLへ差し替える。
  /// 並び・cursor・loaded はそのまま残す（#24 作業B）。
  Future<void> refreshIfExpired() async {
    if (!loaded || loading || _disposed || items.isEmpty || !hasExpiredUrls) {
      return;
    }
    final e = _epoch;
    final remaining = {for (final it in items) _rowId(it)};
    final byKey = <String, MediaItem>{};
    final loadedCount = items.length;
    var seen = 0;
    String? c;
    try {
      while (remaining.isNotEmpty && seen < loadedCount) {
        final p = await fetchPage(c);
        if (e != _epoch || _disposed) return;
        seen += p.items.length;
        for (final it in p.items) {
          final id = _rowId(it);
          if (remaining.remove(id)) byKey[id] = it;
        }
        c = p.cursor;
        if (c == null) break;
      }
    } on Object catch (err) {
      if (e != _epoch || _disposed) return;
      // 写真タブと同じく、断られた時だけ帯で見せ、回線の不調なら取れた分だけ替える（#24 作業B）
      if (isClientRejection(err)) {
        error = err.toString();
        notifyListeners();
        return;
      }
      debugPrint('album resign stopped: $err');
    }
    if (byKey.isEmpty) return;
    items = [for (final it in items) byKey[_rowId(it)] ?? it];
    notifyListeners();
  }

  String _rowId(MediaItem it) => '${it.lib ?? lib}:${it.key}';

  /// タップした行で開く一覧と位置。行の署名URLが切れていればその1件だけ引き直して差し替える。
  /// 復帰の差し替えが途中で切れると切れたURLの行が残り、そのまま開くと原本を読めないため
  /// （写真タブの GalleryState.openTarget と同じ扱い。#24 作業B）。消えていた・引けない時は null。
  Future<({List<MediaItem> items, int index})?> openTarget(MediaItem it) async {
    int indexIn(List<MediaItem> list) =>
        list.indexWhere((x) => _rowId(x) == _rowId(it));
    if (!signedUrlExpired(it.url)) {
      final at = indexIn(items);
      return at < 0 ? null : (items: items, index: at);
    }
    final MediaItem? fresh;
    try {
      fresh = await api.objectAt(it.lib ?? lib, it.key);
    } catch (_) {
      return null;
    }
    if (_disposed || fresh == null) return null;
    final row = it.lib != null && fresh.lib == null
        ? MediaItem.fromJson({...fresh.toJson(), 'lib': it.lib})
        : fresh;
    items = [for (final x in items) _rowId(x) == _rowId(it) ? row : x];
    notifyListeners();
    final at = indexIn(items);
    return at < 0 ? null : (items: items, index: at);
  }

  @override
  void dispose() {
    _backoffTimer?.cancel();
    super.dispose();
  }

  void toggle(MediaItem it) {
    selection.toggle(it, lib);
    notifyListeners();
  }

  void toggleAll(List<MediaItem> visible) {
    selection.toggleAll(visible, lib);
    notifyListeners();
  }

  void clearSelection() {
    selection.clear();
    notifyListeners();
  }

  /// 選択分をゴミ箱へ。戻し先と失敗数を返し、一覧を取り直す。
  Future<TrashOutcome> trashSelected() async {
    if (bulkBusy) return const TrashOutcome([], 0, 0);
    bulkBusy = true;
    final targets = selection.items;
    selection.clear();
    notifyListeners();
    // アルバムはライブラリが混ざるので、項目自身の lib へ送る
    final res = await trashAll(
        api, [for (final it in targets) (lib: it.lib ?? lib, key: it.key)]);
    bulkBusy = false;
    await refresh();
    return res;
  }
}

/// アルバムの中身。並びは worker が持つアルバム順のまま出す（手動の並び替えが見えるように）。
class AlbumDetailState extends _PagedMediaState {
  final String albumId;
  AlbumDetailState(super.api, super.lib, this.albumId,
      {super.loadMoreBackoff});

  String title = '';
  int count = 0;

  /// 取り込み処理が作ったアルバムなど、中身を書き換えられないもの。分かるまでは書き換え不可として扱う
  bool albumReadOnly = true;
  bool opsBusy = false;

  /// 1ページ目の既定件数。KMP 版と同じく小さめにして、続きは末尾付近で自動で読む
  static const pageSize = 60;

  @override
  Future<({List<MediaItem> items, String? cursor})> fetchPage(
      String? cursor) async {
    final p = await api.album(lib, albumId, cursor: cursor, limit: pageSize);
    if (cursor == null) {
      title = p.title;
      count = p.count;
      albumReadOnly = p.readOnly;
    }
    return (items: p.items, cursor: p.cursor);
  }

  /// 選択中の1件を前後へ動かす。並び順は全件を書き戻すので、読み込み済みの範囲ではなく全件を取り直す。
  Future<String?> moveSelected(int delta) async {
    final picked = selection.items;
    if (picked.length != 1) return null;
    return moveItem(picked.single, delta);
  }

  bool _same(MediaItem a, MediaItem b) =>
      a.key == b.key && (a.lib ?? lib) == (b.lib ?? lib);

  String _id(MediaItem it) => '${it.lib ?? lib}:${it.key}';

  /// 操作前の並び [before] へ戻す。送っている間に続きのページが載っていたら、その分は後ろに残す。
  void _rollbackTo(List<MediaItem> before) {
    final known = {for (final it in before) _id(it)};
    items = [...before, ...items.where((it) => !known.contains(_id(it)))];
  }

  /// 1件を前後へ動かす（長押しメニューの「前に移す／後ろに移す」と共用）。
  /// 見えている並びはすぐ動かし、書き戻せなかったら元の並びへ戻す。
  Future<String?> moveItem(MediaItem item, int delta) async {
    if (opsBusy) return null;
    opsBusy = true;
    final before = items;
    final shown = before.indexWhere((it) => _same(it, item));
    if (shown >= 0) {
      final to = (shown + delta).clamp(0, before.length - 1);
      items = [...before]..removeAt(shown);
      items.insert(to, item);
    }
    notifyListeners();
    String? err;
    try {
      final all = await api.albumAll(lib, albumId);
      final at = all.indexWhere((it) => _same(it, item));
      if (at < 0) {
        err = '並び替えに失敗しました';
      } else {
        final to = (at + delta).clamp(0, all.length - 1);
        if (to != at) {
          final moved = all.removeAt(at);
          all.insert(to, moved);
          await api.albumOrder(lib, albumId, all);
        }
      }
    } on ApiError {
      err = '並び替えに失敗しました';
    }
    // 失敗したら動かす前の並びへ戻す。読み直しは要らない（手元の並びがサーバーと同じ）
    if (err != null) _rollbackTo(before);
    opsBusy = false;
    notifyListeners();
    return err;
  }

  /// 選択分をアルバムから外す。worker は lib ごとに受けるので項目の lib で束ねる。
  Future<String?> removeSelected() {
    final targets = selection.items;
    selection.clear();
    return removeItems(targets);
  }

  /// [targets] をアルバムから外す（長押しメニューの「このアルバムから外す」と共用）。
  /// 行はすぐ外し、外せなかったライブラリの分だけ元の位置へ戻す。
  Future<String?> removeItems(List<MediaItem> targets) async {
    if (opsBusy || targets.isEmpty) return null;
    opsBusy = true;
    final before = items;
    final shownCount = count;
    items = before.where((it) => !targets.any((t) => _same(t, it))).toList();
    count = (count - (before.length - items.length)).clamp(0, count);
    notifyListeners();
    String? err;
    final byLib = <String, List<String>>{};
    for (final it in targets) {
      byLib.putIfAbsent(it.lib ?? lib, () => []).add(it.key);
    }
    final failedLibs = <String>{};
    for (final e in byLib.entries) {
      try {
        await api.albumRemove(e.key, albumId, e.value);
      } on ApiError {
        failedLibs.add(e.key);
        err = 'アルバムから外せませんでした';
      }
    }
    if (failedLibs.isNotEmpty) {
      // 外せた分は外したまま、外せなかった分を元の並びの位置へ戻す
      final gone = {
        for (final t in targets)
          if (!failedLibs.contains(t.lib ?? lib)) _id(t),
      };
      _rollbackTo([
        for (final it in before)
          if (!gone.contains(_id(it))) it,
      ]);
      count = (shownCount - gone.length).clamp(0, shownCount);
    }
    opsBusy = false;
    notifyListeners();
    return err;
  }
}

/// 中身を書き換える操作をさせてよいか。ライブラリが読み取り専用なら一切出さない。
bool canEditAlbum({required bool libReadOnly, required bool albumReadOnly, required String albumId}) =>
    !libReadOnly && !albumReadOnly && albumId != otherAlbumId;
