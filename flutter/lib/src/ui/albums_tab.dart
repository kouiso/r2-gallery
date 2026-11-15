import 'dart:math' as math;

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

// 寸法・色・文字は板「現行 · アルバムタブ」（doc/design/project/Albums.dc.html）の値。
// 板は行の高さと字間を指定していないので、板の書体 Noto Sans JP で描いた時の行の高さ
// （14→20、12→17、13→19、16→24）と字間 0 を明示する。指定しないと M3 の既定（行 1.43〜1.5 倍、
// 字間 0.25〜0.5）が乗って板とずれる
const double _cardRadius = 12;
const double _gridGap = 12;

const _albumTitleStyle = TextStyle(
    color: AppColors.textPrimary,
    fontSize: 14,
    fontWeight: FontWeight.w600,
    height: 20 / 14,
    letterSpacing: 0);
const _captionStyle = TextStyle(
    color: AppColors.textDim,
    fontSize: 12,
    fontWeight: FontWeight.w400,
    height: 17 / 12,
    letterSpacing: 0);
const _createLabelStyle = TextStyle(
    color: AppColors.textDim,
    fontSize: 14,
    fontWeight: FontWeight.w400,
    height: 20 / 14,
    letterSpacing: 0);
const _sectionStyle = TextStyle(
    color: AppColors.textDim,
    fontSize: 13,
    fontWeight: FontWeight.w600,
    height: 19 / 13,
    letterSpacing: 0);
const _rowTitleStyle = TextStyle(
    color: AppColors.textPrimary,
    fontSize: 16,
    fontWeight: FontWeight.w400,
    height: 24 / 16,
    letterSpacing: 0);

/// 行の箱を [style] の高さに固定する。日本語は代替フォントで描かれ、そのフォントの上下の張り出しで
/// 行が 1px ほど伸びる（Web 版で実測）ので、高さを書いただけでは板の寸法にならない
StrutStyle _strutOf(TextStyle style) =>
    StrutStyle.fromTextStyle(style, forceStrutHeight: true);

/// 「アルバム／フォルダ」切替の見た目。選択中は金の 20% の地に金の文字、他は地なしで本文色。
/// 箱は高さ 42（中 40 + 枠 1px ずつ）・角丸 20。押せる高さは 48 を保つ。
final ButtonStyle _segmentStyle = SegmentedButton.styleFrom(
  backgroundColor: Colors.transparent,
  foregroundColor: AppColors.textPrimary,
  selectedBackgroundColor: AppColors.accentSoft,
  selectedForegroundColor: AppColors.accent,
  side: const BorderSide(color: AppColors.border),
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
  // SegmentedButton は枠を「文字の大きさ + 上下の余白」の高さで描く。行の箱を文字と同じ 14 にして
  // 上下 14 ずつ取ると、ボタンも枠も 42 で揃う（M3 の既定は 40）
  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
  // PC のブラウザは詰めた密度が既定で、そのままだと箱が縮む
  visualDensity: VisualDensity.standard,
  tapTargetSize: MaterialTapTargetSize.padded,
).copyWith(
  textStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
      fontSize: 14,
      height: 1,
      fontWeight: states.contains(WidgetState.selected)
          ? FontWeight.w600
          : FontWeight.w400,
      letterSpacing: 0)),
);

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
            cards.add(_CreateTile(label: 'アルバム作成', onTap: _createAlbum));
          }
          for (final a in h.albums) {
            // 作成中（id 待ち）のアルバムは開く・書き換えると仮の id で送ってしまうので、何もしない
            final pending = h.isPending(a.id);
            cards.add(_AlbumCard(
              album: a,
              onTap: pending ? () {} : () => _openAlbum(a),
              // 取り込み処理が作ったアルバムや読み取り専用ライブラリでは改名・削除を出さない
              onLongPress:
                  a.readOnly || ro || pending ? null : () => _albumMenu(a),
            ));
          }
        } else {
          if (!ro) {
            // フォルダ側は板に描かれていないので、作成カードもフォルダのカードも今の見た目のまま
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
          final cols =
              (MediaQuery.sizeOf(context).width / 160).floor().clamp(2, 8);
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
                else if (isAlbums)
                  // カバーは正方形で、名前と件数はその下。行の高さは文字の大きさ（端末の文字サイズ設定）で
                  // 変わるので、高さを決め打ちするグリッドではなく行ごとに中身の高さで並べる
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    sliver: SliverList.separated(
                      itemCount: (cards.length / cols).ceil(),
                      separatorBuilder: (_, _) =>
                          const SizedBox(height: _gridGap),
                      itemBuilder: (_, row) => Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (var c = 0; c < cols; c++) ...[
                            if (c > 0) const SizedBox(width: _gridGap),
                            Expanded(
                              child: row * cols + c < cards.length
                                  ? cards[row * cols + c]
                                  : const SizedBox.shrink(),
                            ),
                          ],
                        ],
                      ),
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    sliver: SliverGrid.count(
                      crossAxisCount: cols,
                      mainAxisSpacing: _gridGap,
                      crossAxisSpacing: _gridGap,
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
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
            child: Row(children: [
              Expanded(
                child: SegmentedButton<AlbumsSegment>(
                  style: _segmentStyle,
                  expandedInsets: EdgeInsets.zero,
                  // 既定のチェックは 18 で文字との間が 8。板は 16 と 6 なので、ラベル側で描く
                  showSelectedIcon: false,
                  segments: [
                    for (final s in AlbumsSegment.values)
                      ButtonSegment(
                        value: s,
                        label: _SegmentLabel(s.label, selected: s == segment),
                      ),
                  ],
                  selected: {segment},
                  onSelectionChanged: (v) => setState(() => segment = v.first),
                ),
              ),
              if (!ro) ...[
                const SizedBox(width: 8),
                IconButton(
                  tooltip: isAlbums ? 'アルバムを作成' : 'フォルダを作成',
                  icon: const Icon(Icons.add),
                  onPressed: isAlbums ? _createAlbum : _createFolder,
                ),
              ],
            ]),
          ),
          Expanded(child: content),
        ]);
      },
    );
  }
}

