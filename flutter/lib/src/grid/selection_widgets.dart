import 'package:flutter/material.dart';

import '../ui/theme.dart';
import 'photos_chrome.dart';
import 'sort_mode.dart';

// 画面をまたいで同じ操作は同じアイコン・同じ文言にそろえる（KMP 版 SelectionBar.kt）
SelAction addToAlbumAction(VoidCallback? onTap) =>
    SelAction('アルバムへ', Icons.add_to_photos_outlined, onTap: onTap);
SelAction offlineAction(VoidCallback? onTap) =>
    SelAction('オフライン', Icons.download_outlined, onTap: onTap);
SelAction trashAction(VoidCallback? onTap) =>
    SelAction('ゴミ箱へ', Icons.delete_outline, danger: true, onTap: onTap);

/// 選択中に下のタブと入れ替える操作バー。各操作は等幅の縦並び（アイコン＋文字）。
/// 文字を大きくすると高さだけ伸び、幅が足りない文字は2行まで折り返す（消さない）。
class SelectionOpsBar extends StatelessWidget {
  final List<SelAction> actions;
  const SelectionOpsBar({super.key, required this.actions});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surfaceHigh,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        // 押せる範囲が下端のジェスチャー領域へ食い込むと「押しても反応しない」に見えるので浮かせる
        child: SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 80),
            child: Row(
              children: [
                for (final a in actions) Expanded(child: _OpButton(action: a)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OpButton extends StatelessWidget {
  final SelAction action;
  const _OpButton({required this.action});

  @override
  Widget build(BuildContext context) {
    final enabled = action.onTap != null;
    final color = !enabled
        ? AppColors.textPrimary.withValues(alpha: 0.38)
        : action.danger
        ? AppColors.danger
        : AppColors.textPrimary;
    return Semantics(
      button: true,
      enabled: enabled,
      child: InkWell(
        onTap: action.onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 80),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
            // 下のタブの枠は高さが緩いので、縦に伸びきって画面を覆わんよう中身の高さに留める
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(action.icon, color: color),
                const SizedBox(height: 4),
                Text(
                  action.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: color, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 選択中のアプリバー: 閉じる・「N件を選択」・すべて選択/すべて解除。
/// 選択中はライブラリ切替を出さない（切り替えると選択が解けるので押させない）。
AppBar selectionAppBar(SelectionSurface s) => AppBar(
  leading: IconButton(
    tooltip: '選択を解除',
    icon: const Icon(Icons.close),
    onPressed: s.clearSelection,
  ),
  title: Text('${s.selectedCount}件を選択'),
  actions: [
    TextButton(
      onPressed: s.toggleAll,
      child: Text(s.allSelected ? 'すべて解除' : 'すべて選択'),
    ),
  ],
);

/// 並び替えメニュー。今の並びにチェックを付ける。
class SortMenuButton extends StatelessWidget {
  final SortMode current;
  final ValueChanged<SortMode> onPick;
  const SortMenuButton({
    super.key,
    required this.current,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<SortMode>(
      tooltip: '並び替え',
      icon: const Icon(Icons.filter_list),
      onSelected: onPick,
      itemBuilder: (_) => [
        for (final m in SortMode.values)
          PopupMenuItem(
            value: m,
            child: Row(
              children: [
                SizedBox(
                  width: 16,
                  child: m == current
                      ? const Icon(Icons.check, size: 16)
                      : null,
                ),
                const SizedBox(width: 8),
                Text(m.label),
              ],
            ),
          ),
      ],
    );
  }
}

/// 選択の丸。選択中はチェック入りの塗り、未選択は白い縁の丸。
class SelectCheck extends StatelessWidget {
  final bool selected;
  const SelectCheck({super.key, required this.selected});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected
            ? AppColors.accent
            : Colors.black.withValues(alpha: 0.25),
        border: selected ? null : Border.all(color: Colors.white, width: 2),
      ),
      child: selected
          ? const Icon(
              Icons.check,
              size: 16,
              color: Color(0xFF1A1408),
              semanticLabel: '選択中',
            )
          : null,
    );
  }
}
