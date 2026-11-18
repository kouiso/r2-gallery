import '../api/models.dart';
import 'day_label.dart';

/// グリッドの1行。label が入っている行は日付の見出し、それ以外は count 個のタイルの行。
/// start は一覧全体での先頭の位置。
typedef GridRow = ({
  String? label,
  List<MediaItem> day,
  int start,
  int count,
  bool gapAfter,
});

/// 日付の区切りと行を覚えておき、後ろに足された分と最後の日だけを作り直す。
/// ページが届くたびに読み込み済みの全件をなめ直すと 1 フレームが重くなるので、
/// 作り直しの量を届いた分に比例させる（#25 作業2）。
class DayRows {
  final List<GridRow> rows = [];

  List<MediaItem> _items = const [];
  int _columns = 0;
  int _nowDay = -1;
  // _items の中で、最後の日が始まる位置と、その見出し行が rows にある位置
  int _dayStart = 0;
  int _rowsBeforeLastDay = 0;

  List<GridRow> update(
    List<MediaItem> items, {
    required int columns,
    required DateTime now,
  }) {
    final nowDay =
        DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
    if (columns != _columns || nowDay != _nowDay || _items.isEmpty) {
      _rebuild(items, columns: columns, nowDay: nowDay, from: 0);
    } else if (!identical(items, _items)) {
      // 追記かどうかは、最後の日の先頭より前が同一インスタンスのままかで確かめる
      var append = items.length >= _items.length && _dayStart <= items.length;
      if (append) {
        for (var i = 0; i < _dayStart; i++) {
          if (!identical(items[i], _items[i])) {
            append = false;
            break;
          }
        }
      }
      if (append) {
        rows.removeRange(_rowsBeforeLastDay, rows.length);
        _rebuild(items, columns: columns, nowDay: nowDay, from: _dayStart);
      } else {
        _rebuild(items, columns: columns, nowDay: nowDay, from: 0);
      }
    }
    return rows;
  }

  void _rebuild(
    List<MediaItem> items, {
    required int columns,
    required int nowDay,
    required int from,
  }) {
    if (from == 0) {
      rows.clear();
    }
    _items = items;
    _columns = columns;
    _nowDay = nowDay;
    if (from == 0) {
      _dayStart = 0;
      _rowsBeforeLastDay = 0;
    }

    final now = DateTime.fromMillisecondsSinceEpoch(nowDay);
    String? label;
    var i = from;
    var offset = from;
    while (i < items.length) {
      final l = formatDayHeader(items[i].createdAt, now);
      if (label != l) {
        // 日付が変わる所で、その日の範囲を先に切って見出し行を積む
        label = l;
        _dayStart = i;
        _rowsBeforeLastDay = rows.length;
        var dayEnd = i;
        while (dayEnd < items.length &&
            formatDayHeader(items[dayEnd].createdAt, now) == label) {
          dayEnd++;
        }
        final day = items.sublist(i, dayEnd);
        rows.add((
          label: l,
          day: day,
          start: offset,
          count: 0,
          gapAfter: false,
        ));
        for (var j = 0; j < day.length; j += columns) {
          final remaining = day.length - j;
          rows.add((
            label: null,
            day: day,
            start: offset + j,
            count: remaining < columns ? remaining : columns,
            gapAfter: remaining > columns,
          ));
        }
        offset += day.length;
        i = dayEnd;
      }
    }
  }
}