class _SegmentLabel extends StatelessWidget {
  final String label;
  final bool selected;
  const _SegmentLabel(this.label, {required this.selected});

  @override
  Widget build(BuildContext context) {
    final text = Text(label, maxLines: 1, overflow: TextOverflow.ellipsis);
    if (!selected) return text;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      // チェック 16 は行の箱 14 より高い。箱からはみ出して描かせ、選択中だけ区切りが高くならないようにする
      const SizedBox(
        width: 16,
        height: 14,
        child: OverflowBox(
          minHeight: 16,
          maxHeight: 16,
          child: Icon(Icons.check, size: 16),
        ),
      ),
      const SizedBox(width: 6),
      Flexible(child: text),
    ]);
  }
}

/// 「その他」の見出しとゴミ箱の行。板のとおり面（カード）に載せず、画面の端から端までの行にする。
class _TrashEntry extends StatelessWidget {
  final VoidCallback onTap;
  const _TrashEntry({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
          child: Text('その他',
              style: _sectionStyle, strutStyle: _strutOf(_sectionStyle)),
        ),
        ListTile(
          // 板: 最小 56、上下 10・左右 16、アイコン 24、アイコンと文字の間 16。
          // 密度の既定は端末の種類で変わるので、行が縮まないよう固定する
          visualDensity: VisualDensity.standard,
          minTileHeight: 56,
          minVerticalPadding: 10,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          horizontalTitleGap: 16,
          minLeadingWidth: 24,
          leading: const Icon(Icons.delete_outline,
              size: 24, color: AppColors.textPrimary),
          title: Text('ゴミ箱',
              style: _rowTitleStyle, strutStyle: _strutOf(_rowTitleStyle)),
          subtitle: Text('移した項目の確認と復元',
              style: _captionStyle, strutStyle: _strutOf(_captionStyle)),
          trailing: const Icon(Icons.chevron_right,
              size: 24, color: AppColors.textDim),
          onTap: onTap,
        ),
      ],
    );
  }
}

/// アルバムの作成タイル。カバーと同じ大きさの正方形で、破線の枠。
class _CreateTile extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _CreateTile({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: CustomPaint(
        foregroundPainter: const _DashedBorderPainter(),
        child: Material(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(_cardRadius),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child:
                Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Icon(Icons.add, size: 28, color: AppColors.textDim),
              const SizedBox(height: 8),
              Text(label,
                  style: _createLabelStyle,
                  strutStyle: _strutOf(_createLabelStyle)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// 角丸 12 の破線の枠（1px、3 描いて 2 空ける。板をブラウザで描いた時の刻み）。
/// Flutter の枠線には破線が無いので、輪郭を刻んで描く。
class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter();

  static const double _dash = 3;
  static const double _gap = 2;

  @override
  void paint(Canvas canvas, Size size) {
    // 線の中心を半分内側へ寄せ、枠が箱の外にはみ出さないようにする
    final outline = Path()
      ..addRRect(RRect.fromRectAndRadius((Offset.zero & size).deflate(0.5),
          const Radius.circular(_cardRadius - 0.5)));
    final paint = Paint()
      ..color = AppColors.border
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final m in outline.computeMetrics()) {
      for (var d = 0.0; d < m.length; d += _dash + _gap) {
        canvas.drawPath(m.extractPath(d, math.min(d + _dash, m.length)), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter oldDelegate) => false;
}

/// フォルダの作成カード。フォルダ側は板が無いので、隣の [FolderCard] と揃う今の見た目を保つ。
class _NewCard extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _NewCard({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surfaceHigh,
      borderRadius: BorderRadius.circular(AppRadius.medium),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.medium),
        onTap: onTap,
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.add, color: AppColors.textDim),
          const SizedBox(height: 4),
          Text(label, style: AppText.caption),
        ]),
      ),
    );
  }
}

/// アルバム 1 件。正方形のカバーの下に名前と件数を置く。名前の所を押しても開ける。
class _AlbumCard extends StatelessWidget {
  final Album album;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  const _AlbumCard(
      {required this.album, required this.onTap, required this.onLongPress});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // カバーと文字の間のすき間でも反応させる
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(_cardRadius),
              child: ColoredBox(
                color: AppColors.surfaceHigh,
                child: album.coverUrl != null
                    ? ThumbImage(url: album.coverUrl!)
                    : const Icon(Icons.photo_album_outlined,
                        size: 40, color: AppColors.textDim),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(album.title,
              style: _albumTitleStyle,
              strutStyle: _strutOf(_albumTitleStyle),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: 2),
          Text('${album.count} 件',
              style: _captionStyle, strutStyle: _strutOf(_captionStyle)),
        ],
      ),
    );
  }
}
