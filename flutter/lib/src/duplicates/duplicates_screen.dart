import 'dart:async';

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../grid/day_label.dart';
import '../grid/state_views.dart';
import '../state/app_state.dart';
import '../state/write_guard.dart';
import '../ui/media_tile.dart';
import '../ui/theme.dart';
import '../ui/trash_undo.dart';
import '../ui/viewer_screen.dart';
import '../ui/write_guard_notice.dart';
import '../viewer/viewer_format.dart';
import 'duplicates_controller.dart';

/// 設定タブから開く。重複の確認は時間がかかるので、専用の画面で進み具合を見せる。
Future<void> openDuplicates(BuildContext context, AppState app, String lib) =>
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => DuplicatesScreen(app: app, lib: lib),
    ));

/// 中身がバイト単位で同じ写真・動画の組を出し、利用者が1件ずつ消す画面（#106）。
/// 自動では何も消さない。消した物はゴミ箱へ行くので元に戻せる。
class DuplicatesScreen extends StatefulWidget {
  final AppState app;
  final String lib;

  /// テストで時刻を固定するための口。
  final DateTime Function() clock;
  const DuplicatesScreen(
      {super.key, required this.app, required this.lib, this.clock = DateTime.now});

  @override
  State<DuplicatesScreen> createState() => _DuplicatesScreenState();
}

class _DuplicatesScreenState extends State<DuplicatesScreen> {
  late final DuplicatesController _c =
      DuplicatesController(api: widget.app.api, lib: widget.lib);

  @override
  void initState() {
    super.initState();
    unawaited(_c.start());
  }

  @override
  void dispose() {
    // 計算の呼び出しは次の区切りで止まる。画面を離れることが取り消しになる
    _c.dispose();
    super.dispose();
  }

  bool get _readOnly => widget.app.isReadOnlyLib(widget.lib);

  Future<void> _trash(DuplicateGroupView g, MediaItem item) async {
    final app = widget.app;
    if (!ensureWritable(context, app, widget.lib, WriteAction.trash)) return;
    final messenger = ScaffoldMessenger.of(context);
    final r = await _c.trash(g, item);
    final err = r.error;
    if (err != null) {
      messenger.showSnackBar(SnackBar(content: Text(err)));
      if (r.reload) unawaited(_c.reload());
      return;
    }
    app.markContentChanged(widget.lib);
    final receipt = r.receipt;
    if (receipt == null) return;
    unawaited(offerTrashUndo(messenger, app.api, [receipt], onRestored: () {
      _c.restore(r.removed);
      app.markContentChanged(widget.lib);
    }));
  }

  Future<void> _open(DuplicateGroupView g, int index) => openViewer(
        context,
        app: widget.app,
        lib: widget.lib,
        items: List.of(g.items),
        index: index,
        // ビューアからゴミ箱へ送ると組の形が変わるので読み直す
        onChanged: () => unawaited(_c.reload()),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('重複した写真・動画')),
      body: ListenableBuilder(listenable: _c, builder: (context, _) => _body()),
    );
  }

  Widget _body() {
    switch (_c.phase) {
      case DuplicatesPhase.scanning:
        final n = _c.scanPending;
        return StateView(
          icon: Icons.content_copy_outlined,
          title: n == null || n == 0 ? '確認中…' : '確認中… あと $n 件',
          body: '中身が同じ物を探しています。画面を離れると止まります',
          actions: const [
            SizedBox(width: 160, child: LinearProgressIndicator()),
          ],
        );
      case DuplicatesPhase.loading:
        return const Center(child: CircularProgressIndicator());
      case DuplicatesPhase.unsupported:
        return const StateView(
          icon: Icons.cloud_off_outlined,
          title: 'この接続先はまだ重複の確認に対応していません',
        );
      case DuplicatesPhase.error:
        return StateView(
          icon: Icons.error_outline,
          iconColor: AppColors.danger,
          title: _c.error ?? '読み込めませんでした',
          actions: [StatePrimaryButton('再試行', () => unawaited(_c.start()))],
        );
      case DuplicatesPhase.ready:
        if (_c.groups.isEmpty) {
          return StateView(
            icon: Icons.check_circle_outline,
            title: '重複は見つかりませんでした',
            body: _c.skipped > 0
                ? '大きすぎて確認できなかった物: ${_c.skipped} 件'
                : null,
          );
        }
        return _list();
    }
  }

  Widget _list() {
    final groups = _c.groups;
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: groups.length + 2,
      itemBuilder: (context, i) {
        if (i == 0) return _header();
        if (i == groups.length + 1) return _footer();
        final g = groups[i - 1];
        return _GroupCard(
          key: ValueKey(g.sha256),
          group: g,
          readOnly: _readOnly,
          now: widget.clock(),
          canTrash: (item) => !_readOnly && _c.canTrash(g, item),
          onKeep: (item) => _c.setKeeper(g, item.key),
          onTrash: (item) => unawaited(_trash(g, item)),
          onOpen: (index) => unawaited(_open(g, index)),
        );
      },
    );
  }

  Widget _header() {
    const dim = TextStyle(color: AppColors.textDim, fontSize: 12);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${_c.total}組 · ${formatBytes(_c.reclaimable)} 空けられます',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          const Text('中身がまったく同じ物だけを並べています。消すかどうかは1件ずつ選べます',
              style: dim),
          if (_c.skipped > 0)
            Text('大きすぎて確認できなかった物: ${_c.skipped} 件', style: dim),
          if (_c.pendingAfterScan > 0)
            Text('まだ確認できていない物: ${_c.pendingAfterScan} 件', style: dim),
          if (_readOnly)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                  widget.app.writeBlock(widget.lib, WriteAction.trash) ??
                      'このライブラリは読み取り専用です',
                  style: const TextStyle(color: AppColors.danger, fontSize: 12)),
            ),
        ],
      ),
    );
  }

  Widget _footer() {
    if (_c.cursor == null) return const SizedBox.shrink();
    if (_c.moreFailed) {
      return Center(child: StateTextButton('続きを読み込む', () => unawaited(_c.loadMore())));
    }
    // 末尾が見えたら続きを読む。描画中に状態を変えないよう、描き終えてから頼む
    if (!_c.loadingMore) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => mounted ? unawaited(_c.loadMore()) : null);
    }
    return const Padding(
      padding: EdgeInsets.all(16),
      child: Center(child: CircularProgressIndicator()),
    );
  }
}

