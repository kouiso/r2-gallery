import 'package:flutter/foundation.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../state/trash_ops.dart';

enum DuplicatesPhase { scanning, loading, ready, error, unsupported }

/// 画面で持つ1組。残す方は利用者が選び直せるので、Worker の並び（先頭）とは別に持つ。
class DuplicateGroupView {
  final String sha256;
  final int size;
  final List<MediaItem> items;
  String keeper;
  DuplicateGroupView(this.sha256, this.size, this.items)
      : keeper = items.first.key;

  /// 残す1件以外を消した時に空く容量。
  int get reclaimable => size * (items.length - 1);
}

/// ゴミ箱へ送って一覧から外した1件。失敗や「元に戻す」で同じ場所へ戻すために残す。
class RemovedDuplicate {
  final String sha256;
  final int size;
  final MediaItem item;
  final int index;
  final int groupIndex;
  final String keeper;

  /// 外す前の組の中身。組ごと消えた時に、組を元の形で戻すため。
  final List<MediaItem> before;
  const RemovedDuplicate({
    required this.sha256,
    required this.size,
    required this.item,
    required this.index,
    required this.groupIndex,
    required this.keeper,
    required this.before,
  });
}

class DuplicateTrashResult {
  final RemovedDuplicate removed;
  final TrashReceipt? receipt;
  final String? error;

  /// 残す方が消えていた・同じ中身と記録されていない時。一覧が古いので読み直す。
  final bool reload;
  const DuplicateTrashResult(this.removed,
      {this.receipt, this.error, this.reload = false});
}

/// 重複の確認画面の状態（#106）。Worker の計算を進め切ってから、組を読む。
class DuplicatesController extends ChangeNotifier {
  DuplicatesController({required this.api, required this.lib, this.pageSize = 50});

  final ApiClient api;
  final String lib;
  final int pageSize;

  DuplicatesPhase phase = DuplicatesPhase.scanning;
  String? error;

  /// 計算待ちの残り。最初の応答が来るまでは null。
  int? scanPending;
  int skipped = 0;

  /// 計算が進まなくなって途中で読みに切り替えた時の残り。0 なら全部確かめた。
  int pendingAfterScan = 0;

  final List<DuplicateGroupView> groups = [];
  String? cursor;
  int total = 0;
  int reclaimable = 0;
  bool loadingMore = false;
  bool moreFailed = false;

  bool _disposed = false;
  int _run = 0;
  final Map<String, DuplicateGroupView> _dropped = {};

  /// 何度呼んでも数が減らん時に打ち切る回数。Worker が同じ物で詰まっても画面を回し続けないため。
  static const stallLimit = 3;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> start() async {
    final run = ++_run;
    phase = DuplicatesPhase.scanning;
    error = null;
    scanPending = null;
    _notify();
    try {
      var idle = 0;
      for (;;) {
        final r = await api.duplicateScan(lib);
        if (_disposed || run != _run) return;
        scanPending = r.pending;
        skipped = r.skipped;
        _notify();
        if (r.pending == 0) break;
        idle = r.hashed == 0 ? idle + 1 : 0;
        if (idle >= stallLimit) break;
      }
    } on ApiError catch (e) {
      if (_disposed || run != _run) return;
      if (e.status == 404) {
        phase = DuplicatesPhase.unsupported;
      } else {
        phase = DuplicatesPhase.error;
        error = '重複の確認を進められませんでした';
      }
      _notify();
      return;
    }
    await reload(run: run);
  }

  /// 先頭のページから読み直す。
  Future<void> reload({int? run}) async {
    final r = run ?? ++_run;
    phase = DuplicatesPhase.loading;
    _notify();
    try {
      final page = await api.duplicates(lib, limit: pageSize);
      if (_disposed || r != _run) return;
      groups.clear();
      _dropped.clear();
      groups.addAll(_views(page.groups).toList());
      cursor = page.cursor;
      total = page.total;
      reclaimable = page.reclaimable;
      skipped = page.skipped;
      pendingAfterScan = page.pending;
      moreFailed = false;
      phase = DuplicatesPhase.ready;
    } on ApiError catch (e) {
      if (_disposed || r != _run) return;
      phase = e.status == 404
          ? DuplicatesPhase.unsupported
          : DuplicatesPhase.error;
      error = '重複の一覧を読めませんでした';
    }
    _notify();
  }

