import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../api/models.dart';
import '../api/review_meta.dart';
import '../state/app_state.dart';
import '../state/write_guard.dart';
import '../viewer/device_export.dart';
import '../grid/day_label.dart';
import '../viewer/viewer_format.dart';
import 'media_tile.dart';
import 'theme.dart';
import 'trash_undo.dart';
import 'video_view.dart';
import 'write_guard_notice.dart';
import 'viewer_pages.dart';
import 'album_picker.dart';

/// オフライン保存（暗号化したアプリ内の保存）の口。持っている画面だけが渡す。
/// 渡されなければビューワーの「オフライン」ボタンは出さない。
class OfflineHooks {
  final bool Function(String lib, MediaItem item) isSaved;
  final Future<void> Function(String lib, MediaItem item) save;
  const OfflineHooks({required this.isSaved, required this.save});
}

/// #149 のオフライン保存につなぐ口。暗号化して端末に置けない環境（web）では出さない。
OfflineHooks? offlineHooksFor(AppState app) => app.offlineSupported
    ? OfflineHooks(
        isSaved: (lib, item) => app.isOffline(lib, item.key),
        save: (lib, item) async {
          await app.saveOffline(lib, [item]);
        },
      )
    : null;

/// 一覧からビューワーを開く。閉じた時にゴミ箱へ送っていたら「元に戻す」を出して [onChanged] を呼ぶ。
Future<void> openViewer(
  BuildContext context, {
  required AppState app,
  required String lib,
  required List<MediaItem> items,
  required int index,
  VoidCallback? onChanged,
  OfflineHooks? offline,
  VideoControllerFactory? videoFactory,
  Listenable? source,
  List<MediaItem> Function()? readItems,
  VoidCallback? onNearEnd,
  @visibleForTesting BaseCacheManager? imageCacheManager,
}) async {
  if (items.isEmpty) return;
  // ビューワーを閉じた後に出すので、開く前の画面のものを掴んでおく
  final messenger = ScaffoldMessenger.of(context);
  final receipt = await Navigator.of(context).push<TrashReceipt>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => ViewerScreen(
        app: app,
        lib: lib,
        items: items,
        initialIndex: index,
        offline: offline ?? offlineHooksFor(app),
        videoFactory: videoFactory,
        source: source,
        readItems: readItems,
        onNearEnd: onNearEnd,
        imageCacheManager: imageCacheManager,
      ),
    ),
  );
  if (receipt == null) return;
  onChanged?.call();
  await offerTrashUndo(messenger, app.api, [receipt], onRestored: onChanged);
}

/// 全画面ビューワー（KMP版 ViewerOverlay と同じ構成）。スワイプで前後、タップで上下バーの開閉、
/// 上バーに日時と「N件目」、写真のメモ、下の操作バー（情報／オフライン／端末に保存／アルバムへ／ゴミ箱へ）。
class ViewerScreen extends StatefulWidget {
  final AppState app;
  final String lib;
  final List<MediaItem> items;
  final int initialIndex;
  final OfflineHooks? offline;
  final VideoControllerFactory? videoFactory;

  /// 開いた後に一覧側で続きのページが読み込まれた時、末尾へ足すための口。
  /// 開いた時点の一覧だけだと、スワイプが読み込み済みの最後で止まってしまう。
  final Listenable? source;
  final List<MediaItem> Function()? readItems;

  /// 末尾の近くまで来た時に、一覧側へ続きの取得を頼む。
  final VoidCallback? onNearEnd;

  /// 原本のキャッシュの差し替え口。テストでだけ使う。
  @visibleForTesting
  final BaseCacheManager? imageCacheManager;

