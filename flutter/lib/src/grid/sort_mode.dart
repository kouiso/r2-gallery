import '../api/models.dart';

/// 写真一覧の並び順。KMP 版 SortMode と同じ4種・同じ文言。
/// サーバーは新着順でしか返さないので、読み込み済みの分を端末側で並べ替える。
enum SortMode {
  dateNew('新しい順'),
  dateOld('古い順'),
  name('名前順'),
  size('サイズ順');

  const SortMode(this.label);
  final String label;

  /// 日付で並ぶ時だけ日付見出しを出す（名前順・サイズ順では日が飛び飛びになるため）。
  bool get isDate => this == dateNew || this == dateOld;

  List<MediaItem> sorted(List<MediaItem> items) {
    final cmp = switch (this) {
      SortMode.dateNew =>
        (MediaItem a, MediaItem b) =>
            (b.createdAt ?? 0).compareTo(a.createdAt ?? 0),
      SortMode.dateOld =>
        (MediaItem a, MediaItem b) =>
            (a.createdAt ?? 0).compareTo(b.createdAt ?? 0),
      SortMode.name =>
        (MediaItem a, MediaItem b) =>
            a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      SortMode.size => (MediaItem a, MediaItem b) => (b.size ?? 0).compareTo(
        a.size ?? 0,
      ),
    };
    // List.sort は安定ではない。同じ日時・同じ大きさの並びが読み込みのたびに入れ替わると
    // 見ている位置が跳ぶので、元の順（サーバーの新着順）を同点の決め手にする
    final indexed = [for (var i = 0; i < items.length; i++) (i, items[i])];
    indexed.sort((a, b) {
      final c = cmp(a.$2, b.$2);
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });
    return [for (final e in indexed) e.$2];
  }
}