  Iterable<DuplicateGroupView> _views(List<DuplicateGroup> page) sync* {
    for (final g in page) {
      // 削除や並びの変化でページの境目がずれても、同じ組を二度出さない
      if (g.items.length < 2 || groups.any((v) => v.sha256 == g.sha256)) {
        continue;
      }
      yield DuplicateGroupView(g.sha256, g.size, [...g.items]);
    }
  }

  Future<void> loadMore() async {
    final c = cursor;
    if (c == null || loadingMore || phase != DuplicatesPhase.ready) return;
    final run = _run;
    loadingMore = true;
    moreFailed = false;
    _notify();
    try {
      final page = await api.duplicates(lib, cursor: c, limit: pageSize);
      if (_disposed || run != _run) return;
      groups.addAll(_views(page.groups).toList());
      cursor = page.cursor;
    } on ApiError {
      if (_disposed || run != _run) return;
      moreFailed = true;
    } finally {
      loadingMore = false;
    }
    _notify();
  }

  void setKeeper(DuplicateGroupView g, String key) {
    if (!g.items.any((i) => i.key == key)) return;
    g.keeper = key;
    _notify();
  }

  /// 消してよいか。残す方と、組の最後の1件は消させない。
  bool canTrash(DuplicateGroupView g, MediaItem item) =>
      g.items.length > 1 && item.key != g.keeper;

  /// 一覧からすぐ外してからゴミ箱へ送る。失敗したら元の場所へ戻す。
  Future<DuplicateTrashResult> trash(
      DuplicateGroupView g, MediaItem item) async {
    final groupIndex = groups.indexOf(g);
    final index = g.items.indexWhere((i) => i.key == item.key);
    final removed = RemovedDuplicate(
      sha256: g.sha256,
      size: g.size,
      item: item,
      index: index,
      groupIndex: groupIndex,
      keeper: g.keeper,
      before: [...g.items],
    );
    if (groupIndex < 0 || index < 0 || !canTrash(g, item)) {
      return DuplicateTrashResult(removed, error: 'この項目は消せません');
    }
    g.items.removeAt(index);
    reclaimable -= g.size;
    if (g.items.length < 2) {
      groups.remove(g);
      // 残った1件は「元に戻す」で組を戻す時の土台にする。外す前の写しだと、後から消した物まで生き返る
      _dropped[g.sha256] = g;
      total -= 1;
    }
    _notify();
    try {
      final tk =
          await api.trashDuplicate(lib, item.key, keep: removed.keeper);
      return DuplicateTrashResult(removed,
          receipt: tk.isEmpty ? null : TrashReceipt(lib, tk));
    } on ApiError catch (e) {
      restore(removed);
      final stale = e.status == 409 &&
          (e.code == 'keeper_missing' || e.code == 'not_duplicate');
      return DuplicateTrashResult(removed,
          error: switch (e.code) {
            'keeper_missing' => '残す方が見つかりませんでした。一覧を読み直します',
            'not_duplicate' => '同じ中身と確かめられませんでした。一覧を読み直します',
            'read_only_library' => 'このライブラリは読み取り専用です',
            _ => 'ゴミ箱へ移せませんでした',
          },
          reload: stale);
    }
  }

  /// 外した1件を元の組・元の位置へ戻す（失敗した時と「元に戻す」の後）。
  void restore(RemovedDuplicate r) {
    final existing = groups.where((g) => g.sha256 == r.sha256).toList();
    if (existing.isNotEmpty) {
      final g = existing.first;
      if (g.items.any((i) => i.key == r.item.key)) return;
      g.items.insert(r.index.clamp(0, g.items.length), r.item);
    } else {
      final g = _dropped.remove(r.sha256) ??
          (DuplicateGroupView(r.sha256, r.size, [
            for (final i in r.before)
              if (i.key != r.item.key) i,
          ])
            ..keeper = r.keeper);
      if (g.items.any((i) => i.key == r.item.key)) return;
      g.items.insert(r.index.clamp(0, g.items.length), r.item);
      groups.insert(r.groupIndex.clamp(0, groups.length), g);
      total += 1;
    }
    reclaimable += r.size;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
