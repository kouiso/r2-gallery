import 'package:flutter/material.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../ui/media_tile.dart';
import '../ui/theme.dart';
import 'day_label.dart';
import 'day_rows.dart';
import 'selection_widgets.dart';

/// 1セルの最小幅と隙間。端まで広げて、スマホの幅で4列になる密なグリッド（KMP 版 Adaptive(88dp)・2dp）。
const gridMinCell = 88.0;
const gridGap = 2.0;

/// 最後のセルから何件手前で続きを取りに行くか。9件手前（KMP 版）だと末尾に着いてから
/// 読み込みを待つことになるので、1ページ（200件）の半分強、画面2〜3枚分先から頼む。
const nearEndThreshold = 120;

/// 幅から列数を出す。Compose の GridCells.Adaptive と同じ割り方。
int gridColumnsFor(double width) {
  final n = ((width + gridGap) / (gridMinCell + gridGap)).floor();
  return n < 1 ? 1 : n;
}

/// 並べた一覧を日付ごとに区切る。並びは崩さず、見出しが変わる所で切る。
List<({String label, List<MediaItem> items})> groupByDay(
  List<MediaItem> items,
  DateTime now,
) {
  final out = <({String label, List<MediaItem> items})>[];
  for (final it in items) {
    final label = formatDayHeader(it.createdAt, now);
    if (out.isEmpty || out.last.label != label) {
      out.add((label: label, items: <MediaItem>[]));
    }
    out.last.items.add(it);
  }
  return out;
}

/// 写真・フォルダで共通のグリッド本体。日付見出し・日ごと選択・先頭のフォルダ段・続きの自動取得を持つ。
class MediaGrid extends StatefulWidget {
  final List<MediaItem> items;
  final bool dateHeaders;
  final Set<SelKey> selection;
  final bool selectionMode;
  final String selLib;
  final ValueChanged<int> onOpenItem;
  final ValueChanged<MediaItem> onToggleSelect;
  final ValueChanged<MediaItem> onLongPress;
  final ValueChanged<List<MediaItem>>? onToggleDay;
  final VoidCallback onNearEnd;
  final Future<void> Function() onRefresh;
  final bool loadingMore;
  final List<String> folders;
  final ValueChanged<String>? onOpenFolder;

  /// オフライン保存済みか（#149）。保存済みのタイルに印を付ける。
  final bool Function(MediaItem item)? isOffline;

  const MediaGrid({
    super.key,
    required this.items,
    required this.dateHeaders,
    required this.selection,
    required this.selectionMode,
    required this.selLib,
    required this.onOpenItem,
    required this.onToggleSelect,
    required this.onLongPress,
    required this.onNearEnd,
    required this.onRefresh,
    this.onToggleDay,
    this.loadingMore = false,
    this.folders = const [],
    this.onOpenFolder,
    this.isOffline,
  });

  @override
  State<MediaGrid> createState() => _MediaGridState();
}

class _MediaGridState extends State<MediaGrid> {
  // 日付の区切りと行はページが届くたびに全件をなめ直さず、足された分だけ作り直す（#25 作業2）
  final DayRows _dayRows = DayRows();
  // 続きを頼むかは一覧の状態が決める。ここは組み立て中の通知を避けて、
  // 描画後に1フレーム1回だけ送る
  bool _askQueued = false;

  // フォルダ段の横送り用。Web/マウスでは既定のドラッグが効かんので、バーを出して掴めるようにする
  final ScrollController _folderStripCtl = ScrollController();

  @override
  void dispose() {
    _folderStripCtl.dispose();
    super.dispose();
  }

