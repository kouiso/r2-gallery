import 'package:flutter/material.dart';

import '../api/models.dart';
import '../ui/theme.dart';
import 'media_controller.dart';
import 'media_grid.dart';
import 'sort_mode.dart';
import 'state_views.dart';

/// 一覧の中身（読み込み中・エラー・空・更新失敗の帯・グリッド）。写真タブとフォルダ画面で共通。
class MediaListBody extends StatelessWidget {
  final MediaController c;
  final SortMode sort;
  final List<MediaItem> sorted;
  final ValueChanged<int> onOpenItem;
  final Widget empty;
  final List<Widget> errorActions;
  final ValueChanged<String>? onOpenFolder;
  final Key? gridKey;

  const MediaListBody({
    super.key,
    required this.c,
    required this.sort,
    required this.sorted,
    required this.onOpenItem,
    required this.empty,
    required this.errorActions,
    this.onOpenFolder,
    this.gridKey,
  });

  @override
  Widget build(BuildContext context) {
    final g = c.g;
    final folders = onOpenFolder == null ? const <String>[] : g.folders;
    final nothing = sorted.isEmpty && folders.isEmpty;
    if (g.loading && nothing) {
      return const Center(child: CircularProgressIndicator());
    }
    final err = g.error;
    if (err != null && nothing) {
      return StateView(
        icon: Icons.cloud_off_outlined,
        iconColor: AppColors.danger,
        title: '読み込めませんでした',
        body: '$err\n通信状態を確認して、もう一度お試しください。',
        actions: errorActions,
      );
    }
    if (nothing) return empty;
    return Column(
      children: [
        if (err != null)
          ErrorBanner(message: err, onRetry: () => g.refresh(c.lib)),
        Expanded(
          child: MediaGrid(
            key: gridKey,
            items: sorted,
            dateHeaders: sort.isDate,
            selection: g.selection,
            selectionMode: g.selectionMode,
            selLib: c.lib,
            onOpenItem: onOpenItem,
            onToggleSelect: (it) => g.toggleSelect(it, c.lib),
            onLongPress: (it) => c.onLongPress(context, it),
            onToggleDay: (day) => g.toggleDay(day, c.lib),
            onNearEnd: () => g.loadMore(c.lib),
            onRefresh: () => g.refresh(c.lib),
            loadingMore: g.loadingMore,
            folders: folders,
            onOpenFolder: onOpenFolder,
            isOffline: (it) => c.app.isOffline(it.lib ?? c.lib, it.key),
          ),
        ),
      ],
    );
  }
}
