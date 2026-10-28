import 'package:flutter/foundation.dart';

import '../api/client.dart';
import '../api/models.dart';
import 'trash_ops.dart';

/// Worker が保持日数を返さん時（古い Worker）に出す日数。Worker の既定 TRASH_RETENTION_DAYS と同じ
const int kTrashRetentionDaysFallback = 30;

/// ゴミ箱タブの状態。
class TrashState extends ChangeNotifier {
  final ApiClient api;
  TrashState(this.api);

  List<TrashItem> items = [];
  bool loading = false;
  String? error;
  int retentionDays = kTrashRetentionDaysFallback;
  final Set<String> selected = {};

  /// 復元を送っている途中の trashKey。二度押しで同じ復元を送らんため
  final Set<String> restoring = {};
  int _epoch = 0;
  String? _lib;
  bool _disposed = false;

  Future<void> refresh(String lib) async {
    final e = ++_epoch;
    // 別のライブラリの選択を持ち越すと、復元先を取り違える
    if (_lib != lib) {
      selected.clear();
      items = [];
    }
    _lib = lib;
    loading = true;
    error = null;
    notifyListeners();
    try {
      // 1ページ目だけだと古い項目が見えず、期限前に戻せる物を見落とす。全ページ取る（KMP 版と同じ）
      final all = <TrashItem>[];
      String? cursor;
      int? days;
      do {
        final page = await api.trashList(lib, cursor: cursor);
        if (e != _epoch) return;
        all.addAll(page.items);
        days ??= page.retentionDays;
        cursor = page.cursor;
      } while (cursor != null);
      // 新しく捨てた物ほど探される。Worker はキー順（=古い順）で返すので逆にする
      all.sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
      items = all;
      if (days != null && days > 0) retentionDays = days;
      selected.retainAll(all.map((t) => t.trashKey));
    } on Exception catch (err) {
      if (e != _epoch) return;
      error = err.toString();
    }
    loading = false;
    notifyListeners();
  }

  /// 1件戻す。成功なら null、失敗なら HTTP ステータス（通信失敗は 0）を返す。
  Future<int?> restoreOne(String lib, TrashItem t) async {
    if (!restoring.add(t.trashKey)) return null;
    notifyListeners();
    final res = await restoreAll(api, [TrashReceipt(lib, t.trashKey)]);
    restoring.remove(t.trashKey);
    int? status;
    if (res.restored == 1) {
      // 読み直しが終わる前にもう一度押せんよう、戻した行を先に外す
      items = items.where((x) => x.trashKey != t.trashKey).toList();
      selected.remove(t.trashKey);
    } else {
      status = res.conflict > 0
          ? 409
          : res.readOnly > 0
              ? 403
              : res.notFound > 0
                  ? 404
                  : 0;
    }
    notifyListeners();
    // 404 = すでに戻っている。一覧が古いだけなので、失敗でも読み直して整える
    if (status == null || status == 404) await refresh(lib);
    return status;
  }

  void toggle(String trashKey) {
    if (!selected.remove(trashKey)) selected.add(trashKey);
    notifyListeners();
  }

  void clearSelection() {
    selected.clear();
    notifyListeners();
  }

  Future<RestoreOutcome> bulkRestore(String lib) async {
    final targets = [for (final k in selected) TrashReceipt(lib, k)];
    selected.clear();
    restoring.addAll(targets.map((t) => t.trashKey));
    notifyListeners();
    final res = await restoreAll(api, targets);
    restoring.removeAll(targets.map((t) => t.trashKey));
    notifyListeners();
    await refresh(lib);
    return res;
  }

  @override
  void notifyListeners() {
    // 画面を閉じた後に通信が返っても落ちんようにする（ロック画面へ切り替わった時など）
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
