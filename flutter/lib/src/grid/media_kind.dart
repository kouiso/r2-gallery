import '../api/models.dart';

/// 写真一覧の種別絞り込み。#26：写真だけ・動画だけを出す。
/// SortMode と同じく、絞り込みは Worker がライブラリ全体に対して行う（type パラメータ）。
/// 端末側の [matches] は type を知らない古い Worker に繋がった時だけ、
/// 混ざって返ってきた行を端末で除く退避用。
enum MediaKind {
  all('すべて', null),
  photo('写真', 'photo'),
  video('動画', 'video');

  const MediaKind(this.label, this.apiValue);
  final String label;

  /// Worker に渡す type の値。all はパラメータ自体を送らず、古い Worker との互換を保つ
  final String? apiValue;

  bool matches(MediaItem it) {
    return switch (this) {
      MediaKind.all => true,
      MediaKind.photo => it.isImage,
      MediaKind.video => it.isVideo,
    };
  }
}