  const ViewerScreen({
    super.key,
    required this.app,
    required this.lib,
    required this.items,
    this.initialIndex = 0,
    this.offline,
    this.videoFactory,
    this.source,
    this.readItems,
    this.onNearEnd,
    this.imageCacheManager,
  }) : assert(items.length > 0);

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

/// 下の操作バーの高さ。動画の再生バーをこの上に出す。
const viewerActionBarHeight = 76.0;

class _ViewerScreenState extends State<ViewerScreen>
    with ZoomEdgePaging<ViewerScreen> {
  late final PageController _pager;
  late List<MediaItem> _items;
  late int _index;
  bool _chrome = true;
  bool _busy = false;
  bool _exporting = false;
  bool _saved = false;
  // 情報シートは開いた後に講評が届いても描き直せるよう、通知で渡す（#113）
  final _review = ValueNotifier<ReviewLoad>(const ReviewLoad.loading());
  int _metaRequest = 0;
  final DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    final start =
        widget.items[widget.initialIndex.clamp(0, widget.items.length - 1)];
    final media = playableMedia(widget.items);
    // 表示できるものが 1 件も無い時も落とさず、渡された一覧をそのまま出す
    _items = media.isEmpty ? widget.items : media;
    final at = _items.indexWhere((it) => sameMediaItem(it, start));
    _index = at < 0 ? 0 : at;
    _pager = PageController(initialPage: _index);
    _enterPage(_index);
    widget.source?.addListener(_appendLoaded);
    WidgetsBinding.instance.addPostFrameCallback((_) => _askMoreIfNearEnd());
  }

  @override
  void dispose() {
    widget.source?.removeListener(_appendLoaded);
    _pager.dispose();
    _review.dispose();
    super.dispose();
  }

  @override
  PageController get pager => _pager;
  @override
  int get pageIndex => _index;
  @override
  int get pageCount => _items.length;

  void _askMoreIfNearEnd() {
    if (mounted && _index >= _items.length - 3) widget.onNearEnd?.call();
  }

  /// 一覧が先頭から取り直されても並びが崩れんよう、今の末尾より後ろにあるものだけを足す
  void _appendLoaded() {
    final latest = widget.readItems?.call();
    if (latest == null || !mounted) return;
    final at = latest.indexWhere((it) => sameMediaItem(it, _items.last));
    if (at >= 0) {
      final added = playableMedia(latest.skip(at + 1));
      if (added.isNotEmpty) setState(() => _items = [..._items, ...added]);
    }
    // 読み込んだ分が全部メディア以外でも、末尾の近くなら続きを頼み直す
    scheduleMicrotask(_askMoreIfNearEnd);
  }

  MediaItem get _item => _items[_index];
  String _libOf(MediaItem it) => it.lib ?? widget.lib;

  bool get _readOnly {
    final l = _libOf(_item);
    for (final x in widget.app.libraries) {
      if (x.id == l) return x.readOnly;
    }
    return false;
  }

  void _onPage(int i) {
    setState(() {
      resetEdgePaging();
      _enterPage(i);
    });
    _askMoreIfNearEnd();
  }

  void _enterPage(int i) {
    _index = i;
    final it = _items[i];
    final off = widget.offline;
    _saved = off != null && off.isSaved(_libOf(it), it);
    _loadReview();
  }

  // 講評が無い（null）と取れなかった（例外）を分ける。KMP 版は失敗を黙って流していて、
  // 「審査メモが出ない」の原因が講評なしなのか取得失敗なのか画面から分からなかった（#113）
  void _loadReview() {
    final it = _item;
    // A→B→A と戻っても、前の A の応答で新しい取得結果を上書きしない
    final request = ++_metaRequest;
    _review.value = const ReviewLoad.loading();
    widget.app.api.meta(_libOf(it), it.key).then((m) {
      if (mounted && _metaRequest == request) _review.value = ReviewLoad.done(m);
    }, onError: (Object e) {
      debugPrint('meta failed: $e');
      if (mounted && _metaRequest == request) _review.value = const ReviewLoad.failed();
    });
  }

