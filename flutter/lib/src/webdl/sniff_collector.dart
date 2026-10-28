import 'detected.dart';
import 'url_policy.dart';

/// 閲覧ページで見つけたメディアの集め箱。KMP 版 SniffCollector.kt と同じ役割。
/// 入口は2つ。リソース通信を見張る [capture]（リクエストヘッダ付き）と、
/// ページ内の DOM を走査する [addFromPage]（ページ共通のヘッダのみ）。
/// URL で重複を除き、先に見つけた方（通信由来のヘッダの方が正確）を残す。
class SniffCollector {
  final Map<String, DetectedItem> _found = {};

  /// 1ページで抱える上限。ページは信用できんので、際限なく送られても一覧とメモリが膨らまんようにする。
  static const maxItems = 300;

  bool _accept(String url) =>
      isWebUrl(url) && (_found.length < maxItems || _found.containsKey(url));

  /// 通信から拾う。メディア拡張子か .m3u8 だけが対象で、画像は集めない
  /// （ページ中の画像は通信のたびに出て、一覧が画像だらけになるため）。
  /// Cookie と Referer は、リクエスト側に無い時だけ補う。
  DetectedItem? capture(
    String url,
    Map<String, String>? requestHeaders, {
    String? cookie,
    String? referer,
  }) {
    final kind = detectKind(url);
    if (kind == null || kind == DetectedKind.image || !_accept(url)) return null;
    final h = {...?requestHeaders};
    bool has(String name) => h.keys.any((k) => k.toLowerCase() == name);
    if (cookie != null && cookie.trim().isNotEmpty && !has('cookie')) {
      h['Cookie'] = cookie;
    }
    if (referer != null && referer.trim().isNotEmpty && !has('referer')) {
      h['Referer'] = referer;
    }
    final item = DetectedItem(url, kind, h);
    return _found.putIfAbsent(url, () => item);
  }

  /// DOM 走査の結果を取り込む。通信で拾済みの URL は、そちらのヘッダを優先して触らない。
  /// [poster] / [label] / [frame] は video 要素の表紙・カードのタイトル・実コマ。
  /// 通信だけで拾った検出にも、あとで分かった物なら足す
  /// （ファイル名では一覧で見分けがつかないため）。
  DetectedItem? addFromPage(String url, Map<String, String> headers,
      {String poster = '', String label = '', String frame = ''}) {
    final kind = detectKind(url);
    if (kind == null || !_accept(url)) return null;
    final existing = _found[url];
    if (existing == null) {
      return _found[url] = DetectedItem(url, kind, headers, poster, label, frame);
    }
    // 足せる物が無い通知では同じ物を保つ（ヘッダの優先順位を壊さない）
    if ((poster.isNotEmpty && existing.poster.isEmpty) ||
        (label.isNotEmpty && existing.label.isEmpty) ||
        (frame.isNotEmpty && existing.frame.isEmpty)) {
      return _found[url] =
          existing.withMeta(poster: poster, label: label, frame: frame);
    }
    return existing;
  }

  List<DetectedItem> list() => List.unmodifiable(_found.values);

  /// 新しいページへ移った。前のページの検出が新しいページの件数に混ざらんよう空にする。
  void clear() => _found.clear();
}
