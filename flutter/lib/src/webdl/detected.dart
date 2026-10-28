/// ネットの閲覧中に見つけたメディアの型。KMP 版 webdl/Detected.kt と対応させている。
library;

enum DetectedKind { video, hls, audio, image, other }

/// 閲覧ページで見つけたメディア URL。ホットリンク対策のあるサイトから取るため、
/// 取得に要るリクエストヘッダ（UA / Referer / Cookie）も一緒に持つ。
class DetectedItem {
  final String url;
  final DetectedKind kind;
  final Map<String, String> headers;

  /// サイトがそのメディアに付けている表紙画像の URL（video の poster など）。
  /// 通信だけで拾った URL はファイル名しか分からないので、一覧がサイト上の見た目と
  /// 同じ表紙を出せるように DOM 走査から拾った物を載せる。無ければ空。
  final String poster;

  /// サイト上でそのメディアについている名前（カードのタイトルなど）。
  /// `1143_1_.mp4` のような機械的なファイル名だと一覧で見分けがつかないので、
  /// 分かる時だけ載せる。無ければ空。
  final String label;

  /// ページの video 要素が実際にデコードした 1 コマ（JPEG の data URL）。
  /// サムネは「サイトの表紙」より動画の実体が分かる物の方が判別に効くので、
  /// ブラウザ側で canvas に描いて送ってもらう。無ければ空。
  final String frame;

  const DetectedItem(this.url, this.kind,
      [this.headers = const {},
      this.poster = '',
      this.label = '',
      this.frame = '']);

  /// 後から分かった表紙・名前・実コマを足した物を返す。既にある値は上書きしない。
  DetectedItem withMeta(
          {String poster = '', String label = '', String frame = ''}) =>
      DetectedItem(
        url,
        kind,
        headers,
        this.poster.isNotEmpty ? this.poster : poster,
        this.label.isNotEmpty ? this.label : label,
        this.frame.isNotEmpty ? this.frame : frame,
      );

  /// 一覧とアップロード名に使う名前。URL の末尾セグメントを安全な文字だけにする。
  String get displayName {
    final path = _beforeAny(url, '?#');
    final lastSlash = path.lastIndexOf('/');
    final rawSeg = lastSlash < 0 ? path : path.substring(lastSlash + 1);
    final seg = rawSeg.trim().isEmpty ? 'media' : rawSeg;
    String? decoded;
    try {
      final segs = Uri.parse(url).pathSegments;
      if (segs.isNotEmpty) decoded = segs.last;
    } on FormatException {
      // 解釈できない URL は素の末尾セグメントにフォールバックする
    }
    final base = (decoded != null && decoded.trim().isNotEmpty) ? decoded : seg;
    final clean = _trimChars(base.replaceAll(RegExp(r'[^\w.() -]+'), '_'), '_.');
    return clean.trim().isEmpty ? 'media' : _take(clean, 80);
  }
}

String _beforeAny(String s, String chars) {
  var end = s.length;
  for (final c in chars.split('')) {
    final i = s.indexOf(c);
    if (i >= 0 && i < end) end = i;
  }
  return s.substring(0, end);
}

String _trimChars(String s, String chars) {
  var a = 0;
  var b = s.length;
  while (a < b && chars.contains(s[a])) {
    a++;
  }
  while (b > a && chars.contains(s[b - 1])) {
    b--;
  }
  return s.substring(a, b);
}

String _take(String s, int n) => s.length <= n ? s : s.substring(0, n);

const _videoExt = [
  '.mp4', '.webm', '.mkv', '.mov', '.m4v', '.avi', '.flv', '.3gp', //
  '.mpg', '.mpeg', '.wmv', '.ts',
];
const _audioExt = ['.mp3', '.m4a', '.aac', '.ogg', '.opus', '.wav', '.flac'];
const _imageExt = ['.jpg', '.jpeg', '.png', '.webp', '.gif', '.avif', '.bmp'];

/// 見つけたリクエスト／メディア URL を動画ダウンローダ系アプリと同じ基準で分類する。
/// ダウンロード対象でなければ null。
DetectedKind? detectKind(String url) {
  final path = _beforeAny(url, '?#').toLowerCase();
  if (path.endsWith('.m3u8') || url.contains('.m3u8?')) return DetectedKind.hls;
  if (_videoExt.any(path.endsWith)) return DetectedKind.video;
  if (_audioExt.any(path.endsWith)) return DetectedKind.audio;
  if (_imageExt.any(path.endsWith)) return DetectedKind.image;
  return null;
}