  // 操作バーに被せると2秒間ボタンが押せなくなるので、バーの上に浮かせる
  void _flash(String msg) {
    final bottom = MediaQuery.of(context).padding.bottom;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.fromLTRB(16, 0, 16, viewerActionBarHeight + bottom + 28),
      ));
  }

  Future<void> _alert(String msg) => showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(msg),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(c).pop(), child: const Text('OK')),
          ],
        ),
      );

  Future<void> _trash() async {
    if (_busy) return;
    final it = _item;
    final l = _libOf(it);
    if (!ensureWritable(context, widget.app, l, WriteAction.trash)) return;
    setState(() => _busy = true);
    try {
      final key = await widget.app.api.trash(l, it.key);
      if (!mounted) return;
      _busy = false;
      // 確認は挟まず即ゴミ箱へ。閉じた先で「元に戻す」を出す（KMP版と同じ）
      Navigator.of(context).pop(key.isEmpty ? null : TrashReceipt(l, key));
    } on ApiError catch (e) {
      debugPrint('trash failed: $e');
      if (!mounted) return;
      setState(() => _busy = false);
      await _alert('ゴミ箱への移動に失敗しました');
    }
  }

  Future<void> _addToAlbum() async {
    final it = _item;
    final l = _libOf(it);
    final res = await pickAlbumAndAdd(context, widget.app,
        lib: l, targets: [(l, it.key)]);
    if (res == null || !mounted) return;
    if (res.ok) {
      _flash('アルバムに追加しました');
    } else {
      await _alert(res.error ?? 'アルバムへの追加に失敗しました');
    }
  }

  Future<void> _export() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    String msg;
    try {
      await widget.app.exportToDevice(_item, lib: widget.lib);
      msg = '端末に保存しました';
    } on DeviceExportError catch (e) {
      msg = e.message;
    } on ApiError catch (e) {
      debugPrint('export failed: $e');
      msg = '端末への保存に失敗しました';
    }
    if (!mounted) return;
    setState(() => _exporting = false);
    await _alert(msg);
  }

  Future<void> _saveOffline() async {
    final off = widget.offline;
    if (off == null) return;
    if (_saved) {
      _flash('オフライン保存済みです');
      return;
    }
    await off.save(_libOf(_item), _item);
    if (!mounted) return;
    setState(() => _saved = true);
    _flash('オフライン保存に追加しました');
  }

  void _showInfo() {
    final it = _item;
    final l = _libOf(it);
    var libTitle = l;
    for (final x in widget.app.libraries) {
      if (x.id == l) libTitle = x.title;
    }
    final slash = it.key.lastIndexOf('/');
    final folder = slash < 0 ? '' : it.key.substring(0, slash);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      builder: (_) => ValueListenableBuilder<ReviewLoad>(
        valueListenable: _review,
        builder: (_, r, _) => ViewerInfoSheet(
          name: it.name,
          isVideo: it.isVideo,
          sizeText: it.size == null ? null : formatBytes(it.size!),
          addedAt:
              it.createdAt == null ? null : formatDateTime(it.createdAt!, _now),
          location: folder.isEmpty ? libTitle : '$libTitle / $folder',
          note: (it.note ?? '').trim().isEmpty ? null : it.note,
          review: r.meta,
          reviewLoading: r.loading,
          reviewFailed: r.failed,
          onRetryReview: _loadReview,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final it = _item;
    final bottomSafe = MediaQuery.of(context).padding.bottom;
    return PopScope(
      // ゴミ箱への移動中に閉じると、移動済みでも「元に戻す」が出せなくなる
      canPop: !_busy,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            wrapEdgePaging(PageView.builder(
              controller: _pager,
              physics: edgePagingPhysics,
              itemCount: items.length,
              onPageChanged: _onPage,
              itemBuilder: (context, i) {
                final x = items[i];
                final key = ValueKey('${x.lib}:${x.key}');
                if (x.isVideo) {
                  // 動画は表示中のページだけがコントローラを持つ。隣は先読みしない（#141）
                  if (i != _index) return _VideoPoster(key: key, item: x);
                  return VideoView(
                    key: ValueKey('video-${x.lib}:${x.key}'),
                    url: x.url,
                    active: true,
                    bottomInset:
                        _chrome ? viewerActionBarHeight + bottomSafe : 0,
                    controllerFactory: widget.videoFactory,
                    onControlsVisibleChange: (v) {
                      if (mounted && _chrome != v) setState(() => _chrome = v);
                    },
                  );
                }
                if (!x.isImage) {
                  return GestureDetector(
                    onTap: () => setState(() => _chrome = !_chrome),
                    child: const Center(
                        child: Icon(Icons.insert_drive_file,
                            size: 64, color: AppColors.textDim)),
                  );
                }
                return ViewerImagePage(
                  key: key,
                  item: x,
                  onToggleControls: () => setState(() => _chrome = !_chrome),
                  onViewport: (z, l, r) => onViewport(i, z, l, r),
                  cacheManager: widget.imageCacheManager,
                );
              },
            )),
            if (_chrome) ...[
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _topBar(it),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  // 動画ではメモを出さない（再生バーと重なるため。全文は情報シート）
                  if (!it.isVideo && (it.note ?? '').trim().isNotEmpty)
                    _memo(it.note!),
                  _actionBar(bottomSafe),
                ]),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _topBar(MediaItem it) {
    final title =
        it.createdAt == null ? it.name : formatDateTime(it.createdAt!, _now);
    return Container(
      color: const Color(0x8C000000),
      child: SafeArea(
        bottom: false,
        child: Row(children: [
          IconButton(
            tooltip: '閉じる',
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: _busy ? null : () => Navigator.of(context).maybePop(),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600)),
                  Text('${_index + 1}件目 · ${it.name}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Color(0xCCFFFFFF), fontSize: 12)),
                ],
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _memo(String note) => Container(
        width: double.infinity,
        color: const Color(0x8C000000),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Text(note,
            key: const ValueKey('viewer-memo'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Color(0xEBFFFFFF), fontSize: 14)),
      );

  Widget _actionBar(double bottomSafe) {
    final actions = <Widget>[
      _ViewerAction(icon: Icons.info_outline, label: '情報', onTap: _showInfo),
      if (widget.offline != null)
        _saved
            ? _ViewerAction(
                icon: Icons.download_done,
                label: '保存済み',
                accent: true,
                onTap: _saveOffline)
            : _ViewerAction(
                icon: Icons.download, label: 'オフライン', onTap: _saveOffline),
      if (widget.app.deviceExportSupported)
        _ViewerAction(
            icon: Icons.save_alt,
            label: _exporting ? '保存中…' : '端末に保存',
            onTap: _exporting ? null : _export),
      // 読み取り専用のライブラリでは書き換える操作を出さない
      if (!_readOnly) ...[
        _ViewerAction(
            icon: Icons.add_to_photos_outlined,
            label: 'アルバムへ',
            onTap: _addToAlbum),
        _ViewerAction(
            icon: Icons.delete_outline,
            label: 'ゴミ箱へ',
            danger: true,
            onTap: _busy ? null : _trash),
      ],
    ];
    return Container(
      color: const Color(0x8C000000),
      padding: EdgeInsets.only(bottom: bottomSafe),
      child: SizedBox(
        height: viewerActionBarHeight,
        child: Row(children: [for (final a in actions) Expanded(child: a)]),
      ),
    );
  }
}

class _ViewerAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool danger;
  final bool accent;
  const _ViewerAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
    this.accent = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = onTap == null
        ? Colors.white38
        : danger
            ? AppColors.danger
            : accent
                ? AppColors.accent
                : Colors.white;
    return InkWell(
      onTap: onTap,
      child: Semantics(
        button: true,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color),
            const SizedBox(height: 4),
            Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(color: color, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

/// 講評の取得状態。取得中・届いた（講評なしの null を含む）・取れなかった、の3つ。
class ReviewLoad {
  final bool loading;
  final bool failed;
  final ReviewMeta? meta;
  const ReviewLoad.loading()
      : loading = true,
        failed = false,
        meta = null;
  const ReviewLoad.done(this.meta)
      : loading = false,
        failed = false;
  const ReviewLoad.failed()
      : loading = false,
        failed = true,
        meta = null;
}

/// 情報シート。モデルにある値だけ出す（無いものは行ごと出さない）。
class ViewerInfoSheet extends StatelessWidget {
  final String name;
  final bool isVideo;
  final String? sizeText;
  final String? addedAt;
  final String location;
  final String? note;
  final ReviewMeta? review;
  final bool reviewLoading;
  final bool reviewFailed;
  final VoidCallback? onRetryReview;

  const ViewerInfoSheet({
    super.key,
    required this.name,
    required this.isVideo,
    required this.location,
    this.sizeText,
    this.addedAt,
    this.note,
    this.review,
    this.reviewLoading = false,
    this.reviewFailed = false,
    this.onRetryReview,
  });

  String _score(double? x) {
    if (x == null) return '-';
    return x == x.roundToDouble() ? x.toStringAsFixed(0) : x.toString();
  }

  @override
  Widget build(BuildContext context) {
    final m = review;
    final reviewLines = <String>[
      if (m != null) ...[
        if (m.intentComment != null) '意図: ${m.intentComment}',
        if (m.directorScore != null) '総合スコア: ${_score(m.directorScore)}',
        if (m.directorComment != null) '講評: ${m.directorComment}',
        for (final c in m.criteria) ...[
          '・${c.key}: ${_score(c.directorScore ?? c.panelScore)}${c.veto ? '（veto）' : ''}'
              '${c.directorScore != null && c.panelScore != null ? '（パネル: ${_score(c.panelScore)}）' : ''}',
          if ((c.comment ?? '').trim().isNotEmpty) '  ${c.comment}',
        ],
      ],
    ];
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('情報',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            _row(isVideo ? Icons.videocam_outlined : Icons.image_outlined, name,
                sizeText),
            if (addedAt != null) _row(Icons.schedule, addedAt!, '追加日時'),
            _row(Icons.folder_outlined, location, '保存場所'),
            if (note != null) _row(Icons.notes, note!, 'メモ'),
            if (m != null)
              _row(
                  Icons.rate_review_outlined,
                  '${m.label} · ${m.verdict} · ${m.round}回目',
                  reviewLines.isEmpty ? null : reviewLines.join('\n'))
            else if (reviewFailed)
              Row(children: [
                Expanded(
                    child: _row(Icons.error_outline, '講評を取得できませんでした',
                        '通信を確かめて、もう一度読み込んでください')),
                TextButton(
                    onPressed: onRetryReview, child: const Text('再読み込み')),
              ])
            else if (reviewLoading)
              _row(Icons.rate_review_outlined, '講評を確認中…', null)
            else
              _row(Icons.rate_review_outlined, '講評はありません', null),
          ],
        ),
      ),
    );
  }

  Widget _row(IconData icon, String primary, String? secondary) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, color: AppColors.textDim),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(primary, style: const TextStyle(fontSize: 15)),
                if (secondary != null)
                  Text(secondary,
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.textDim)),
              ],
            ),
          ),
        ]),
      );
}

/// 表示していない動画ページ。コントローラを作らず、保存済みのサムネだけ見せる。
class _VideoPoster extends StatelessWidget {
  final MediaItem item;
  const _VideoPoster({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    final thumb = item.thumbUrl;
    return ColoredBox(
      color: Colors.black,
      child: thumb != null && item.thumbStored
          ? CachedNetworkImage(
              imageUrl: thumb,
              cacheKey: thumbCacheKey(thumb),
              cacheManager: thumbCache,
              fit: BoxFit.contain,
              fadeInDuration: Duration.zero,
              errorWidget: (_, _, _) => const SizedBox.shrink(),
            )
          : const SizedBox.shrink(),
    );
  }
}
