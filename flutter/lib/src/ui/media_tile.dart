import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter/material.dart';

import '../api/models.dart';
import '../grid/selection_widgets.dart';
import 'theme.dart';

/// 署名URLのクエリ（e=期限, s=署名）は1〜2時間で変わるので、
/// キャッシュはパス（ホスト/種別/ライブラリ/キー）だけで引く。KMP 版の Coil より長く効かせるため。
/// サムネ未生成の画像は /t/ が原本を返すので、生成後に軽いサムネへ切り替わるよう別キーにする。
String thumbCacheKey(String url, {bool stored = true}) {
  final q = url.indexOf('?');
  final path = q < 0 ? url : url.substring(0, q);
  return stored ? path : '$path#orig';
}

/// 一覧のサムネ用ディスクキャッシュ。既定の200件では1ライブラリ分も持てず、
/// 切り替えて戻るたびに取り直しになるので、KMP 版の Coil 並みに広く取る。
final thumbCache = CacheManager(
  Config(
    'r2g.thumbs',
    stalePeriod: const Duration(days: 30),
    maxNrOfCacheObjects: 5000,
  ),
);

/// 一覧・アルバムで共通のサムネ表示。セルの寸法で decode し、ディスクキャッシュから引く。
class ThumbImage extends StatelessWidget {
  final String url;
  final bool stored;
  const ThumbImage({super.key, required this.url, this.stored = true});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        // 原寸で decode するとメモリキャッシュがすぐ溢れて切替のたびに取り直しになる。
        // 幅だけ指定で縦横比は保たれるので、横長でもセルを埋めるよう 2 倍まで許す
        final px =
            (c.biggest.shortestSide *
                    MediaQuery.devicePixelRatioOf(context) *
                    2)
                .round();
        return CachedNetworkImage(
          // 一覧を取り直して署名URLが新しくなったら、前回失敗したセルも新しいURLで取り直させる
          key: ValueKey(url),
          imageUrl: url,
          cacheKey: thumbCacheKey(url, stored: stored),
          cacheManager: thumbCache,
          memCacheWidth: px > 0 ? px : null,
          fit: BoxFit.cover,
          fadeInDuration: Duration.zero,
          placeholder: (_, _) => const ThumbFallback(),
          errorWidget: (_, _, _) => const ThumbFallback(),
        );
      },
    );
  }
}

/// グリッドの1セル。端まで詰めた正方形のサムネ + 動画バッジ + 選択の丸。
/// 選択中はタイルを内側へ寄せて角を丸め、どれを選んだか一目で分かるようにする（KMP 版と同じ）。
class MediaTile extends StatelessWidget {
  final MediaItem item;
  final bool selected;
  final bool selectionMode;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const MediaTile({
    super.key,
    required this.item,
    required this.selected,
    required this.selectionMode,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    // 動画でサムネが無い時に原本URLを渡すと動画ファイルを丸ごと落とすので、KMP 版と同じく枠だけ出す
    final thumb = item.thumbUrl;
    final inset = selected ? 10.0 : 0.0;
    return Semantics(
      label: item.name,
      selected: selectionMode ? selected : null,
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: ColoredBox(
          color: AppColors.surfaceHigh,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Padding(
                padding: EdgeInsets.all(inset),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(selected ? 8 : 0),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
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
                    ],
                  ),
                ),
              ),
              if (selectionMode)
                Positioned(
                  top: selected ? 10 : 6,
                  left: selected ? 10 : 6,
                  child: SelectCheck(selected: selected),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class ThumbFallback extends StatelessWidget {
  const ThumbFallback({super.key});
  @override
  Widget build(BuildContext context) => const Center(
    child: Icon(Icons.image_outlined, color: AppColors.textDim, size: 28),
  );
}

/// オフライン保存済みの印（KMP 版の「保存済み」）。
class OfflineBadge extends StatelessWidget {
  const OfflineBadge({super.key});

  @override
  Widget build(BuildContext context) => Semantics(
        label: '保存済み',
        child: Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Icon(Icons.download_done,
              size: 16, color: AppColors.accent),
        ),
      );
}
