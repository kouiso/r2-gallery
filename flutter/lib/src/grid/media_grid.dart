import 'package:flutter/material.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../ui/media_tile.dart';
import '../ui/theme.dart';
import 'day_label.dart';
import 'selection_widgets.dart';

/// 1セルの最小幅と隙間。端まで広げて、スマホの幅で4列になる密なグリッド（KMP 版 Adaptive(88dp)・2dp）。
const gridMinCell = 88.0;
const gridGap = 2.0;

/// 最後のセルから何件手前で続きを取りに行くか（KMP 版と同じ9件）。
const nearEndThreshold = 9;

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

/// 写真・フォルダで共通のグリッド本体。日付見出し・日ごと選択・末尾のフォルダカード・続きの自動取得を持つ。
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
  // 同じ件数のまま何度も続きを頼まんよう、頼んだ時の件数を覚えておく。
  // 取得に失敗しても毎フレーム投げ直すループにならない
  int _askedAt = -1;

  void _maybeNearEnd(int index) {
    final n = widget.items.length;
    if (n == 0 || index < n - nearEndThreshold || _askedAt == n) return;
    _askedAt = n;
    // セルを組み立てている最中に一覧の状態を変えると build 中の通知になるので、描画後に頼む
    WidgetsBinding.instance.addPostFrameCallback((_) {
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
    return Stack(children: [
      Positioned.fill(child: tile),
      const Positioned(left: 6, top: 6, child: OfflineBadge()),
    ]);
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
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
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

  Widget _folderCard(String prefix) {
    final name = prefix.endsWith('/')
        ? prefix.substring(0, prefix.length - 1).split('/').last
        : prefix.split('/').last;
    return Material(
      color: AppColors.surfaceHigh,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => widget.onOpenFolder?.call(prefix),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.folder, color: AppColors.accent),
              const SizedBox(height: 6),
              Text(
                name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12),
              ),
            ],
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
        if (widget.dateHeaders) {
          var offset = 0;
          for (final day in groupByDay(items, now)) {
            final start = offset;
            slivers.add(
              SliverToBoxAdapter(child: _header(day.label, day.items)),
            );
            slivers.add(
              _gridOf(
                columns,
                day.items.length,
                (i) => _tile(day.items[i], start + i),
              ),
            );
            offset += day.items.length;
          }
        } else {
          slivers.add(
            _gridOf(columns, items.length, (i) => _tile(items[i], i)),
          );
        }
        if (widget.folders.isNotEmpty) {
          slivers.add(
            const SliverToBoxAdapter(child: SizedBox(height: gridGap)),
          );
          slivers.add(
            _gridOf(
              columns,
              widget.folders.length,
              (i) => _folderCard(widget.folders[i]),
            ),
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
