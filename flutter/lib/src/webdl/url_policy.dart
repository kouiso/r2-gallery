/// 取り込みブラウザが扱ってよい URL の決まり。
/// 開くページは信用できんので、http/https 以外（file: / content: / intent: / javascript: など）は
/// 開かず・取らず・拾わない。端末内のファイルや他アプリへ抜ける口を作らんため。
library;

/// http/https で、ホストを持つ URL か。
bool isWebUrl(String url) {
  final u = Uri.tryParse(url.trim());
  if (u == null) return false;
  return (u.scheme == 'http' || u.scheme == 'https') && u.host.isNotEmpty;
}

/// 入力欄の文字列を、開く URL にする。開けないものは null。
/// スキームを省いた入力（example.com/video）は https とみなす（KMP 版と同じ）。
String? normalizeBrowserInput(String input) {
  final t = input.trim();
  if (t.isEmpty) return null;
  final url = t.contains('://') ? t : 'https://$t';
  return isWebUrl(url) ? url : null;
}
