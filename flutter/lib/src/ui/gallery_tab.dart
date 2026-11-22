
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../api/models.dart';
import '../grid/media_controller.dart';
import '../grid/media_list_body.dart';
import '../grid/state_views.dart';
import '../state/app_state.dart';
import '../state/write_guard.dart';
import '../store/kv.dart';
import '../upload/image_thumb.dart';
import '../upload/thumbs.dart';
import '../transfer/upload_confirm.dart';
import '../webdl/web_transfer.dart';
import 'media_tile.dart';
import 'theme.dart';
import 'viewer_screen.dart';
import 'write_guard_notice.dart';

/// 写真タブ: 並び替え・日付見出しつきの密なグリッド + 複数選択 + アップロード。
/// 選択中の見出しと操作バーはシェルが描く（app.photosChrome 経由）。
class GalleryTab extends StatefulWidget {
  final AppState app;
  final String lib;

  /// エラー画面の「接続先を確認する」。設定タブへ移る。
  final VoidCallback? onOpenSettings;

  /// 端末側でサムネを補完するか。Web ではエンジンの ImageDescriptor が使えず、
  /// 原本を取っても必ず失敗するので既定で止める（テストから差し替えるために引数にしてある）
  final bool backfillThumbs;
  const GalleryTab(
      {super.key,
      required this.app,
      required this.lib,
      this.onOpenSettings,
      this.backfillThumbs = !kIsWeb});

  @override
  State<GalleryTab> createState() => _GalleryTabState();
}

/// サムネが保存できたら、未保存の間に積んだ原本のキャッシュ('#orig')は用済みなので消す。
/// 残すと原本の置き場が件数上限まで容量を食う。
Future<void> _dropOrigCache(MediaItem item) async {
  final url = item.thumbUrl;
  if (url == null) return;
  await thumbCacheFor(stored: false)
      .removeFile(thumbCacheKey(url, stored: false));
}

class _GalleryTabState extends State<GalleryTab> {
  // ライブラリごとに一覧を持ち続け、切り替えて戻った時は手元の一覧を即出して裏で取り直す
  final Map<String, GalleryState> _states = {};
  StreamSubscription<Object>? _doneSub;
  StreamSubscription<String>? _changeSub;
  StreamSubscription<void>? _resumeSub;
  final Set<String> _finishedImports = {};

  GalleryState get g => _stateFor(widget.lib);

  GalleryState _stateFor(String lib) => _states.putIfAbsent(lib, () {
        final s = GalleryState(widget.app.api,
            sort: widget.app.photosChrome.sort,
            cache: widget.app.listingCache);
        s.refresh(lib);
        return s;
      });

  late final MediaController _c = MediaController(widget.app);

  @override
  void initState() {
    super.initState();
    _c.bind(_stateFor(widget.lib), widget.lib);
    widget.app.photosChrome.attach(_c);
    widget.app.photosChrome.addListener(_onSortChanged);
    // 裏で上がり終わったら、そのライブラリの一覧を取り直して新しいファイルを出す。
    // 読み進めた位置と続きのページは残す
    _doneSub = widget.app.transfers.doneEvents.listen((t) {
      if (t.isUpload) _states[t.lib]?.softRefresh(t.lib);
    });
    _finishedImports.addAll(widget.app.webQueue.tasks
        .where((t) => t.status == WebTaskStatus.done)
        .map((t) => t.id));
    widget.app.webQueue.addListener(_onImportsChanged);
    // ゴミ箱タブで戻した写真を、写真タブに戻った時に出す
    // 読み込み中なら、終わった後に1回だけ取り直す
    _changeSub = widget.app.contentChanged
        .listen((lib) => _states[lib]?.softRefresh(lib));
    // 裏でURLの寿命が切れていた分だけ、復帰時に各一覧が取り直す（#24 作業B）
    _resumeSub = widget.app.resumed.listen((_) {
      for (final e in _states.entries) {
        e.value.refreshIfExpired(e.key);
      }
    });
    _resumeLostPick();
  }

