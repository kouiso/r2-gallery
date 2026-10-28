import 'dart:async';

import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../ui/import_parts.dart';
import '../ui/theme.dart';
import 'transfer_queue.dart';
import 'transfer_rows.dart';

/// 下タブ（[child]）の上に転送バーを重ねる。
class TransfersDock extends StatelessWidget {
  final AppState app;
  final Widget child;
  const TransfersDock({super.key, required this.app, required this.child});

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [TransfersStrip(app: app), child],
      );
}

/// 下タブの上に置く転送バー（KMP 版 TransfersDock）。タップで転送シートを開く。
/// 動いている転送も失敗も無ければ何も出さない。
class TransfersStrip extends StatefulWidget {
  final AppState app;
  const TransfersStrip({super.key, required this.app});

  /// 完了・取り消しの行を一覧から消すまでの時間（KMP 版と同じ4秒）。
  static const finishedRowLife = Duration(seconds: 4);

  @override
  State<TransfersStrip> createState() => _TransfersStripState();
}

class _TransfersStripState extends State<TransfersStrip> {
  final Map<String, Timer> _expiry = {};

  @override
  void dispose() {
    for (final t in _expiry.values) {
      t.cancel();
    }
    super.dispose();
  }

  // 完了行を残すと、動いている転送が無くなった時に転送バー（シートへの唯一の入口）も消えて、
  // 開けない完了行だけが溜まる。数秒で片付ける
  void _scheduleExpiry(List<TransferRow> rows) {
    final finished = {
      for (final r in rows)
        if (r.status == TransferStatus.done ||
            r.status == TransferStatus.cancelled)
          r.id: r,
    };
    _expiry.removeWhere((id, t) {
      if (finished.containsKey(id)) return false;
      t.cancel();
      return true;
    });
    for (final r in finished.values) {
      final dismiss = r.onDismiss;
      if (dismiss == null) continue;
      _expiry.putIfAbsent(
          r.id,
          () => Timer(TransfersStrip.finishedRowLife, () {
                _expiry.remove(r.id);
                dismiss();
              }));
    }
  }

  void _open() {
    final app = widget.app;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surfaceHigh,
      builder: (ctx) => AnimatedBuilder(
        animation: app.transfers,
        builder: (ctx, _) => TransfersSheetContent(
          queue: app.webQueue,
          transfers: app.transfers,
          online: app.transfers.online,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return AnimatedBuilder(
      animation: Listenable.merge([app.webQueue, app.transfers]),
      builder: (context, _) {
        final online = app.transfers.online;
        final rows = transferRows(app.webQueue, app.transfers, online: online);
        _scheduleExpiry(rows);
        final summary = summarizeTransfers(rows, online: online);
        if (summary == null) return const SizedBox.shrink();
        final attention = summary.active == 0 && summary.failed > 0;
        return Semantics(
          button: true,
          onTapHint: '転送の詳細を開く',
          child: Material(
            color: AppColors.surface,
            child: InkWell(
              onTap: _open,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(
                    value: attention ? 0 : summary.percent / 100,
                    minHeight: 2,
                    backgroundColor: AppColors.border,
                  ),
                  ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 56),
                    child: Padding(
                      padding: const EdgeInsets.only(left: 16, right: 4),
                      child: Row(
                        children: [
                          Icon(
                            summary.upload
                                ? Icons.cloud_upload_outlined
                                : Icons.download,
                            color: attention
                                ? AppColors.danger
                                : AppColors.accent,
                          ),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(12, 6, 0, 6),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(summary.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600)),
                                  Text(summary.detail,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: summary.failed > 0
                                              ? AppColors.danger
                                              : AppColors.textDim)),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(
                            width: 48,
                            height: 48,
                            child: Icon(Icons.keyboard_arrow_up),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
