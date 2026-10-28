import 'package:flutter/material.dart';

import '../api/models.dart';
import '../grid/day_label.dart';
import '../viewer/viewer_format.dart';
import 'theme.dart';

/// ゴミ箱の見た目だけの部品。TrashItem にはサムネの URL が無いので、種類アイコンで出す。

const _videoExtensions = {'mp4', 'mov', 'm4v', 'webm', 'mkv', 'ts', 'm2ts', 'avi'};

bool isVideoKey(String key) {
  final dot = key.lastIndexOf('.');
  if (dot < 0 || dot < key.lastIndexOf('/')) return false;
  return _videoExtensions.contains(key.substring(dot + 1).toLowerCase());
}

/// 「10月9日にゴミ箱へ · 3.1 MB」
String trashRowMeta(TrashItem t, DateTime now) =>
    '${formatShortDate(t.deletedAt, now)}にゴミ箱へ · ${formatBytes(t.size)}';

/// 一覧の先頭に出す保持期間の説明。
String trashRetentionNotice(int days, {required bool canRestore}) {
  final tail = canRestore
      ? 'それまではいつでも元の場所に戻せます。'
      : 'このライブラリは読み取り専用なので、戻すことはできません。';
  return 'ゴミ箱の項目は、移してから$days日たつと自動で完全に削除されます。$tail';
}

class TrashInfoBanner extends StatelessWidget {
  final String text;
  const TrashInfoBanner(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: AppColors.surface, borderRadius: BorderRadius.circular(12)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.info_outline, size: 20, color: AppColors.textDim),
          const SizedBox(width: 12),
          Expanded(
              child: Text(text,
                  style: const TextStyle(
                      color: AppColors.textDim, fontSize: 12, height: 1.5))),
        ]),
      );
}

/// 一覧が出ている状態で読み直しだけ失敗した時の帯。古い一覧を黙って見せないため
class TrashErrorBanner extends StatelessWidget {
  final String text;
  final VoidCallback onRetry;
  const TrashErrorBanner(this.text, {super.key, required this.onRetry});

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        decoration: BoxDecoration(
            color: AppColors.danger.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(12)),
        child: Row(children: [
          const Icon(Icons.error_outline, size: 20, color: AppColors.danger),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
          TextButton(onPressed: onRetry, child: const Text('再試行')),
        ]),
      );
}

/// 空・失敗・読み取り専用の全面表示。引っ張って更新できるよう、呼び出し側でスクロール可能な中に置く
class TrashStateView extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final Color iconColor;
  final Widget? action;
  const TrashStateView({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.iconColor = AppColors.textDim,
    this.action,
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 80),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 56, color: iconColor),
          const SizedBox(height: 16),
          Text(title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(body,
              style: const TextStyle(color: AppColors.textDim, height: 1.5),
              textAlign: TextAlign.center),
          if (action != null) ...[const SizedBox(height: 16), action!],
        ]),
      );
}

class TrashRow extends StatelessWidget {
  final TrashItem item;
  final DateTime now;
  final bool selected;
  final bool busy;
  final bool canRestore;
  final VoidCallback? onTap;
  final VoidCallback onRestore;
  const TrashRow({
    super.key,
    required this.item,
    required this.now,
    required this.selected,
    required this.busy,
    required this.canRestore,
    required this.onRestore,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final video = isVideoKey(item.key);
    return Material(
      color: selected ? AppColors.accentSoft : AppColors.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 72),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
            child: Row(children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                    color: AppColors.surfaceHigh,
                    borderRadius: BorderRadius.circular(8)),
                child: Icon(
                  selected
                      ? Icons.check_circle
                      : video
                          ? Icons.videocam_outlined
                          : Icons.image_outlined,
                  color: selected ? AppColors.accent : AppColors.textDim,
                  semanticLabel: selected ? '選択中' : (video ? '動画' : '画像'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(item.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 2),
                      Text(trashRowMeta(item, now),
                          style: const TextStyle(
                              color: AppColors.textDim, fontSize: 12)),
                    ]),
              ),
              if (canRestore)
                OutlinedButton(
                  onPressed: busy ? null : onRestore,
                  style:
                      OutlinedButton.styleFrom(minimumSize: const Size(64, 44)),
                  // 同じ「復元」が並ぶので、読み上げではどのファイルかを含める
                  child: Text(busy ? '復元中…' : '復元',
                      semanticsLabel: '${item.name}を復元'),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}
