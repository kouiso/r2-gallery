import 'package:flutter/foundation.dart';

import '../webdl/web_transfer.dart';
import 'transfer_queue.dart';

/// 転送バーと転送シートに出す1行。アップロード・オフライン保存（TransferQueue）と
/// ネット取り込み（WebTransferQueue）を同じ見た目と操作で並べるための形。
class TransferRow {
  final String id;
  final String name;

  /// 'up' / 'down' / 'web'
  final String kind;
  final TransferStatus status;
  final int percent;
  final int size;
  final int loaded;
  final String label;
  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final VoidCallback? onRetry;
  final VoidCallback? onCancel;
  final VoidCallback? onDismiss;

  const TransferRow({
    required this.id,
    required this.name,
    required this.kind,
    required this.status,
    required this.percent,
    required this.size,
    required this.loaded,
    required this.label,
    this.onPause,
    this.onResume,
    this.onRetry,
    this.onCancel,
    this.onDismiss,
  });

  bool get live =>
      status == TransferStatus.queued ||
      status == TransferStatus.preparing ||
      status == TransferStatus.running ||
      status == TransferStatus.paused;
}

String _pct(int p) => '$p%';

/// アップロード・オフライン保存の行。文言は KMP 版 TransfersParts.kt の statusLabel と同じ。
TransferRow rowOfTask(TransferTask t, TransferQueue q, {required bool online}) {
  final label = switch (t.status) {
    TransferStatus.preparing => '端末に保存中',
    TransferStatus.queued => online ? '待機中' : '待機中（オフライン）',
    TransferStatus.running => t.isUpload
        ? 'アップロード中 ${_pct(t.percent)}'
        : 'オフライン保存中 ${_pct(t.percent)}',
    TransferStatus.done => '完了',
    TransferStatus.error => '失敗: ${t.error ?? ''}',
    TransferStatus.cancelled => '取り消しました',
    TransferStatus.paused =>
      t.percent > 0 ? '一時停止 ${_pct(t.percent)}' : '一時停止中',
  };
  final s = t.status;
  return TransferRow(
    id: t.id,
    name: t.name,
    kind: t.kind,
    status: s,
    percent: t.percent,
    size: t.size,
    loaded: t.loaded,
    label: label,
    onPause: s == TransferStatus.running ||
            s == TransferStatus.queued ||
            s == TransferStatus.preparing
        ? () => q.pause(t.id)
        : null,
    onResume: s == TransferStatus.paused ? () => q.resume(t.id) : null,
    onRetry: s == TransferStatus.error ? () => q.retry(t.id) : null,
    onCancel: s == TransferStatus.done || s == TransferStatus.cancelled
        ? null
        : () => q.cancel(t.id),
    onDismiss: s == TransferStatus.done || s == TransferStatus.cancelled
        ? () => q.dismiss(t.id)
        : null,
  );
}

TransferStatus _webStatus(WebTaskStatus s) => switch (s) {
      WebTaskStatus.queued => TransferStatus.queued,
      WebTaskStatus.fetching => TransferStatus.preparing,
      WebTaskStatus.uploading => TransferStatus.running,
      WebTaskStatus.done => TransferStatus.done,
      WebTaskStatus.error => TransferStatus.error,
      WebTaskStatus.cancelled => TransferStatus.cancelled,
      WebTaskStatus.paused => TransferStatus.paused,
    };

/// ネット取り込みの行。取得の段は「ネットから取得中」と出して、アップロードと区別する。
TransferRow rowOfWeb(WebTransferTask t, WebTransferQueue q,
    {required bool online}) {
  final s = _webStatus(t.status);
  final label = switch (t.status) {
    WebTaskStatus.queued => online ? '待機中' : '待機中（オフライン）',
    WebTaskStatus.fetching => t.hls && t.hlsTotal > 0
        ? 'ネットから取得中 ${t.hlsSeg}/${t.hlsTotal}'
        : 'ネットから取得中 ${_pct(t.percent)}',
    WebTaskStatus.uploading => 'アップロード中 ${_pct(t.percent)}',
    WebTaskStatus.done => '完了',
    WebTaskStatus.error => '失敗: ${t.error ?? ''}',
    WebTaskStatus.cancelled => '取り消しました',
    WebTaskStatus.paused =>
      t.percent > 0 ? '一時停止 ${_pct(t.percent)}' : '一時停止中',
  };
  return TransferRow(
    id: t.id,
    name: t.name,
    kind: 'web',
    status: s,
    percent: t.percent,
    // HLS の取得中は総バイト数が分からんので、残りの計算に入れない
    size: t.hls && t.status == WebTaskStatus.fetching ? 0 : t.size,
    loaded: t.hls && t.status == WebTaskStatus.fetching ? 0 : t.loaded,
    label: label,
    onPause: t.active ? () => q.pause(t.id) : null,
    onResume: s == TransferStatus.paused ? () => q.resume(t.id) : null,
    onRetry: s == TransferStatus.error || s == TransferStatus.cancelled
        ? () => q.retry(t.id)
        : null,
    onCancel: t.active || s == TransferStatus.paused ? () => q.cancel(t.id) : null,
    onDismiss: s == TransferStatus.done || s == TransferStatus.cancelled
        ? () => q.dismiss(t.id)
        : null,
  );
}

