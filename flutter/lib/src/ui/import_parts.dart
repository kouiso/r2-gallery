import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../transfer/transfer_queue.dart';
import '../transfer/transfer_rows.dart';
import '../webdl/detected.dart';
import '../webdl/detected_thumb.dart';
import '../webdl/detection_filter.dart';
import '../webdl/web_history.dart';
import '../webdl/web_transfer.dart';
import 'theme.dart';

/// 取り込みタブの見た目の部品。KMP 版 ImportParts.kt / ImportBrowserScreen.kt に対応する。
/// 検出したメディアは普段たたんだ1行にして、ページの閲覧を邪魔しない。

/// 保存できない理由。保存先ライブラリが書き込めん時だけ出す。
enum SaveBlock {
  noLibrary('接続先にライブラリが見つかりません。接続先と権限を確認してください。'),
  notConnected('保存先が未接続です。'),
  readOnly('このライブラリは読み取り専用なので、保存できません。');

  const SaveBlock(this.message);
  final String message;
}

/// 取り込みの「保存」を止める理由。保存先が書き込める時だけ null。
SaveBlock? saveBlockFor(
    {required bool libFound,
    required bool hasConnection,
    required bool libReadOnly}) {
  if (!libFound) {
    return hasConnection ? SaveBlock.noLibrary : SaveBlock.notConnected;
  }
  if (libReadOnly) return SaveBlock.readOnly;
  return null;
}

String kindLabel(DetectedKind k) => switch (k) {
      DetectedKind.video => '動画',
      DetectedKind.hls => 'HLS動画',
      DetectedKind.audio => '音声',
      DetectedKind.image => '画像',
      DetectedKind.other => 'ファイル',
    };

IconData kindIcon(DetectedKind k) => switch (k) {
      DetectedKind.video || DetectedKind.hls => Icons.movie,
      DetectedKind.audio => Icons.music_note,
      DetectedKind.image => Icons.photo,
      DetectedKind.other => Icons.download,
    };

/// 検出した動画の再生時間。「3分05秒」「0分05秒」「65分02秒」（時間の桁は作らない）。
/// 端数は四捨五入で秒に丸める（59.6 秒は「1分00秒」）。
String fmtDuration(Duration d) {
  final total = (d.inMilliseconds / 1000).round();
  final m = total ~/ 60;
  final s = total % 60;
  return '$m分${s.toString().padLeft(2, '0')}秒';
}

String fmtSize(int bytes) {
  if (bytes >= 1000000000) return '${(bytes / 1000000000 * 10).floor() / 10} GB';
  if (bytes >= 1000000) return '${(bytes / 1000000 * 10).floor() / 10} MB';
  return '${(bytes + 500) ~/ 1000} KB';
}

String fmtHist(int epochMs) {
  final t = DateTime.fromMillisecondsSinceEpoch(epochMs);
  String p(int v) => v.toString().padLeft(2, '0');
  return '${p(t.month)}/${p(t.day)} ${p(t.hour)}:${p(t.minute)}';
}

/// 検出が1件以上ある時だけ出る、たたんだ1行。タップで一覧のシートを開く。
class DetectionBar extends StatelessWidget {
  final int count;
  final VoidCallback onTap;
  const DetectionBar({super.key, required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      onTapHint: '検出したメディアの一覧を開く',
      child: Material(
        color: AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(AppRadius.large),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.large),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.only(left: 16, right: 4),
              child: Row(
                children: [
                  const Icon(Icons.download, color: AppColors.accent),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text('$count件のメディアを検出',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
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
        ),
      ),
    );
  }
}

/// 検出したメディアの一覧（ボトムシートの中身）。
class DetectedSheetContent extends StatelessWidget {
  final List<DetectedItem> items;
  final SaveBlock? block;
  final ValueChanged<DetectedItem> onSave;
  /// 行の頭に出すサムネの作り手（#164）。null なら種類のアイコンだけ出す
  final DetectedThumbs? thumbs;

