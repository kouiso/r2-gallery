import 'dart:async';

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../state/trash_ops.dart';

export '../state/trash_ops.dart' show TrashReceipt, TrashOutcome, trashAll;

/// 「元に戻す」を押せる時間。短いと押す前に消え、長いと次の操作の通知が後ろに詰まる（KMP 版と同じ6秒）
const Duration trashUndoWindow = Duration(seconds: 6);

/// ゴミ箱へ送った直後に「元に戻す」スナックバーを出す。単発・一括、どのタブからでも呼ぶ。
///
/// [messenger] は await の前に取っておく。戻すのを待つ間にタブやライブラリが切り替わって
/// 呼び出し元の context が無くなっても、結果の通知は出せるようにするため。
/// 戻した後は一覧が古いままになるので、[onRestored] で呼び出し側が読み直す。
Future<void> offerTrashUndo(
  ScaffoldMessengerState messenger,
  ApiClient api,
  List<TrashReceipt> receipts, {
  VoidCallback? onRestored,
}) async {
  if (receipts.isEmpty) return;
  final controller = messenger.showSnackBar(SnackBar(
    content: Text('${receipts.length}件をゴミ箱に移しました'),
    duration: trashUndoWindow,
    // 操作ボタン付きの既定は「閉じるまで残る」。それだと6秒で取り消し期限が切れたのか分からんので時間で消す
    persist: false,
    action: SnackBarAction(label: '元に戻す', onPressed: () {}),
  ));
  final reason = await controller.closed;
  if (reason != SnackBarClosedReason.action) return;
  final result = await restoreAll(api, receipts);
  // 一部だけ戻った場合も一覧は変わっている。通知を出す前に読み直しを始める
  onRestored?.call();
  final msg = restoreSummaryMessage(result);
  if (msg != null && messenger.mounted) {
    messenger.showSnackBar(SnackBar(content: Text(msg)));
  }
}

/// 一覧から先に外し、ゴミ箱へは裏で送っている時の「元に戻す」。送り終わるのを待たずに出す。
/// 全部送れなかったと分かったら、移していない物を「移しました」と言い続けないよう閉じる。
/// 戻す本体（行の差し戻しと復元）は [onUndo] が持ち、その結果で失敗の文言を出す。
Future<void> offerOptimisticTrashUndo(
  ScaffoldMessengerState messenger, {
  required int count,
  required Future<TrashOutcome> done,
  required Future<RestoreOutcome> Function() onUndo,
}) async {
  if (count <= 0) return;
  final controller = messenger.showSnackBar(SnackBar(
    content: Text('$count件をゴミ箱に移しました'),
    duration: trashUndoWindow,
    persist: false,
    action: SnackBarAction(label: '元に戻す', onPressed: () {}),
  ));
  var closed = false;
  unawaited(done.then((res) {
    if (res.trashed == 0 && !closed) controller.close();
  }));
  final reason = await controller.closed;
  closed = true;
  if (reason != SnackBarClosedReason.action) return;
  final result = await onUndo();
  final msg = restoreSummaryMessage(result);
  if (msg != null && messenger.mounted) {
    messenger.showSnackBar(SnackBar(content: Text(msg)));
  }
}