/// 両方のキューの行。新しく積んだものを上に出す。
List<TransferRow> transferRows(WebTransferQueue web, TransferQueue? queue,
    {bool online = true}) {
  return [
    if (queue != null)
      for (final t in queue.tasks.reversed) rowOfTask(t, queue, online: online),
    for (final t in web.tasks.reversed) rowOfWeb(t, web, online: online),
  ];
}

/// 転送バーの要約。動いているものも失敗も無ければ null（バーごと出さない）。KMP 版 summarizeTransfers と同じ組み立て。
class TransferSummary {
  final int active;
  final int failed;
  final int percent;
  final String title;
  final String detail;

  /// アップロード系か（false ならオフライン保存だけ）。
  final bool upload;
  const TransferSummary({
    required this.active,
    required this.failed,
    required this.percent,
    required this.title,
    required this.detail,
    required this.upload,
  });
}

String formatBytes(int bytes) {
  if (bytes >= 1000000000) return '${(bytes / 1000000000).toStringAsFixed(1)} GB';
  if (bytes >= 1000000) return '${(bytes / 1000000).toStringAsFixed(1)} MB';
  if (bytes >= 1000) return '${(bytes / 1000).toStringAsFixed(0)} KB';
  return '$bytes B';
}

TransferSummary? summarizeTransfers(List<TransferRow> rows,
    {bool online = true}) {
  final live = rows.where((r) => r.live).toList();
  final failed = rows.where((r) => r.status == TransferStatus.error).length;
  if (live.isEmpty && failed == 0) return null;
  // 失敗だけの時も、失敗した転送の種類で向き（アイコン）を決める
  final basis =
      live.isNotEmpty ? live : rows.where((r) => r.status == TransferStatus.error);
  final downOnly = basis.isNotEmpty && basis.every((r) => r.kind == 'down');
  final mixed =
      live.any((r) => r.kind == 'down') && live.any((r) => r.kind != 'down');
  final title = live.isEmpty
      ? '転送に失敗したものがあります'
      : mixed
          ? '転送中 ${live.length}件'
          : downOnly
              ? 'オフライン保存中 ${live.length}件'
              : 'アップロード中 ${live.length}件';
  final percent = live.isEmpty
      ? 0
      : live.fold<int>(0, (a, r) => a + r.percent) ~/ live.length;
  final remaining = live.fold<int>(
      0, (a, r) => a + (r.size - r.loaded > 0 ? r.size - r.loaded : 0));
  final parts = <String>[];
  if (live.isNotEmpty) {
    if (live.every((r) => r.status == TransferStatus.paused)) {
      parts.add('一時停止中');
    } else if (!online && live.any((r) => r.status == TransferStatus.queued)) {
      parts.add('オフライン（接続待ち）');
    } else if (remaining > 0) {
      parts.add('残り ${formatBytes(remaining)}');
    } else {
      parts.add('$percent%');
    }
  }
  if (failed > 0) parts.add('失敗 $failed件');
  return TransferSummary(
    active: live.length,
    failed: failed,
    percent: percent,
    title: title,
    detail: parts.join(' · '),
    upload: !downOnly,
  );
}

enum TransferGroup {
  attention('要対応'),
  active('進行中'),
  waiting('待機中'),
  finished('完了・取り消し');

  const TransferGroup(this.title);
  final String title;
}

/// 転送シートの並び: 失敗 → 進行中（一時停止を含む）→ 待機中 → 完了。空のグループは出さない。
List<(TransferGroup, List<TransferRow>)> groupTransfers(List<TransferRow> rows) {
  TransferGroup groupOf(TransferRow r) => switch (r.status) {
        TransferStatus.error => TransferGroup.attention,
        TransferStatus.running ||
        TransferStatus.preparing ||
        TransferStatus.paused =>
          TransferGroup.active,
        TransferStatus.queued => TransferGroup.waiting,
        TransferStatus.done || TransferStatus.cancelled => TransferGroup.finished,
      };
  final by = <TransferGroup, List<TransferRow>>{};
  for (final r in rows) {
    (by[groupOf(r)] ??= []).add(r);
  }
  return [
    for (final g in TransferGroup.values)
      if (by[g] != null) (g, by[g]!),
  ];
}
