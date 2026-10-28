import 'package:flutter/material.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../state/trash_ops.dart';
import '../state/trash_state.dart';
import '../state/write_guard.dart';
import 'theme.dart';
import 'trash_parts.dart';
import 'write_guard_notice.dart';

/// ゴミ箱タブ: 削除済み一覧 + 行ごとの復元 + 選択して一括復元。
class TrashTab extends StatefulWidget {
  final AppState app;
  final String lib;
  /// 表示中のタブか。裏にいる間はライブラリが変わっても取りに行かず、開いた時に取る
  final bool active;
  /// 「今年か」の判定に使う時計。テストで日付表示を固定するため差し替えられるようにしている
  final DateTime Function() clock;
  const TrashTab({
    super.key,
    required this.app,
    required this.lib,
    this.active = true,
    this.clock = DateTime.now,
  });

  @override
  State<TrashTab> createState() => _TrashTabState();
}

class _TrashTabState extends State<TrashTab> {
  late final TrashState t = TrashState(widget.app.api);
  String? _loadedLib;

  // 読み取り専用のライブラリは Worker がゴミ箱の一覧も戻すのも 403 で断る。聞きに行かず、理由を出す
  bool get _readOnly {
    for (final l in widget.app.libraries) {
      if (l.id == widget.lib) return l.readOnly;
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    if (widget.active) _load();
  }

  @override
  void didUpdateWidget(TrashTab old) {
    super.didUpdateWidget(old);
    // 写真タブでゴミ箱へ送った・元に戻した分を映すため、タブに戻ってきた時も読み直す
    if (widget.active && (_loadedLib != widget.lib || !old.active)) _load();
  }

  void _load() {
    _loadedLib = widget.lib;
    if (_readOnly) return;
    t.refresh(widget.lib);
  }

  Future<void> _reload() => _readOnly ? Future.value() : t.refresh(widget.lib);

  @override
  void dispose() {
    t.dispose();
    super.dispose();
  }

  void _say(ScaffoldMessengerState m, String text) =>
      m.showSnackBar(SnackBar(content: Text(text)));

  Future<void> _restoreOne(TrashItem item) async {
    if (!ensureWritable(context, widget.app, widget.lib, WriteAction.restore)) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final status = await t.restoreOne(widget.lib, item);
    // 404 は「もう戻っている」。写真タブの一覧が古いだけなので、これも取り直させる
    if (status == null || status == 404) widget.app.markContentChanged(widget.lib);
    if (status != null) _say(messenger, restoreFailureMessage(status));
  }

  Future<void> _restoreSelected() async {
    if (!ensureWritable(context, widget.app, widget.lib, WriteAction.restore)) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final res = await t.bulkRestore(widget.lib);
    if (res.restored > 0) {
      widget.app.markContentChanged(widget.lib);
      _say(messenger, '${res.restored}件を復元しました');
    }
    final msg = restoreSummaryMessage(res);
    if (msg != null) _say(messenger, msg);
  }

  @override
  Widget build(BuildContext context) {
    final readOnly = _readOnly;
    return AnimatedBuilder(
      animation: t,
      builder: (context, _) {
        final now = widget.clock();
        final List<Widget> children;
        if (readOnly) {
          children = [
            TrashStateView(
              icon: Icons.lock_outline,
              title: '読み取り専用のライブラリです',
              body: 'このライブラリは読み取り専用なので、ゴミ箱へ移したり戻したりはできません。',
            ),
          ];
        } else if (t.loading && t.items.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        } else if (t.error != null && t.items.isEmpty) {
          children = [
            TrashStateView(
              icon: Icons.cloud_off_outlined,
              iconColor: AppColors.danger,
              title: '読み込めませんでした',
              body: '${t.error}\n通信状態を確認して、もう一度お試しください。',
              action: FilledButton(onPressed: _reload, child: const Text('再試行')),
            ),
          ];
        } else if (t.items.isEmpty) {
          children = [
            TrashInfoBanner(
                trashRetentionNotice(t.retentionDays, canRestore: true)),
            const TrashStateView(
              icon: Icons.delete_outline,
              title: 'ゴミ箱は空です',
              body: 'ゴミ箱に移した写真や動画がここに表示されます。',
            ),
          ];
        } else {
          children = [
            TrashInfoBanner(
                trashRetentionNotice(t.retentionDays, canRestore: !readOnly)),
            if (t.error != null)
              TrashErrorBanner('最新の状態を読み込めませんでした', onRetry: _reload),
            for (final it in t.items)
              Padding(
                key: ValueKey(it.trashKey),
                padding: const EdgeInsets.fromLTRB(12, 3, 12, 3),
                child: TrashRow(
                  item: it,
                  now: now,
                  selected: t.selected.contains(it.trashKey),
                  busy: t.restoring.contains(it.trashKey),
                  canRestore: !readOnly,
                  onTap: readOnly ? null : () => t.toggle(it.trashKey),
                  onRestore: () => _restoreOne(it),
                ),
              ),
          ];
        }
        return Stack(children: [
          Positioned.fill(
            child: RefreshIndicator(
              onRefresh: _reload,
              child: ListView(
                // 空や失敗の表示でも引っ張って読み直せるよう、中身が短くてもスクロールさせる
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.only(bottom: 120),
                children: children,
              ),
            ),
          ),
          if (t.selected.isNotEmpty && !readOnly)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: Material(
                    color: AppColors.surfaceHigh,
                    elevation: 8,
                    borderRadius: BorderRadius.circular(20),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 6),
                      child: Row(children: [
                        IconButton(
                            tooltip: '選択を解除',
                            onPressed: t.clearSelection,
                            icon: const Icon(Icons.close)),
                        Text('${t.selected.length}件',
                            style:
                                const TextStyle(fontWeight: FontWeight.w700)),
                        const Spacer(),
                        FilledButton.icon(
                          onPressed: _restoreSelected,
                          icon: const Icon(Icons.restore, size: 18),
                          label: const Text('まとめて復元'),
                        ),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
        ]);
      },
    );
  }
}