  /// 除外・選択の状態（#37/#38）。null の時は除外の操作を出さない
  final DetectionFilter? filter;
  const DetectedSheetContent({
    super.key,
    required this.items,
    required this.block,
    required this.onSave,
    this.thumbs,
    this.filter,
  });

  @override
  Widget build(BuildContext context) {
    final f = filter;
    final visible = f?.visibleOf(items) ?? items;
    final hidden = f?.excludedOf(items) ?? const <DetectedItem>[];
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: Text('検出されたメディア（${visible.length}件）',
                style: Theme.of(context).textTheme.titleMedium),
          ),
          if (block != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(block!.message,
                  style:
                      AppText.caption.copyWith(color: AppColors.danger)),
            ),
          if (f != null) ...[
            // 種別の絞り込みチップ（#26）。件数が多い時に写真だけ・動画だけへ絞る
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                children: [
                  for (final (v, label) in const [
                    (DetectedView.all, 'すべて'),
                    (DetectedView.photo, '写真'),
                    (DetectedView.video, '動画'),
                  ])
                    ChoiceChip(
                      label: Text(label),
                      selected: f.view == v,
                      onSelected: (_) => f.viewKind = v,
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 16, right: 16, bottom: 4),
              child: Wrap(
                spacing: 8,
                children: [
                  if (visible.any((d) => d.kind == DetectedKind.image))
                    TextButton.icon(
                      onPressed: () => f.excludeImages(visible),
                      icon: const Icon(Icons.hide_image_outlined, size: 18),
                      label: const Text('画像をすべて除外'),
                    ),
                  TextButton.icon(
                    onPressed:
                        f.selected.isEmpty ? null : f.excludeSelected,
                    icon: const Icon(Icons.playlist_remove, size: 18),
                    label: Text(f.selected.isEmpty
                        ? '選択して除外'
                        : '選択した${f.selected.length}件を除外'),
                  ),
                ],
              ),
            ),
          ],
          if (visible.isEmpty && items.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 24, vertical: 12),
              // 除外で消えたのか絞り込みで消えたのかを分けて出す（混同すると戻せない）。
              // 種類の合う候補自体はあるなら、未検出ではなく全部除外の方
              child: Text(
                  f != null && f.view != DetectedView.all &&
                          f.matchingOf(items).isEmpty
                      ? 'この種類のメディアは検出されていません'
                      : '検出はすべて除外されています',
                  style: const TextStyle(color: AppColors.textDim)),
            ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 24),
              itemCount: visible.length + (hidden.isEmpty ? 0 : 1),
              itemBuilder: (context, i) {
                if (i == visible.length) {
                  // 誤って外した物を戻せるよう、除外済みも末尾に畳んで残す
                  return ExpansionTile(
                    tilePadding:
                        const EdgeInsets.symmetric(horizontal: 24),
                    title: Text('除外したメディア（${hidden.length}件）',
                        style: AppText.caption.copyWith(
                            color: AppColors.textDim)),
                    children: [
                      for (final d in hidden)
                        ListTile(
                          dense: true,
                          leading: DetectedThumb(item: d, thumbs: thumbs),
                          title: Text(
                            d.label.isNotEmpty ? d.label : d.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                const TextStyle(color: AppColors.textDim),
                          ),
                          trailing: TextButton(
                            onPressed: () => f!.restore(d.url),
                            child: const Text('戻す'),
                          ),
                        ),
                    ],
                  );
                }
                final d = visible[i];
                final savable = isWebSavable(d);
                final host = d.url.contains('://')
                    ? d.url.split('://').last.split('/').first
                    : d.url;
                return ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 56),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 8, right: 8),
                    child: Row(
                      children: [
                        if (f != null)
                          Checkbox(
                            value: f.selected.contains(d.url),
                            onChanged: (_) => f.toggle(d.url),
                          ),
                        DetectedThumb(item: d, thumbs: thumbs),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(12, 6, 0, 6),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // サイト上のタイトルが分かる時はそれを出す。
                                // 機械的なファイル名だけではどの動画か見分けがつかないため
                                Text(d.label.isNotEmpty
                                    ? d.label
                                    : d.displayName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                Text(
                                  // 音声などは上げても一覧に出ないので、押す前に分かるようにする
                                  '${kindLabel(d.kind)}${d.duration == null ? '' : ' ${fmtDuration(d.duration!)}'}・$host${d.label.isNotEmpty ? '・${d.displayName}' : ''}${savable ? '' : '・ギャラリー非対応'}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppText.caption.copyWith(
                                      color: AppColors.textDim),
                                ),
                              ],
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed:
                              (block == null && savable) ? () => onSave(d) : null,
                          child: const Text('保存'),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 検出一覧の行の頭。サムネが取れるまでと取れない時は種類のアイコンを出す（#164）。
/// 大きさは行の高さ（最小 56）に収まる 48 の正方形にして、取れても取れなくても一覧の並びが揺れんようにする。
class DetectedThumb extends StatelessWidget {
  final DetectedItem item;
  final DetectedThumbs? thumbs;
  const DetectedThumb({super.key, required this.item, this.thumbs});

  static const size = 48.0;

  Widget get _icon => SizedBox(
        width: size,
        height: size,
        child: Icon(kindIcon(item.kind), color: AppColors.accent),
      );

  @override
  Widget build(BuildContext context) {
    final t = thumbs;
    if (t == null) return _icon;
    return FutureBuilder<Uint8List?>(
      future: t.of(item),
      builder: (context, snap) {
        final bytes = snap.data;
        if (bytes == null) return _icon;
        final px = (size * MediaQuery.devicePixelRatioOf(context)).round();
        return ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.small),
          child: Image.memory(
            bytes,
            width: size,
            height: size,
            fit: BoxFit.cover,
            cacheWidth: px,
            gaplessPlayback: true,
            // 画像として読めない中身（SVG や壊れたファイル）はアイコンに戻す
            errorBuilder: (context, error, stack) => _icon,
          ),
        );
      },
    );
  }
}

