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
