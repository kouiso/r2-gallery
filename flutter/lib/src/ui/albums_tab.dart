import 'package:flutter/material.dart';

import '../albums/album_detail_screen.dart';
import '../albums/album_states.dart';
import '../albums/album_widgets.dart';
import 'folder_browse_screen.dart';
import '../api/models.dart';
import '../state/app_state.dart';
import '../state/write_guard.dart';
import 'write_guard_notice.dart';
import 'media_tile.dart';
import 'theme.dart';

/// アルバムタブの表示切替。KMP 版 AlbumsSegment と同じ文言。
enum AlbumsSegment {
  albums('アルバム'),
  folders('フォルダ');

  const AlbumsSegment(this.label);
  final String label;
}

/// アルバムタブ: 「アルバム／フォルダ」の切替、アルバムの作成・名前変更・削除、フォルダ作成と閲覧。
/// 末尾の「その他」にゴミ箱の入口を置く（Kotlin 版 AlbumsTabContent と同じ、#167）。
class AlbumsTab extends StatefulWidget {
  final AppState app;
  final String lib;
  /// 表示中のタブか。裏にいる間はライブラリが変わっても取りに行かず、開いた時に取る
  final bool active;
  /// 「その他」のゴミ箱を押した時。null なら入口を出さない
  final VoidCallback? onOpenTrash;
  /// アルバム・フォルダを開く。シェルはアルバムタブの子画面として積み、閉じた時に Future を終える。
  /// null（シェルの外で単体表示する時）は画面を積んで開く
  final Future<void> Function(Album album)? onOpenAlbum;
  final Future<void> Function(String prefix)? onOpenFolder;
  const AlbumsTab(
      {super.key,
      required this.app,
      required this.lib,
      this.active = true,
      this.onOpenTrash,
      this.onOpenAlbum,
      this.onOpenFolder});

  @override
  State<AlbumsTab> createState() => _AlbumsTabState();
}

class _AlbumsTabState extends State<AlbumsTab> {
  late final AlbumsHomeState h = AlbumsHomeState(widget.app.api);
  AlbumsSegment segment = AlbumsSegment.albums;

  @override
  void initState() {
    super.initState();
    if (widget.active) h.load(widget.lib);
  }

  @override
  void didUpdateWidget(AlbumsTab old) {
    super.didUpdateWidget(old);
    if (widget.active && h.lib != widget.lib) h.load(widget.lib);
  }

  @override
  void dispose() {
    h.dispose();
    super.dispose();
  }

  bool get _libReadOnly =>
      widget.app.libraries.any((l) => l.id == widget.lib && l.readOnly);

  Future<void> _report(String? err) async {
    if (err != null && mounted) await showMessageDialog(context, '操作に失敗しました', err);
  }

  // アルバムの作成・変更・削除とフォルダ作成は、送る前に書き込みのガード（#145）を通す
  bool _canEdit() =>
      ensureWritable(context, widget.app, widget.lib, WriteAction.edit);

  Future<void> _createAlbum() async {
    if (!_canEdit()) return;
    final lib = widget.lib;
    final name = await showNameDialog(context, title: 'アルバムを作成');
    if (name == null) return;
    await _report(await h.create(lib, name));
  }

  Future<void> _createFolder() async {
    if (!_canEdit()) return;
    final lib = widget.lib;
    final name = await showNameDialog(context,
        title: 'フォルダを作成', placeholder: '新しいフォルダ名');
    if (name == null) return;
    await _report(await h.mkdir(lib, name));
  }

