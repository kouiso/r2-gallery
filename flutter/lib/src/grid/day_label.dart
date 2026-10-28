/// 日付の見出し・表示。KMP 版 DayLabel.kt と同じ文言にそろえる。
/// 写真タブ・フォルダ・アルバムの見出し、ゴミ箱の日付、ビューアの日時はすべてここを使う。
library;

const _weekdays = ['月曜日', '火曜日', '水曜日', '木曜日', '金曜日', '土曜日', '日曜日'];

DateTime _dateOf(DateTime t) => DateTime(t.year, t.month, t.day);

DateTime _dateOfMs(int epochMs) =>
    _dateOf(DateTime.fromMillisecondsSinceEpoch(epochMs));

String _monthDayWeekday(DateTime d) =>
    '${d.month}月${d.day}日 ${_weekdays[d.weekday - 1]}';

/// 日付見出し。今日・昨日は言葉で、それ以外は曜日つき（今年は年を省く）。
/// createdAt が無いものは「日付不明」にまとめる。同じ日は同じ文字列になるので、
/// そのままグループ分けのキーにも使える。
String formatDayHeader(int? createdAt, DateTime now) {
  if (createdAt == null) return '日付不明';
  final d = _dateOfMs(createdAt);
  final today = _dateOf(now);
  // 夏時間のある地域でも日付だけで比べるよう、年月日から作り直して1日前を出す
  final yesterday = DateTime(today.year, today.month, today.day - 1);
  if (d == today) return '今日';
  if (d == yesterday) return '昨日';
  if (d.year == today.year) return _monthDayWeekday(d);
  return '${d.year}年${_monthDayWeekday(d)}';
}

/// ゴミ箱の「10月9日」など。今年は年を省く。
String formatShortDate(int epochMs, DateTime now) {
  final d = _dateOfMs(epochMs);
  final md = '${d.month}月${d.day}日';
  return d.year == now.year ? md : '${d.year}年$md';
}

/// ビューア上部の「10月8日 木曜日 18:42」。今日・昨日は言い換えず日付で出す。
String formatDateTime(int createdAt, DateTime now) {
  final t = DateTime.fromMillisecondsSinceEpoch(createdAt);
  final d = _dateOf(t);
  final day = d.year == now.year
      ? _monthDayWeekday(d)
      : '${d.year}年${_monthDayWeekday(d)}';
  final hh = t.hour.toString().padLeft(2, '0');
  final mm = t.minute.toString().padLeft(2, '0');
  return '$day $hh:$mm';
}
