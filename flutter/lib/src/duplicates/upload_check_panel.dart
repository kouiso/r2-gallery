import 'package:flutter/material.dart';

import '../ui/media_tile.dart';
import '../ui/theme.dart';
import 'upload_check.dart';

/// 確認シートの中の重複確認の欄。照合の途中でもシートは使えるようにし、結果は届いた時に出す。
class UploadCheckPanel extends StatelessWidget {
  final UploadCheckController controller;
  const UploadCheckPanel({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final o = controller.outcome;
        if (o == null) {
          return Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Row(children: [
              SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 12),
              Text('重複を確認中…',
                  style: AppText.caption.copyWith(color: AppColors.textDim)),
            ]),
          );
        }
        final notes = <Widget>[];
        if (o.status == UploadCheckStatus.failed) {
          notes.add(const _Note('重複の確認ができませんでした'));
        } else if (o.unresolved.isNotEmpty) {
          notes.add(_Note('${o.unresolved.length}件は重複の確認ができませんでした'));
        }
        final flagged = o.flags.keys.toList()..sort();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            ...notes,
            for (final i in flagged)
              _FlagRow(
                controller: controller,
                index: i,
                flag: o.flags[i]!,
              ),
          ],
        );
      },
    );
  }
}

class _Note extends StatelessWidget {
  final String text;
  const _Note(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(text,
            style: AppText.caption.copyWith(color: AppColors.textDim)),
      );
}

class _FlagRow extends StatelessWidget {
  final UploadCheckController controller;
  final int index;
  final UploadDuplicate flag;
  const _FlagRow(
      {required this.controller, required this.index, required this.flag});

  @override
  Widget build(BuildContext context) {
    final source = controller.sources[index];
    final stored = flag.stored;
    final same = flag.sameAs;
    final forced = controller.forced.contains(index);
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.medium),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(source.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          SizedBox(height: 4),
          Text(
            stored != null ? 'ライブラリに同じ物があります' : '選んだ物の中に同じ物があります',
            style: AppText.caption.copyWith(color: AppColors.accent),
          ),
          if (stored != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.small),
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: stored.thumbUrl == null
                        ? const ColoredBox(
                            color: AppColors.surfaceHigh,
                            child: ThumbFallback())
                        : ThumbImage(
                            url: stored.thumbUrl!, stored: stored.thumbStored),
                  ),
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Text(stored.key,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption.copyWith(
                          color: AppColors.textDim)),
                ),
              ]),
            )
          else if (same != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('同じ物: ${controller.sources[same].name}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption.copyWith(
                      color: AppColors.textDim)),
            ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 4, children: [
            ChoiceChip(
              label: const Text('アップロードしない（スキップ）'),
              selected: !forced,
              onSelected: (_) => controller.setForced(index, false),
            ),
            ChoiceChip(
              label: const Text('それでも上げる'),
              selected: forced,
              onSelected: (_) => controller.setForced(index, true),
            ),
          ]),
        ],
      ),
    );
  }
}