  Future<void> _albumMenu(Album a) async {
    if (!_canEdit()) return;
    final lib = widget.lib;
    final pick = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            title: const Text('名前を変更'),
            onTap: () => Navigator.of(ctx).pop('rename'),
          ),
          ListTile(
            title: const Text('削除',
                style: TextStyle(color: AppColors.danger)),
            onTap: () => Navigator.of(ctx).pop('delete'),
          ),
          const SizedBox(height: 24),
        ]),
      ),
    );
    if (!mounted) return;
    if (pick == 'rename') {
      final name = await showNameDialog(context,
          title: 'アルバム名を変更', initial: a.title, confirmLabel: '変更');
      if (name == null) return;
      await _report(await h.rename(lib, a.id, name));
    } else if (pick == 'delete') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('アルバムを削除しますか？'),
          content: Text('「${a.title}」を削除します。写真や動画は削除されません。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('キャンセル')),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('削除',
                  style: TextStyle(color: AppColors.danger)),
            ),
          ],
        ),
      );
      if (ok != true) return;
      await _report(await h.delete(lib, a.id));
    }
  }

  Future<void> _openAlbum(Album a) async {
    final lib = widget.lib;
    final open = widget.onOpenAlbum;
    if (open != null) {
      await open(a);
    } else {
      await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) =>
              AlbumDetailScreen(app: widget.app, lib: lib, album: a)));
    }
    // 中で外す・並び替え・ゴミ箱へをすると件数やカバーが変わるので取り直す
    if (mounted && h.lib == lib) h.load(lib);
  }

  Future<void> _openFolder(String prefix) async {
    final lib = widget.lib;
    final open = widget.onOpenFolder;
    if (open != null) {
      await open(prefix);
    } else {
      await openFolder(context, widget.app, lib, prefix);
    }
    if (mounted && h.lib == lib) h.load(lib);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: h,
      builder: (context, _) {
        final ro = _libReadOnly;
        final isAlbums = segment == AlbumsSegment.albums;
        final cards = <Widget>[];
        if (isAlbums) {
          if (!ro) {
            cards.add(_NewCard(label: 'アルバム作成', onTap: _createAlbum));
          }
          for (final a in h.albums) {
            cards.add(_AlbumCard(
              album: a,
              onTap: () => _openAlbum(a),
              // 取り込み処理が作ったアルバムや読み取り専用ライブラリでは改名・削除を出さない
              onLongPress: a.readOnly || ro ? null : () => _albumMenu(a),
            ));
          }
        } else {
          if (!ro) {
            cards.add(_NewCard(label: 'フォルダ作成', onTap: _createFolder));
          }
          for (final f in h.folders) {
            cards.add(FolderCard(name: folderName(f), onTap: () => _openFolder(f)));
          }
        }
        // ゴミ箱はアルバムの読み込みに失敗しても開けるよう、どの状態でも一覧の末尾に置く
        final trash = widget.onOpenTrash == null
            ? null
            : _TrashEntry(onTap: widget.onOpenTrash!);
        Widget content;
        if (h.loading && h.albums.isEmpty && h.folders.isEmpty) {
          content = Column(children: [
            const Expanded(child: Center(child: CircularProgressIndicator())),
            ?trash,
          ]);
        } else if (h.error != null && h.albums.isEmpty && h.folders.isEmpty) {
          content = ListView(children: [
            const SizedBox(height: 120),
            Text(h.error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textDim)),
            const SizedBox(height: 12),
            Center(
              child: FilledButton.tonal(
                  onPressed: () => h.load(widget.lib),
                  child: const Text('再試行')),
            ),
            const SizedBox(height: 24),
            ?trash,
          ]);
        } else {
          content = RefreshIndicator(
            onRefresh: () => h.load(widget.lib),
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                if (cards.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 120),
                      child: Center(
                        child: Text(isAlbums ? 'アルバムがありません' : 'フォルダがありません',
                            style: const TextStyle(color: AppColors.textDim)),
                      ),
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                    sliver: SliverGrid.count(
                      crossAxisCount: (MediaQuery.sizeOf(context).width / 160)
                          .floor()
                          .clamp(2, 8),
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      children: cards,
                    ),
                  ),
                if (trash != null) SliverToBoxAdapter(child: trash),
                const SliverToBoxAdapter(child: SizedBox(height: 16)),
              ],
            ),
          );
        }
        return Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: Row(children: [
              Expanded(
                child: SegmentedButton<AlbumsSegment>(
                  segments: [
                    for (final s in AlbumsSegment.values)
                      ButtonSegment(value: s, label: Text(s.label)),
                  ],
                  selected: {segment},
                  onSelectionChanged: (v) => setState(() => segment = v.first),
                ),
              ),
              if (!ro)
                IconButton(
                  tooltip: isAlbums ? 'アルバムを作成' : 'フォルダを作成',
                  icon: const Icon(Icons.add),
                  onPressed: isAlbums ? _createAlbum : _createFolder,
                ),
            ]),
          ),
          Expanded(child: content),
        ]);
      },
    );
  }
}

/// 「その他」の見出しとゴミ箱の行。大きさは Kotlin 版（ListItem 最小 64dp、角丸の面）に合わせる。
class _TrashEntry extends StatelessWidget {
  final VoidCallback onTap;
  const _TrashEntry({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(left: 4, bottom: 8),
            child: Text('その他',
                style: TextStyle(
                    color: AppColors.textDim,
                    fontSize: 14,
                    fontWeight: FontWeight.w700)),
          ),
          Material(
            color: AppColors.surfaceHigh,
            borderRadius: BorderRadius.circular(16),
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              minTileHeight: 64,
              leading: const Icon(Icons.delete_outline),
              title: const Text('ゴミ箱'),
              subtitle: const Text('移した項目の確認と復元',
                  style: TextStyle(color: AppColors.textDim, fontSize: 12)),
              trailing: const Icon(Icons.chevron_right),
              onTap: onTap,
            ),
          ),
        ],
      ),
    );
  }
}

class _NewCard extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _NewCard({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surfaceHigh,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.add, color: AppColors.textDim),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(fontSize: 12)),
        ]),
      ),
    );
  }
}

class _AlbumCard extends StatelessWidget {
  final Album album;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  const _AlbumCard(
      {required this.album, required this.onTap, required this.onLongPress});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(fit: StackFit.expand, children: [
          ColoredBox(
            color: AppColors.surfaceHigh,
            child: album.coverUrl != null
                ? ThumbImage(url: album.coverUrl!)
                : const Icon(Icons.photo_album_outlined,
                    size: 40, color: AppColors.textDim),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Colors.black87, Colors.transparent],
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(album.title,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  Text('${album.count} 件',
                      style: const TextStyle(
                          color: AppColors.textDim, fontSize: 11)),
                ],
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
