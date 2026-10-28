import 'package:flutter/foundation.dart';

import '../api/client.dart';
import '../api/models.dart';
import 'media_selection.dart';
import '../state/trash_ops.dart';

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

  Future<String?> create(String lib, String title) =>
      _run(lib, () => api.albumCreate(lib, title));

  Future<String?> rename(String lib, String albumId, String title) =>
      _run(lib, () => api.albumRename(lib, albumId, title));

  Future<String?> delete(String lib, String albumId) =>
      _run(lib, () => api.albumDelete(lib, albumId));

  Future<String?> mkdir(String lib, String name) =>
      _run(lib, () => api.mkdir(lib, name));
}

/// アルバム・フォルダの中身に共通の、ページ送りと選択。
abstract class _PagedMediaState extends ChangeNotifier with _SafeNotify {
  final ApiClient api;
  final String lib;
  _PagedMediaState(this.api, this.lib);

  List<MediaItem> items = [];
  String? cursor;
  bool loading = false;
  bool loadingMore = false;

  /// 最初の1ページが取れたか。読み込み前の一瞬に「空」を出さないための印
  bool loaded = false;
  String? error;
  int _epoch = 0;

  /// 続きの取得に失敗したら、取り直すまで自動では読みに行かない（失敗の繰り返しで通信し続けないため）
  bool _moreFailed = false;
  final MediaSelection selection = MediaSelection();
  bool bulkBusy = false;

  /// 1ページ取り、見出し等の付随情報もここで反映する。
  Future<({List<MediaItem> items, String? cursor})> fetchPage(String? cursor);

  Future<void> refresh() async {
    final e = ++_epoch;
    loading = true;
    // 取り直しの間に返ってきた古い続きページを積まないよう、ページ送りも打ち切る
    loadingMore = false;
    _moreFailed = false;
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
    if (cursor == null || loadingMore || loading || _moreFailed) return;
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
    } on ApiError catch (err) {
      if (e != _epoch) return;
      error = err.toString();
      _moreFailed = true;
    }
    loadingMore = false;
    notifyListeners();
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
  AlbumDetailState(super.api, super.lib, this.albumId);

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

  /// 1件を前後へ動かす（長押しメニューの「前に移す／後ろに移す」と共用）。
  Future<String?> moveItem(MediaItem item, int delta) async {
    if (opsBusy) return null;
    opsBusy = true;
    notifyListeners();
    String? err;
    try {
      final all = await api.albumAll(lib, albumId);
      final at = all.indexWhere(
          (it) => it.key == item.key && (it.lib ?? lib) == (item.lib ?? lib));
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
    opsBusy = false;
    notifyListeners();
    if (err == null) await refresh();
    return err;
  }

  /// 選択分をアルバムから外す。worker は lib ごとに受けるので項目の lib で束ねる。
  Future<String?> removeSelected() {
    final targets = selection.items;
    selection.clear();
    return removeItems(targets);
  }

  /// [targets] をアルバムから外す（長押しメニューの「このアルバムから外す」と共用）。
  Future<String?> removeItems(List<MediaItem> targets) async {
    if (opsBusy || targets.isEmpty) return null;
    opsBusy = true;
    notifyListeners();
    String? err;
    final byLib = <String, List<String>>{};
    for (final it in targets) {
      byLib.putIfAbsent(it.lib ?? lib, () => []).add(it.key);
    }
    try {
      for (final e in byLib.entries) {
        await api.albumRemove(e.key, albumId, e.value);
      }
    } on ApiError {
      err = 'アルバムから外せませんでした';
    }
    opsBusy = false;
    await refresh();
    return err;
  }
}

/// 中身を書き換える操作をさせてよいか。ライブラリが読み取り専用なら一切出さない。
bool canEditAlbum({required bool libReadOnly, required bool albumReadOnly, required String albumId}) =>
    !libReadOnly && !albumReadOnly && albumId != otherAlbumId;