  // ピッカーを開いている間にアプリが落ちると選択は戻らない。開いた時のライブラリを
  // pendingPickLib に控えているので、次の起動で写真タブが出た後に1回だけ選び直させる。
  // 控えが違うライブラリか無ければ何もしない（決めた事 13）
  static bool _pickResumed = false;
  void _resumeLostPick() {
    if (_pickResumed) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (_pickResumed) return;
      _pickResumed = true;
      String? pending;
      try {
        pending = await Kv.get(Keys.pendingPickLib);
      } catch (_) {
        // テストなど KV が無い環境では再開しない
        return;
      }
      if (pending == null || pending != widget.lib || !mounted) return;
      try {
        await Kv.remove(Keys.pendingPickLib);
      } catch (_) {}
      if (!mounted) return;
      // 選択自体は消えているので、確認シートではなくピッカーから選び直す
      await pickAndConfirmUpload(context, widget.app, widget.lib);
    });
  }

  // 並び順・種別の絞り込みは Worker に渡して取り直す。端末側の処理だと読み込み済みの分にしか効かない
  void _onSortChanged() {
    final chrome = widget.app.photosChrome;
    final s = _states[widget.lib];
    if (s == null) return;
    if (s.sort != chrome.sort) s.changeSort(chrome.sort, widget.lib);
    if (s.kind != chrome.kind) s.changeKind(chrome.kind, widget.lib);
  }

  void _onImportsChanged() {
    final done = widget.app.webQueue.tasks
        .where((t) => t.status == WebTaskStatus.done)
        .toList();
    final ids = done.map((t) => t.id).toSet();
    _finishedImports.removeWhere((id) => !ids.contains(id));
    // 写真タブは裏でも一覧を持つため、ネット取り込みも完了時に保存先だけ取り直す。
    // 進捗や完了行の後片付けの通知では、同じ一覧を繰り返し取得しない。
    final changedLibs = {
      for (final t in done)
        if (_finishedImports.add(t.id)) t.lib,
    };
    for (final lib in changedLibs) {
      _states[lib]?.softRefresh(lib);
    }
  }

  @override
  void didUpdateWidget(GalleryTab old) {
    super.didUpdateWidget(old);
    if (old.lib == widget.lib) return;
    // KMP 版と同じく、ライブラリを離れたら選択は解く
    _states[old.lib]?.clearSelection();
    final cached = _states[widget.lib];
    if (cached == null) {
      _stateFor(widget.lib);
    } else if (cached.sort != widget.app.photosChrome.sort ||
        cached.kind != widget.app.photosChrome.kind) {
      // 離れている間に並び順・絞り込みが変わっていた
      cached.changeSort(widget.app.photosChrome.sort, widget.lib);
      cached.changeKind(widget.app.photosChrome.kind, widget.lib);
    } else if (!cached.loading) {
      cached.softRefresh(widget.lib);
    }
    _c.bind(_stateFor(widget.lib), widget.lib);
  }

  @override
  void dispose() {
    widget.app.photosChrome.removeListener(_onSortChanged);
    widget.app.photosChrome.detach(_c);
    _c.dispose();
    _doneSub?.cancel();
    _changeSub?.cancel();
    _resumeSub?.cancel();
    widget.app.webQueue.removeListener(_onImportsChanged);
    for (final s in _states.values) {
      s.dispose();
    }
    super.dispose();
  }

  Future<Uint8List?> _makeThumb(MediaItem item) async {
    if (item.isVideo) return videoThumb(item.url);
    if (!item.isImage) return null;
    // 上限を超える原本は途中で切る。大きさの無い行でも丸ごとメモリへ読ませない（#1 作業2）
    final bytes = await widget.app.api
        .fetchBytes(item.url, maxBytes: maxThumbSourceBytes);
    return makeImageThumb(bytes);
  }

  Future<void> _refresh() => _stateFor(widget.lib).refresh(widget.lib);

  Future<void> _openPlayer(List<MediaItem> sorted, int index) async {
    final lib = widget.lib;
    final g = _stateFor(lib);
    // 控えの一覧から開く時は、期限の切れた署名URLを新しいものに替えてから開く
    final target = await g.openTarget(sorted, index, lib: lib);
    if (target == null || !mounted || widget.lib != lib) return;
    await openViewer(context,
        app: widget.app,
        lib: lib,
        items: target.items,
        index: target.index,
        // 開いた後に一覧が読み込む続きのページも、スワイプで辿れるようにする
        source: g,
        readItems: g.ordered,
        onNearEnd: () => g.loadMore(lib),
        // 操作を始めたライブラリの一覧を直す。終わる前に切り替えても別のライブラリを触らない
        onChanged: () => g.softRefresh(lib),
        onTrash: (it) => _c.trashOne(context, it));
  }

  // 選んだ後に確認シート（保存先・合計サイズ・先頭の数件）を挟み、押した時だけ転送キューに積む（#149）。
  // 書けない保存先はファイル選択を開く前に理由を出して止める（#145）
  Future<void> _upload() async {
    if (!ensureWritable(context, widget.app, widget.lib, WriteAction.upload)) {
      return;
    }
    await pickAndConfirmUpload(context, widget.app, widget.lib);
  }

  @override
  Widget build(BuildContext context) {
    final g = this.g;
    final chrome = widget.app.photosChrome;
    return ListenableBuilder(
      // オフライン保存の目録が変わったら「保存済み」の印を出し直す
      listenable: Listenable.merge([g, chrome, widget.app.offline]),
      builder: (context, _) {
        final sorted = g.ordered();
        final readOnly = _c.readOnly;
        // サムネ未生成分は開いた一覧のついでに裏で補完する。
        // 書き戻せないライブラリでは原本を取りに行くだけ無駄なので回さない。
        // Web は作れないサムネのために原本を落とし続けるだけなので回さない（#58）
        if (widget.backfillThumbs &&
            sorted.isNotEmpty &&
            widget.app.canWriteTo(widget.lib)) {
          g.backfillThumbs(widget.lib,
              makeThumb: _makeThumb, onThumbStored: _dropOrigCache);
        }
        return PopScope(
          // 選択中の戻るは選択を解くだけにする（アプリごと閉じて選択を失わせない）
          canPop: !g.selectionMode,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) g.clearSelection();
          },
          child: Stack(
          children: [
            Positioned.fill(
              child: MediaListBody(
                c: _c,
                sort: chrome.sort,
                sorted: sorted,
                // ライブラリ・並び順・種別を替えたら、別の一覧として作り直して先頭から見せる（KMP 版と同じ）
                gridKey: ValueKey('grid-${widget.lib}-${g.sort.apiValue}-${g.kind.apiValue}'),
                onOpenItem: (i) => _openPlayer(sorted, i),
                errorActions: [
                  StatePrimaryButton('再試行', _refresh),
                  if (widget.onOpenSettings != null)
                    StateTextButton('接続先を確認する', widget.onOpenSettings!),
                ],
                empty: StateView(
                  icon: Icons.photo_library_outlined,
                  title: 'まだ写真がありません',
                  body: '端末の写真や動画をアップロードするか、「取り込み」でWebから保存できます。',
                  actions: [
                    if (!readOnly) StatePrimaryButton('写真・動画を追加', _upload),
                  ],
                ),
              ),
            ),
            // 空・エラーの時は画面中央のボタンが同じ役目なので出さない。読み取り専用では追加させない
            if (!g.selectionMode && !readOnly && sorted.isNotEmpty)
              Positioned(
                right: 16,
                bottom: 16,
                child: FloatingActionButton.extended(
                  onPressed: _upload,
                  backgroundColor: AppColors.accent,
                  foregroundColor: AppColors.onAccent,
                  icon: const Icon(Icons.add),
                  label: const Text('追加'),
                ),
              ),
          ],
          ),
        );
      },
    );
  }
}
