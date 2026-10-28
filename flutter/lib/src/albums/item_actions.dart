import 'package:flutter/material.dart';

import '../api/models.dart';
import '../ui/theme.dart';

/// 長押しメニューで選べる操作。
enum ItemAction { movePrev, moveNext, removeFromAlbum, addToAlbum, trash }

/// 1件の長押しメニュー（KMP 版 ItemActionDialog と同じ並び・文言）。
/// [inAlbum] の時だけ並び替えと「外す」を出す。読み取り専用では書き換える操作を一切出さない。
Future<ItemAction?> showItemActions(
  BuildContext context, {
  required MediaItem item,
  required bool readOnly,
  bool inAlbum = false,
}) {
  Widget entry(BuildContext ctx, String label, ItemAction a,
          {bool danger = false}) =>
      SizedBox(
        width: double.infinity,
        child: TextButton(
          onPressed: () => Navigator.of(ctx).pop(a),
          child: Text(label,
              style: danger ? const TextStyle(color: AppColors.danger) : null),
        ),
      );

  return showDialog<ItemAction>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        if (readOnly)
          const Text('このライブラリは読み取り専用です',
              style: TextStyle(color: AppColors.textDim)),
        if (!readOnly && inAlbum) ...[
          entry(ctx, '前に移す', ItemAction.movePrev),
          entry(ctx, '後ろに移す', ItemAction.moveNext),
          entry(ctx, 'このアルバムから外す', ItemAction.removeFromAlbum),
        ],
        if (!readOnly) ...[
          entry(ctx, 'アルバムに追加', ItemAction.addToAlbum),
          entry(ctx, 'ゴミ箱へ', ItemAction.trash, danger: true),
        ],
      ]),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(ctx).pop(), child: const Text('閉じる')),
      ],
    ),
  );
}