  void _maybeNearEnd(int index) {
    final n = widget.items.length;
    if (n == 0 || index < n - nearEndThreshold || _askQueued) return;
    _askQueued = true;
    // セルを組み立てている最中に一覧の状態を変えると build 中の通知になるので、描画後に頼む
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _askQueued = false;
      if (mounted) widget.onNearEnd();
    });
  }

  Widget _tile(MediaItem item, int index) {
    _maybeNearEnd(index);
    final sel = widget.selection.contains(
      SelKey(item.lib ?? widget.selLib, item.key),
    );
    final tile = MediaTile(
      key: ValueKey('t:${item.lib ?? ''}:${item.key}'),
      item: item,
      selected: sel,
      selectionMode: widget.selectionMode,
      onTap: () => widget.selectionMode
          ? widget.onToggleSelect(item)
          : widget.onOpenItem(index),
      onLongPress: () => widget.onLongPress(item),
    );
    if (!(widget.isOffline?.call(item) ?? false)) return tile;
    return Stack(
      children: [
        Positioned.fill(child: tile),
        const Positioned(left: 6, top: 6, child: OfflineBadge()),
      ],
    );
  }

  SliverGrid _gridOf(int columns, int count, Widget Function(int) build) =>
      SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          mainAxisSpacing: gridGap,
          crossAxisSpacing: gridGap,
        ),
        delegate: SliverChildBuilderDelegate(
          (_, i) => build(i),
          childCount: count,
        ),
      );

  Widget _header(String label, List<MediaItem> day) {
    final daySel = widget.selectionMode && widget.onToggleDay != null;
    final allSel =
        daySel &&
        day.every(
          (it) => widget.selection.contains(
            SelKey(it.lib ?? widget.selLib, it.key),
          ),
        );
    return Padding(
      padding: const EdgeInsets.only(top: 8, left: 16, right: 4),
      child: Row(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                label,
                style: AppText.label,
              ),
            ),
          ),
          if (daySel)
            // 見た目は24、押せる範囲は48
            Semantics(
              key: ValueKey('day:$label'),
              button: true,
              label: 'この日をまとめて選択',
              child: InkResponse(
                onTap: () => widget.onToggleDay!(day),
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: Center(child: SelectCheck(selected: allSel)),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 見出し（フォルダ N）と、横に送れるカードの1段。数が多くても縦の高さは変わらず、写真が押し出されない。
  Widget _folderStrip() {
    return Column(
      key: const ValueKey('folderStrip'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // デザイン（ReviewFolder.dc.html）の見出し行は上下 8 の余白に 48 高の行で、数だけ淡色・細字にして名前と区別する
        Container(
          height: 64,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text.rich(
              TextSpan(
                text: 'フォルダ ',
                children: [
                  TextSpan(
                    text: '${widget.folders.length}',
                    style: const TextStyle(
                      color: AppColors.textDim,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
              style: AppText.label,
            ),
          ),
        ),
        SizedBox(
          height: 88,
          child: Scrollbar(
            controller: _folderStripCtl,
            thumbVisibility: true,
            child: ListView.separated(
              controller: _folderStripCtl,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: widget.folders.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (_, i) => _folderCard(widget.folders[i]),
            ),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _folderCard(String prefix) {
    final name = prefix.endsWith('/')
        ? prefix.substring(0, prefix.length - 1).split('/').last
        : prefix.split('/').last;
    return SizedBox(
      width: 112,
      height: 88,
      child: Material(
        color: AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(AppRadius.medium),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => widget.onOpenFolder?.call(prefix),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // デザインは線のフォルダアイコン
                const Icon(Icons.folder_outlined, color: AppColors.accent),
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    // 「今日／昨日」の基準。一覧を作り直す時だけ取り直せば足りる
    final now = DateTime.now();
    return LayoutBuilder(
      builder: (context, c) {
        final columns = gridColumnsFor(c.maxWidth);
        final slivers = <Widget>[];
        // 下位フォルダは写真の上に1段で出す。写真を最後まで送らないと辿れない問題（#73）の対策。無い時は段ごと出さない
        if (widget.folders.isNotEmpty) {
          slivers.add(SliverToBoxAdapter(child: _folderStrip()));
        }
        if (widget.dateHeaders) {
          // 日付の区切りと行は DayRows が覚える。届いた分と最後の日だけを作り直す（#25 作業2）
          final rows = _dayRows.update(items, columns: columns, now: now);
          final cell = (c.maxWidth - gridGap * (columns - 1)) / columns;
          // 複数の SliverGrid は画面外でも各日先頭を構築するため、日付も行も一つの遅延リストにする。
          slivers.add(
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (_, i) {
                  final row = rows[i];
                  if (row.label != null) return _header(row.label!, row.day);
                  return Padding(
                    padding: EdgeInsets.only(
                      bottom: row.gapAfter ? gridGap : 0,
                    ),
                    child: Row(
                      children: [
                        for (var j = 0; j < row.count; j++) ...[
                          if (j > 0) const SizedBox(width: gridGap),
                          SizedBox(
                            width: cell,
                            height: cell,
                            child: _tile(items[row.start + j], row.start + j),
                          ),
                        ],
                      ],
                    ),
                  );
                },
                childCount: rows.length,
                addAutomaticKeepAlives: false,
              ),
            ),
          );
        } else {
          slivers.add(
            _gridOf(columns, items.length, (i) => _tile(items[i], i)),
          );
        }
        if (widget.loadingMore) {
          slivers.add(
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            ),
          );
        }
        // 最終行が追加ボタンに隠れない余白
        slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 88)));
        return RefreshIndicator(
          onRefresh: widget.onRefresh,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: slivers,
          ),
        );
      },
    );
  }
}
