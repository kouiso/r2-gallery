import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../api/models.dart';
import 'media_tile.dart';
import 'theme.dart';

// #141（4d4d12d）の PlayerScreen にあった画像ページとページ送りの部品。
// ビューワー（#147 の ViewerScreen）に一本化した時に、ここへ移した。

/// ビューワーで開いた原本のディスクキャッシュ。サムネ用と分けるのは、原本は 1 枚数MB あり、
/// 件数だけで上限を切る cache manager に 5000 件も積むと数十GB になるため。
/// 既定の 200 件も容量の上限が無く、重い原本では膨らみすぎる。
final viewerCache = CacheManager(
  Config(
    'r2g.viewer',
    stalePeriod: const Duration(days: 7),
    maxNrOfCacheObjects: 40,
  ),
);

/// ビューワーの画像を decode する幅（px）。原寸だと 12MP で ~48MB になりメモリキャッシュから
/// すぐ追い出されるので、通常表示は画面幅の 2 倍に抑える（2 倍拡大までは等倍の密度で見える）。
/// それ以上の拡大では足りなくなるので、ViewerImagePage が原寸を重ねる。幅が取れない時は null。
@visibleForTesting
int? viewerDecodeWidth(double logicalWidth, double devicePixelRatio) {
  final px = logicalWidth * devicePixelRatio * 2;
  if (!px.isFinite || px <= 0) return null;
  return px.round();
}

bool sameMediaItem(MediaItem a, MediaItem b) => a.lib == b.lib && a.key == b.key;

/// 画像と動画だけ。それ以外はビューワーで開いても壊れた画像になるだけなので、スワイプの対象にしない
List<MediaItem> playableMedia(Iterable<MediaItem> items) =>
    [for (final it in items) if (it.isImage || it.isVideo) it];

/// 拡大した画像の端から外へ引いた時だけ、止めてあるページ送りを手で動かす。
/// 拡大中は 1 本指のドラッグを画像のパンに使うので PageView のスクロールは止める。
mixin ZoomEdgePaging<T extends StatefulWidget> on State<T> {
  PageController get pager;
  int get pageIndex;
  int get pageCount;

  // 拡大中は 1 本指のドラッグを画像のパンに使うので、ページ送りを止める
  bool zoomed = false;
  // 拡大した画像の左右の端に着いているか。着いた端から外へ引いた時だけページ送りへ回す
  bool atLeft = true;
  bool atRight = true;
  int _pointers = 0;
  VelocityTracker? _velocity;
  // ページ送りを止めている間、端で外へ引いたドラッグを手でページに伝える。
  // null の間は伝えていない。値は引き始めたページ
  int? _dragOrigin;

  ScrollPhysics? get edgePagingPhysics =>
      zoomed ? const NeverScrollableScrollPhysics() : null;

  /// ページが変わった時に呼ぶ。新しいページは等倍から始まる。
  void resetEdgePaging() {
    zoomed = false;
    atLeft = true;
    atRight = true;
  }

  /// 表示中の画像ページから拡大状態を受け取る。
  void onViewport(int page, bool z, bool l, bool r) {
    if (page != pageIndex) return;
    atLeft = l;
    atRight = r;
    if (z != zoomed) setState(() => zoomed = z);
  }

  Widget wrapEdgePaging(Widget pageView) => Listener(
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _onPointerEnd,
        onPointerCancel: _onPointerEnd,
        child: pageView,
      );

  void _onPointerDown(PointerDownEvent e) {
    _pointers++;
    if (_pointers == 1) _velocity = VelocityTracker.withKind(e.kind);
    _velocity?.addPosition(e.timeStamp, e.position);
    // 指が増えたらピンチなので、引いていたページ送りは中途半端な位置で放さず収める
    if (_pointers > 1) _settleEdgeDrag(0);
  }

  void _onPointerMove(PointerMoveEvent e) {
    _velocity?.addPosition(e.timeStamp, e.position);
    if (_pointers != 1 || !pager.hasClients) return;
    final dx = e.delta.dx;
    var origin = _dragOrigin;
    if (origin == null) {
      final outward = (atLeft && dx > 0) || (atRight && dx < 0);
      if (!zoomed || !outward || dx.abs() < e.delta.dy.abs()) return;
      origin = _dragOrigin = pageIndex;
    }
    final pos = pager.position;
    final w = pos.viewportDimension;
    final base = origin * w;
    // 画像が端に着いている側へだけ動かす。逆へ戻した時は元のページの位置で止まる
    final low = base - (atLeft ? w : 0);
    final high = base + (atRight ? w : 0);
    final next = (pos.pixels - dx)
        .clamp(low, high)
        .clamp(pos.minScrollExtent, pos.maxScrollExtent)
        .toDouble();
    pos.jumpTo(next);
  }

  void _onPointerEnd(PointerEvent e) {
    _pointers = _pointers > 0 ? _pointers - 1 : 0;
    if (_pointers > 0) return;
    final vx = e is PointerUpEvent
        ? (_velocity?.getVelocity().pixelsPerSecond.dx ?? 0.0)
        : 0.0;
    _velocity = null;
    _settleEdgeDrag(vx);
  }

  void _settleEdgeDrag(double vx) {
    final origin = _dragOrigin;
    if (origin == null) return;
    _dragOrigin = null;
    if (!pager.hasClients) return;
    final offset = (pager.page ?? origin.toDouble()) - origin;
    var target = origin;
    // 指が右へ動いている(vx>0)のは前のページへ戻す向き
    final flung = vx.abs() > 700 && (vx < 0) == (offset > 0);
    if (offset != 0 && (offset.abs() > 0.3 || flung)) {
      target = origin + (offset > 0 ? 1 : -1);
    }
    unawaited(pager.animateToPage(
      target.clamp(0, pageCount - 1),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    ));
  }
}

