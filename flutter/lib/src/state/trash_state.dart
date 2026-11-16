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
  /// 行は返事を待たずに外し、戻せなかったら元の位置へ戻す（待たせると操作がもたつくため）。
  Future<int?> restoreOne(String lib, TrashItem t) async {
    if (!restoring.add(t.trashKey)) return null;
    final removed = _takeRows({t.trashKey});
    notifyListeners();
    final res = await restoreAll(api, [TrashReceipt(lib, t.trashKey)]);
    restoring.remove(t.trashKey);
    final status = res.failures[t.trashKey];
    // 404 = すでに戻っている。行は戻さず、一覧が古いだけなので読み直して整える
    if (status != null && status != 404) _putBack(removed);
    notifyListeners();
    if (status == 404) await refresh(lib);
    return status;
  }

  /// [keys] の行を外し、元の位置と選択の有無を控えて返す。
  List<({int index, TrashItem item, bool selected})> _takeRows(
      Set<String> keys) {
    final out = <({int index, TrashItem item, bool selected})>[];
    for (var i = 0; i < items.length; i++) {
      final it = items[i];
      if (keys.contains(it.trashKey)) {
        out.add((index: i, item: it, selected: selected.remove(it.trashKey)));
      }
    }
    items = items.where((x) => !keys.contains(x.trashKey)).toList();
    return out;
  }

  /// [_takeRows] で外した行を元の位置へ戻す。読み直しで既に戻っている行は重ねない。
  void _putBack(List<({int index, TrashItem item, bool selected})> rows) {
    final list = [...items];
    for (final r in rows) {
      if (list.any((x) => x.trashKey == r.item.trashKey)) continue;
      list.insert(r.index.clamp(0, list.length), r.item);
      if (r.selected) selected.add(r.item.trashKey);
    }
    items = list;
  }

  void toggle(String trashKey) {
    if (!selected.remove(trashKey)) selected.add(trashKey);
    notifyListeners();
  }

  void clearSelection() {
    selected.clear();
    notifyListeners();
  }

  /// 選んだ分をまとめて戻す。行は先に外し、戻せなかった行だけ元の位置へ戻す。
  Future<RestoreOutcome> bulkRestore(String lib) async {
    final targets = [for (final k in selected) TrashReceipt(lib, k)];
    final keys = {for (final t in targets) t.trashKey};
    final removed = _takeRows(keys);
    selected.clear();
    restoring.addAll(keys);
    notifyListeners();
    final res = await restoreAll(api, targets);
    restoring.removeAll(keys);
    _putBack([
      for (final r in removed)
        if (res.failures[r.item.trashKey] case final st? when st != 404) r,
    ]);
    notifyListeners();
    // 全部戻せたなら手元の一覧が正しい。失敗が混ざった時だけ（404 の取り違えも含め）読み直して整える
    if (res.failed > 0) await refresh(lib);
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