class _GroupCard extends StatelessWidget {
  final DuplicateGroupView group;
  final bool readOnly;
  final DateTime now;
  final bool Function(MediaItem) canTrash;
  final ValueChanged<MediaItem> onKeep;
  final ValueChanged<MediaItem> onTrash;
  final ValueChanged<int> onOpen;
  const _GroupCard({
    super.key,
    required this.group,
    required this.readOnly,
    required this.now,
    required this.canTrash,
    required this.onKeep,
    required this.onTrash,
    required this.onOpen,
  });

  static String _dir(String key) {
    final i = key.lastIndexOf('/');
    return i < 0 ? '' : key.substring(0, i);
  }

  @override
  Widget build(BuildContext context) {
    final items = group.items;
    // 全部同じフォルダならフォルダ名は情報にならないので出さない
    final showDir = items.map((i) => _dir(i.key)).toSet().length > 1;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${items.length}件 · 1件 ${formatBytes(group.size)}',
                style:
                    const TextStyle(color: AppColors.textDim, fontSize: 12)),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < items.length; i++)
                    _ItemCell(
                      item: items[i],
                      keeper: items[i].key == group.keeper,
                      showDir: showDir,
                      dir: _dir(items[i].key),
                      now: now,
                      readOnly: readOnly,
                      canTrash: canTrash(items[i]),
                      onKeep: () => onKeep(items[i]),
                      onTrash: () => onTrash(items[i]),
                      onOpen: () => onOpen(i),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ItemCell extends StatelessWidget {
  final MediaItem item;
  final bool keeper;
  final bool showDir;
  final String dir;
  final DateTime now;
  final bool readOnly;
  final bool canTrash;
  final VoidCallback onKeep;
  final VoidCallback onTrash;
  final VoidCallback onOpen;
  const _ItemCell({
    required this.item,
    required this.keeper,
    required this.showDir,
    required this.dir,
    required this.now,
    required this.readOnly,
    required this.canTrash,
    required this.onKeep,
    required this.onTrash,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    const dim = TextStyle(color: AppColors.textDim, fontSize: 11);
    final thumb = item.thumbUrl;
    final created = item.createdAt;
    final size = item.size;
    return Container(
      width: 128,
      margin: const EdgeInsets.only(right: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            label: item.name,
            button: true,
            child: GestureDetector(
              onTap: onOpen,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 128,
                  height: 128,
                  child: ColoredBox(
                    color: AppColors.surfaceHigh,
                    child: Stack(fit: StackFit.expand, children: [
                      // 動画でサムネが無い時に原本URLを渡すと動画を丸ごと落とすので、一覧と同じく枠だけ出す
                      thumb == null
                          ? const ThumbFallback()
                          : ThumbImage(url: thumb, stored: item.thumbStored),
                      if (item.isVideo)
                        const Positioned(
                          right: 4,
                          bottom: 4,
                          child: Icon(Icons.play_arrow,
                              color: Colors.white, semanticLabel: '動画'),
                        ),
                    ]),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12)),
          if (showDir)
            Text(dir.isEmpty ? '（一番上）' : dir,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: dim),
          Text(
              [
                if (size != null) formatBytes(size),
                if (created != null) formatShortDate(created, now),
              ].join(' · '),
              style: dim),
          const SizedBox(height: 4),
          if (keeper)
            const Chip(
              avatar: Icon(Icons.check, size: 16, color: AppColors.accent),
              label: Text('残す'),
              visualDensity: VisualDensity.compact,
            )
          else if (!readOnly) ...[
            if (canTrash)
              SizedBox(
                height: 36,
                child: TextButton.icon(
                  onPressed: onTrash,
                  icon: const Icon(Icons.delete_outline,
                      size: 18, color: AppColors.danger),
                  label: const Text('ゴミ箱へ',
                      style: TextStyle(color: AppColors.danger)),
                ),
              ),
            SizedBox(
              height: 36,
              child: TextButton(
                  onPressed: onKeep, child: const Text('こちらを残す')),
            ),
          ],
        ],
      ),
    );
  }
}
