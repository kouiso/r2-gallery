import 'package:flutter/material.dart';

import '../api/models.dart';
import '../ui/media_tile.dart';
import '../ui/theme.dart';
import 'album_states.dart';
import '../grid/day_label.dart';
import 'media_selection.dart';

/// 選択中の操作バーの1操作。アイコンの下に必ず文字を付ける（KMP 版 SelAction と同じ）。
class SelAction {
  final String label;
  final IconData icon;
  final bool danger;
  final bool enabled;
  final VoidCallback onTap;
  const SelAction(this.label, this.icon, this.onTap,
      {this.danger = false, this.enabled = true});
}

/// 画面下の操作バー。各操作は等幅の縦並び。
class SelectionActionsBar extends StatelessWidget {
  final List<SelAction> actions;
  const SelectionActionsBar({super.key, required this.actions});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surfaceHigh,
      // 押せる範囲が下端のジェスチャー領域に食い込むと「押しても反応しない」に見えるので浮かせる
      child: SafeArea(
        top: false,
        child: Container(
          decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: AppColors.border))),
          constraints: const BoxConstraints(minHeight: 72),
          child: Row(children: [
            for (final a in actions)
              Expanded(
                child: InkWell(
                  onTap: a.enabled ? a.onTap : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
                    child: Builder(builder: (context) {
                      final color = !a.enabled
                          ? AppColors.textDim.withValues(alpha: 0.5)
                          : a.danger
                              ? AppColors.danger
                              : AppColors.textPrimary;
                      return Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(a.icon, color: color),
                        const SizedBox(height: 4),
                        Text(a.label,
                            maxLines: 2,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: color, fontSize: 12)),
                      ]);
                    }),
                  ),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

/// アルバム・フォルダの中身グリッド。日付見出しと日ごとの丸選択、末尾のフォルダカードを持てる。
class AlbumMediaGrid extends StatelessWidget {
  final List<MediaItem> items;
  final String lib;
  final MediaSelection selection;
  final bool dateHeaders;
  final List<String> folders;
  final void Function(String prefix)? onOpenFolder;
  final void Function(MediaItem) onOpen;
  final void Function(MediaItem) onToggle;
  final void Function(MediaItem) onLongPress;
  final void Function(List<MediaItem>)? onToggleDay;
  final VoidCallback onNearEnd;
  final bool loadingMore;
  final Future<void> Function() onRefresh;

  /// 「今日／昨日」の基準。テストで日付を固定するため差し替えられる
  final DateTime? now;

  const AlbumMediaGrid({
    super.key,
    required this.items,
    required this.lib,
    required this.selection,
    required this.onOpen,
    required this.onToggle,
    required this.onLongPress,
    required this.onNearEnd,
    required this.onRefresh,
    this.dateHeaders = false,
    this.folders = const [],
    this.onOpenFolder,
    this.onToggleDay,
    this.loadingMore = false,
    this.now,
  });

  static const _gridDelegate = SliverGridDelegateWithMaxCrossAxisExtent(
    maxCrossAxisExtent: 160,
    mainAxisSpacing: 4,
    crossAxisSpacing: 4,
  );

  Widget _tile(MediaItem it, int index) {
    // KMP 版と同じく、末尾9件手前まで来たら続きを読む（見出しの有無に関わらず）
    if (index >= items.length - 9) {
      WidgetsBinding.instance.addPostFrameCallback((_) => onNearEnd());
    }
    final selecting = selection.isNotEmpty;
    return MediaTile(
      key: ValueKey('album-media-${it.lib ?? lib}:${it.key}'),
      item: it,
      selected: selection.contains(it, lib),
      selectionMode: selecting,
      onTap: () => selecting ? onToggle(it) : onOpen(it),
      onLongPress: () => onLongPress(it),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selecting = selection.isNotEmpty;
    final slivers = <Widget>[];
    if (!dateHeaders) {
      slivers.add(SliverGrid(
        gridDelegate: _gridDelegate,
        delegate: SliverChildBuilderDelegate((c, i) => _tile(items[i], i),
            childCount: items.length),
      ));
    } else {
      final base = now ?? DateTime.now();
      // 並び順を崩さず、続いている同じ日をひとまとめにする
      final groups = <({String label, List<int> idx})>[];
      for (var i = 0; i < items.length; i++) {
        final label = formatDayHeader(items[i].createdAt, base);
        if (groups.isEmpty || groups.last.label != label) {
          groups.add((label: label, idx: [i]));
        } else {
          groups.last.idx.add(i);
        }
      }
      for (final g in groups) {
        final dayItems = [for (final i in g.idx) items[i]];
        final allSel = selection.allSelected(dayItems, lib);
        slivers.add(SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
            child: Row(children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(g.label,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
              if (selecting && onToggleDay != null)
                IconButton(
                  tooltip: 'この日をまとめて選択',
                  onPressed: () => onToggleDay!(dayItems),
                  icon: Icon(
                    allSel ? Icons.check_circle : Icons.radio_button_unchecked,
                    color: allSel ? AppColors.accent : AppColors.textDim,
                  ),
                ),
            ]),
          ),
        ));
        slivers.add(SliverGrid(
          gridDelegate: _gridDelegate,
          delegate: SliverChildBuilderDelegate(
              (c, j) => _tile(items[g.idx[j]], g.idx[j]),
              childCount: g.idx.length),
        ));
      }
    }
    if (folders.isNotEmpty) {
      slivers.add(SliverPadding(
        padding: const EdgeInsets.only(top: 4),
        sliver: SliverGrid(
          gridDelegate: _gridDelegate,
          delegate: SliverChildBuilderDelegate(
            (c, i) => FolderCard(
                name: folderName(folders[i]),
                onTap: () => onOpenFolder?.call(folders[i])),
            childCount: folders.length,
          ),
        ),
      ));
    }
    if (loadingMore) {
      slivers.add(const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      ));
    }
    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 96)));
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: slivers,
      ),
    );
  }
}

/// フォルダのカード（アルバムタブのフォルダ一覧とフォルダ閲覧の末尾で共用）。
class FolderCard extends StatelessWidget {
  final String name;
  final VoidCallback onTap;
  const FolderCard({super.key, required this.name, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surfaceHigh,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.folder, color: AppColors.accent),
            const SizedBox(height: 6),
            Text(name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12)),
          ]),
        ),
      ),
    );
  }
}

/// アルバム名・フォルダ名の入力。空なら確定できない。
Future<String?> showNameDialog(
  BuildContext context, {
  required String title,
  String placeholder = '新しいアルバム名',
  String initial = '',
  String confirmLabel = '作成',
}) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => _NameDialog(
        title: title,
        placeholder: placeholder,
        initial: initial,
        confirmLabel: confirmLabel),
  );
}

class _NameDialog extends StatefulWidget {
  final String title;
  final String placeholder;
  final String initial;
  final String confirmLabel;
  const _NameDialog(
      {required this.title,
      required this.placeholder,
      required this.initial,
      required this.confirmLabel});

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _c =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _c.text.trim();
    if (name.isNotEmpty) Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _c,
        autofocus: true,
        decoration: InputDecoration(hintText: widget.placeholder),
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('キャンセル')),
        TextButton(
          onPressed: _c.text.trim().isEmpty ? null : _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// 失敗を伝えて閉じるだけのダイアログ。
Future<void> showMessageDialog(BuildContext context, String title,
    [String? body]) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: body == null ? null : Text(body),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(ctx).pop(), child: const Text('OK')),
      ],
    ),
  );
}
