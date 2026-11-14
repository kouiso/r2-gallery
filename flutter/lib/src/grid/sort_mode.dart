import '../api/models.dart';

/// 写真一覧の並び順。KMP 版 SortMode と同じ4種・同じ文言。
/// 並べ替えは Worker がライブラリ全体に対して行う。[sorted] は、並び順を知らない
/// 古い Worker に繋がった時だけ、読み込み済みの分を端末側で並べる退避用。
enum SortMode {
  dateNew('新しい順', 'new'),
  dateOld('古い順', 'old'),
  name('名前順', 'name'),
  size('サイズ順', 'size');

  const SortMode(this.label, this.apiValue);
  final String label;

  final String apiValue;

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