/// 転送中の行の要約。完了・失敗が混ざる時も1行で状況が分かるようにする。
String transfersSummary(List<WebTransferTask> tasks) {
  final active = tasks.where((t) => t.active).length;
  final failed = tasks.where((t) => t.status == WebTaskStatus.error).length;
  if (active > 0) {
    return '転送中 $active件${failed > 0 ? '・失敗 $failed件' : ''}';
  }
  if (failed > 0) return '失敗 $failed件';
  return '転送完了 ${tasks.where((t) => t.status == WebTaskStatus.done).length}件';
}

/// 転送の状況シート。ネット取り込みに加えて、アップロードとオフライン保存も同じ一覧で扱う。
/// 一時停止・再開・再試行・取り消し・終わった行の整理ができる（KMP 版 TransfersSheetContent と同じ並び）。
class TransfersSheetContent extends StatelessWidget {
  final WebTransferQueue queue;
  final TransferQueue? transfers;
  final bool online;
  const TransfersSheetContent(
      {super.key, required this.queue, this.transfers, this.online = true});

  @override
  Widget build(BuildContext context) {
    final up = transfers;
    return SafeArea(
      child: AnimatedBuilder(
        animation: Listenable.merge([queue, ?up]),
        builder: (context, _) {
          final rows = transferRows(queue, up, online: online);
          final summary = summarizeTransfers(rows, online: online);
          final groups = groupTransfers(rows);
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 8, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('転送の状況',
                          style: Theme.of(context).textTheme.titleMedium),
                    ),
                    TextButton(
                      onPressed: rows.any((r) =>
                              r.status == TransferStatus.done ||
                              r.status == TransferStatus.cancelled ||
                              r.status == TransferStatus.error)
                          ? () {
                              queue.clearFinished();
                              up?.clearFinished();
                            }
                          : null,
                      child: const Text('終わった行を消す'),
                    ),
                  ],
                ),
              ),
              if (summary != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text('${summary.title} · ${summary.detail}',
                      style: AppText.caption.copyWith(
                          color: AppColors.textDim)),
                ),
              if (rows.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('転送はありません',
                      style: TextStyle(color: AppColors.textDim)),
                ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 24),
                  children: [
                    for (final (group, items) in groups) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 12, 8, 2),
                        child: Text('${group.title} ${items.length}',
                            style: AppText.label.copyWith(
                                color: group == TransferGroup.attention
                                    ? AppColors.danger
                                    : AppColors.textDim)),
                      ),
                      for (final r in items) _TransferRowTile(row: r),
                    ],
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _TransferRowTile extends StatelessWidget {
  final TransferRow row;
  const _TransferRowTile({required this.row});

  IconData get _icon => switch (row.kind) {
        'down' => Icons.download,
        'web' => Icons.public,
        _ => Icons.cloud_upload_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final r = row;
    final moving = r.status == TransferStatus.running ||
        (r.status == TransferStatus.preparing && r.kind == 'web');
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 6, 8, 6),
      child: Row(
        children: [
          Icon(_icon, size: 22, color: AppColors.textDim),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(r.label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption.copyWith(
                        color: r.status == TransferStatus.error
                            ? AppColors.danger
                            : r.status == TransferStatus.done
                                ? AppColors.accent
                                : AppColors.textDim)),
                if (moving)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: LinearProgressIndicator(
                      value: r.percent == 0 ? null : r.percent / 100,
                      minHeight: 3,
                    ),
                  ),
              ],
            ),
          ),
          if (r.onRetry != null)
            IconButton(
              tooltip: 'やり直す',
              icon: const Icon(Icons.refresh),
              onPressed: r.onRetry,
            ),
          if (r.onResume != null)
            IconButton(
              tooltip: '再開',
              icon: const Icon(Icons.play_arrow),
              onPressed: r.onResume,
            ),
          if (r.onPause != null)
            IconButton(
              tooltip: '一時停止',
              icon: const Icon(Icons.pause),
              onPressed: r.onPause,
            ),
          if (r.onCancel != null)
            IconButton(
              tooltip: '取り消す',
              icon: const Icon(Icons.close),
              onPressed: r.onCancel,
            ),
          if (r.onDismiss != null)
            IconButton(
              tooltip: '一覧から消す',
              icon: const Icon(Icons.close),
              onPressed: r.onDismiss,
            ),
        ],
      ),
    );
  }
}

/// ダウンロード履歴ダイアログの中身。
class HistoryList extends StatelessWidget {
  final List<WebHistoryEntry> entries;
  const HistoryList({super.key, required this.entries});

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const Text('まだダウンロードはありません');
    return SizedBox(
      width: double.maxFinite,
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: entries.length,
        itemBuilder: (context, i) {
          final h = entries[i];
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: Icon(Icons.video_library,
                      size: 20, color: AppColors.textDim),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(h.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.body),
                      Text('${fmtHist(h.at)}・${fmtSize(h.size)}',
                          style: AppText.caption.copyWith(
                              color: AppColors.textDim)),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// 取り込み済みの動画をもう一度取り込もうとした時の確認。わざと複製したい時もあるので止め切らない。
/// 「それでも取り込む」を選んだ時だけ true。
Future<bool> confirmDuplicateImport(
    BuildContext context, WebHistoryEntry existing) async {
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('既にあります'),
      content: Text('${existing.name} は取り込み済みです。\n'
          '保存先: ${existing.key}\n\nもう一度取り込みますか？'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('やめる')),
        TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('それでも取り込む')),
      ],
    ),
  );
  return go == true;
}