class ViewerImagePage extends StatefulWidget {
  final MediaItem item;
  final VoidCallback onToggleControls;
  final void Function(bool zoomed, bool atLeft, bool atRight) onViewport;

  /// 原本のキャッシュ。テストでだけ差し替える（実機の cache manager はテストでは応答しない）。
  final BaseCacheManager? cacheManager;
  const ViewerImagePage({
    super.key,
    required this.item,
    required this.onToggleControls,
    required this.onViewport,
    this.cacheManager,
  });

  @override
  State<ViewerImagePage> createState() => _ViewerImagePageState();
}

/// 端に着いたとみなす誤差（論理px）。パンの最後は 1px に満たない端数で止まることがある
const _edgeSlop = 1.0;

class _ViewerImagePageState extends State<ViewerImagePage> {
  final TransformationController _tc = TransformationController();
  bool _zoomed = false;
  bool _atLeft = true;
  bool _atRight = true;
  // 通常の decode 幅では 2 倍拡大までしか精細に見えんので、それを超えた間だけ原寸を重ねる
  bool _sharp = false;

  @override
  void initState() {
    super.initState();
    _tc.addListener(_onTransform);
  }

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  void _onTransform() {
    final m = _tc.value;
    final scale = m.getMaxScaleOnAxis();
    final zoomed = scale > 1.01;
    // 出し入れの境目をずらして、2 倍付近で重ねたり外したりを繰り返さんようにする
    final sharp = _sharp ? scale > 1.5 : scale > 2;
    if (sharp != _sharp && mounted) setState(() => _sharp = sharp);
    // 動かせる範囲は子（画面幅）の中なので、平行移動量が両端に着いたかで端を判定する
    final w = context.size?.width;
    final tx = m.getTranslation().x;
    final atLeft = !zoomed || tx >= -_edgeSlop;
    final atRight = !zoomed || (w != null && tx <= w - w * scale + _edgeSlop);
    if (zoomed == _zoomed && atLeft == _atLeft && atRight == _atRight) return;
    _zoomed = zoomed;
    _atLeft = atLeft;
    _atRight = atRight;
    widget.onViewport(zoomed, atLeft, atRight);
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final thumb = item.thumbUrl;
    const spinner = Center(child: CircularProgressIndicator());
    return GestureDetector(
      onTap: widget.onToggleControls,
      child: InteractiveViewer(
        transformationController: _tc,
        minScale: 0.5,
        maxScale: 5,
        child: Center(
          child: Stack(
            alignment: Alignment.center,
            children: [
              CachedNetworkImage(
            imageUrl: item.url,
            // 署名URLは 1〜2 時間で変わるので、パスだけで引いて再署名後も同じ原本に当てる
            cacheKey: thumbCacheKey(item.url),
            cacheManager: widget.cacheManager ?? viewerCache,
            fit: BoxFit.contain,
            memCacheWidth: viewerDecodeWidth(
                MediaQuery.sizeOf(context).width,
                MediaQuery.devicePixelRatioOf(context)),
            fadeInDuration: Duration.zero,
            // 保存済みの軽いサムネは一覧で引いてあるはずなので、原本が来るまでそれを見せる。
            // 未保存のサムネ URL は原本を返すので使わない（二重に落とすだけになる）
            placeholder: (_, _) => thumb != null && item.thumbStored
                ? CachedNetworkImage(
                    imageUrl: thumb,
                    cacheKey: thumbCacheKey(thumb),
                    cacheManager: thumbCache,
                    fit: BoxFit.contain,
                    fadeInDuration: Duration.zero,
                    placeholder: (_, _) => spinner,
                    errorWidget: (_, _, _) => spinner,
                  )
                : spinner,
            errorWidget: (_, _, _) => const Icon(Icons.broken_image,
                size: 64, color: AppColors.textDim),
          ),
              if (_sharp)
                // 下の画像を見せたまま、読み終えた所で原寸に差し替える（待つ間にサムネへ戻さない）
                CachedNetworkImage(
                  imageUrl: item.url,
                  cacheKey: thumbCacheKey(item.url),
                  cacheManager: widget.cacheManager ?? viewerCache,
                  fit: BoxFit.contain,
                  fadeInDuration: Duration.zero,
                  placeholder: (_, _) => const SizedBox.shrink(),
                  errorWidget: (_, _, _) => const SizedBox.shrink(),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
