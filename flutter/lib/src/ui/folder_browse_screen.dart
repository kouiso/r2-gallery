import 'dart:async';

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../grid/media_controller.dart';
import '../grid/media_list_body.dart';
import '../grid/selection_widgets.dart';
import '../grid/sort_mode.dart';
import '../grid/state_views.dart';
import 'open_failed_notice.dart';
import '../state/app_state.dart';
import 'viewer_screen.dart';

/// フォルダを開く。サブフォルダはグリッド末尾のカードからさらに辿れる。
/// アルバムタブのフォルダ一覧（A9）からもここを呼ぶ。
Future<void> openFolder(
  BuildContext context,
  AppState app,
  String lib,
  String prefix,
) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => FolderBrowseScreen(app: app, lib: lib, prefix: prefix),
    ),
  );
}

/// フォルダの中身（直下のファイル + サブフォルダのカード）。
/// 選択・アルバムへ・ゴミ箱＋元に戻す・長押しメニューは写真タブと同じものを使う。
class FolderBrowseScreen extends StatefulWidget {
  final AppState app;
  final String lib;
  final String prefix;
  /// シェルのアルバムタブに子画面として載せる時の戻る。null なら画面を積んだ時の戻る（見出しは自動）
  final VoidCallback? onBack;
  /// サブフォルダを開く。null なら画面を積んで開く
  final ValueChanged<String>? onOpenFolder;
  /// 選択に入った・抜けた時。シェルは選択中だけ下タブを隠す
  final ValueChanged<bool>? onSelectingChanged;
  /// 見えている画面か。裏に残っている間に別のタブで増減した分を映すため、見えるように戻った時に読み直す
  final bool active;
  const FolderBrowseScreen({
    super.key,
    required this.app,
    required this.lib,
    required this.prefix,
    this.onBack,
    this.onOpenFolder,
    this.onSelectingChanged,
    this.active = true,
  });

  @override
  State<FolderBrowseScreen> createState() => _FolderBrowseScreenState();
}

class _FolderBrowseScreenState extends State<FolderBrowseScreen> {
  late final GalleryState _g = GalleryState(
    widget.app.api,
    prefix: widget.prefix,
    recursive: false,
    sort: widget.app.photosChrome.sort,
    cache: widget.app.listingCache,
  )..refresh(widget.lib);
  late final MediaController _c = MediaController(widget.app)
    ..bind(_g, widget.lib);
  // フォルダの中は写真タブと同じ並びで開く。ここで変えても写真タブには持ち越さない
  late SortMode _sort = widget.app.photosChrome.sort;
  bool _selecting = false;
  StreamSubscription<void>? _resumeSub;

  @override
  void initState() {
    super.initState();
    _c.addListener(_reportSelecting);
    // 裏へ回っている間にURLの寿命が切れた分を、復帰時に差し替える（#24 作業B）
    _resumeSub =
        widget.app.resumed.listen((_) => _g.refreshIfExpired(widget.lib));
  }

  @override
  void didUpdateWidget(FolderBrowseScreen old) {
    super.didUpdateWidget(old);
    // 読み進めた位置と続きのページは残し、差分だけ映す
    if (widget.active && !old.active) _g.softRefresh(widget.lib);
  }

  void _reportSelecting() {
    final now = _c.selectedCount > 0;
    if (now == _selecting) return;
    _selecting = now;
    widget.onSelectingChanged?.call(now);
  }

  @override
  void dispose() {
    _resumeSub?.cancel();
    _c.removeListener(_reportSelecting);
    _c.dispose();
    _g.dispose();
    super.dispose();
  }

  Future<void> _open(List<MediaItem> sorted, int index) async {
    // 控えの一覧から開く時は、期限の切れた署名URLを新しいものに替えてから開く
    final target = await _g.openTarget(sorted, index, lib: widget.lib);
    if (!mounted) return;
    // 引き直しの間にロックされたら開かない（ロック層は下の画面を残すので mounted では防げない）
    if (widget.app.locked) return;
    if (target == null) {
      // 消えていた時も引き直しの失敗も null なので、どちらにも当てはまる文言で知らせる
      showOpenFailedNotice(context);
      return;
    }
    await openViewer(context,
        app: widget.app,
        lib: widget.lib,
        items: target.items,
        index: target.index,
        onChanged: () => _g.softRefresh(widget.lib),
        onTrash: (it) => _c.trashOne(context, it));
  }

  String get _title {
    final p = widget.prefix.endsWith('/')
        ? widget.prefix.substring(0, widget.prefix.length - 1)
        : widget.prefix;
    return p.isEmpty ? 'フォルダ' : p.split('/').last;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        final sorted = _g.ordered();
        final selecting = _c.selectedCount > 0;
        return PopScope(
          // 選択中の戻るは選択を解くだけにする（画面ごと閉じて選択を失わせない）
          canPop: !selecting,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _c.clearSelection();
          },
          child: Scaffold(
            appBar: selecting
                ? selectionAppBar(_c)
                : AppBar(
                    leading: widget.onBack == null
                        ? null
                        : BackButton(onPressed: widget.onBack),
                    title: Text(_title),
                    actions: [
                      SortMenuButton(
                        current: _sort,
                        onPick: (m) {
                          setState(() => _sort = m);
                          _g.changeSort(m, widget.lib);
                        },
                      ),
                    ],
                  ),
            body: MediaListBody(
              c: _c,
              // 並び順を替えたら、別の一覧として作り直して先頭から見せる
              gridKey: ValueKey('folder-${_g.sort.apiValue}'),
              sort: _sort,
              sorted: sorted,
              onOpenItem: (i) => _open(sorted, i),
              onOpenFolder: widget.onOpenFolder ??
                  (p) => openFolder(context, widget.app, widget.lib, p),
              errorActions: [
                StatePrimaryButton('再試行', () => _g.refresh(widget.lib)),
              ],
              empty: const StateView(
                icon: Icons.folder_outlined,
                title: 'このフォルダは空です',
              ),
            ),
            bottomNavigationBar: selecting
                ? SelectionOpsBar(actions: _c.selectionActions(context))
                : null,
          ),
        );
      },
    );
  }
}
