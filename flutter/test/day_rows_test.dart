import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/grid/day_rows.dart';

MediaItem _it(String key, int at) => MediaItem(
    key: key, type: 'image', url: 'https://w.example/m/$key', createdAt: at);

void main() {
  final now = DateTime(2026, 11, 18, 12); // 水曜日
  // createdAt はエポックミリ秒
  int day(int y, int m, int d) => DateTime(y, m, d).millisecondsSinceEpoch;

  test('初回は全件で日付の区切りと行を作る', () {
    final r = DayRows();
    final rows = r.update(
        [
          _it('a', day(2026, 11, 18)),
          _it('b', day(2026, 11, 18)),
          _it('c', day(2026, 11, 17))
        ],
        columns: 4,
        now: now);
    expect(rows.map((e) => e.label),
        ['今日', null, '昨日', null]);
    expect(rows[1].start, 0);
    expect(rows[1].count, 2);
    expect(rows[3].start, 2);
    expect(rows[3].count, 1);
  });

  test('後ろに足された分は最後の日の作り直しだけで揃う', () {
    final r = DayRows();
    final first = [
      _it('a', day(2026, 11, 18)),
      _it('b', day(2026, 11, 17)),
      _it('c', day(2026, 11, 17)),
    ];
    final rows0 = r.update(first, columns: 4, now: now);
    expect(rows0.map((e) => e.label),
        ['今日', null, '昨日', null]);
    final headerToday = rows0[0];

    final rows1 = r.update(
        [...first, _it('d', day(2026, 11, 17)), _it('e', day(2026, 11, 10))],
        columns: 4,
        now: now);
    expect(rows1.map((e) => e.label),
        ['今日', null, '昨日', null, '11月10日 火曜日', null]);
    // 前の日の見出し行は同一インスタンスのまま（作り直しは最後の日から）
    expect(identical(rows1[0], headerToday), isTrue);
    expect(rows1[2].day.length, 3); // b,c,d が 11月17日
    expect(rows1[3].start, 1);
    expect(rows1[3].count, 3);
    expect(rows1[5].start, 4);
  });

  test('途中の行が差し替わったら全件で作り直す', () {
    final r = DayRows();
    final first = [_it('a', day(2026, 11, 18)), _it('b', day(2026, 11, 17))];
    final rows0 = r.update(first, columns: 4, now: now);
    final headerToday = rows0[0];
    final rows1 =
        r.update([_it('x', day(2026, 11, 18)), first[1]], columns: 4, now: now);
    expect(identical(rows1[0], headerToday), isFalse);
    expect(rows1.map((e) => e.label), ['今日', null, '昨日', null]);
  });

  test('列数が変わったら全件で作り直す', () {
    final r = DayRows();
    final items = List.generate(5, (i) => _it('a$i', day(2026, 11, 18)));
    final rows0 = r.update(items, columns: 4, now: now);
    expect(rows0.length, 3); // 見出し + 4列 + 1列
    final rows1 = r.update(items, columns: 2, now: now);
    expect(rows1.length, 4); // 見出し + 2 + 2 + 1
  });
}
