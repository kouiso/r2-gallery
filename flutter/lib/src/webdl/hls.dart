/// HLS（m3u8）の解釈。KMP 版 WebFetcher.kt の純関数部分と同じ挙動で、
/// 最良の画質を選んで全セグメントを順に取る方式（動画ダウンローダ系アプリと同じ）。
library;

// AVERAGE-BANDWIDTH を BANDWIDTH と取り違えんよう、属性の頭（: か ,）に揃えて探す
final _bandwidth = RegExp(r'#EXT-X-STREAM-INF:(?:[^\n]*,)?BANDWIDTH=(\d+)');

/// 行が URI 行（空でもコメントでもない）か。
bool _isUri(String l) => l.isNotEmpty && !l.startsWith('#');

/// 参照を基準 URL に対して絶対 URL にする。
String resolveUrl(String base, String ref) =>
    Uri.parse(base).resolve(ref).toString();

// CODECS は値の中にカンマを含むので、引用符の中身をまとめて取る
final _codecs = RegExp(r'[:,]CODECS="([^"]*)"');
final _resolution = RegExp(r'[:,]RESOLUTION=\d+x\d+');

// 映像の codec の頭（RFC 6381 の表記）。mp4a・ac-3・ec-3・opus などは音声だけ
const _videoCodecs = [
  'avc1', 'avc3', 'hvc1', 'hev1', 'dvh1', 'dvhe', 'dva1', 'dvav', //
  'vp08', 'vp09', 'av01', 'vvc1', 'vvi1', 'mp4v',
];

class _Variant {
  _Variant(this.bandwidth, this.url, this.codecs, this.hasResolution);
  final int bandwidth;
  final String url;
  final String? codecs;
  final bool hasResolution;

  bool get hasVideoCodec =>
      codecs != null &&
      codecs!.split(',').any((c) =>
          _videoCodecs.any((v) => c.trim().toLowerCase().startsWith(v)));
}

/// マスタープレイリストから BANDWIDTH 最大の変種プレイリスト URL を選ぶ。
/// [lowest] なら最小を選ぶ（サムネのように 1 コマだけ要る時に、取る量を減らすため）。
/// ただし音声だけの変種は 1 コマも取れないので飛ばし、映像のある中で一番軽い物を選ぶ。
/// 映像の有無が分かる物が 1 つも無ければ、従来どおり単純に最小を選ぶ。
/// メディアプレイリスト（セグメントだけ）なら null。
String? hlsVariant(String masterText, String baseUrl, {bool lowest = false}) {
  final variants = <_Variant>[];
  int? lastBw;
  String? lastCodecs;
  var lastRes = false;
  for (final raw in masterText.split('\n')) {
    final l = raw.trim();
    final m = _bandwidth.firstMatch(l);
    if (m != null) {
      lastBw = int.tryParse(m.group(1)!) ?? 0;
      lastCodecs = _codecs.firstMatch(l)?.group(1);
      lastRes = _resolution.hasMatch(l);
      continue;
    }
    if (_isUri(l) && lastBw != null) {
      variants
          .add(_Variant(lastBw, resolveUrl(baseUrl, l), lastCodecs, lastRes));
      lastBw = null;
    }
  }
  if (variants.isEmpty) return null;
  var pool = variants;
  if (lowest) {
    // 音声だけの変種は、映像の codec も RESOLUTION も無い物。
    // CODECS が無い時は、他に RESOLUTION を持つ変種がある場合に限って音声だけと見なす
    final anyRes = variants.any((v) => v.hasResolution);
    final withVideo = [
      for (final v in variants)
        if (v.hasVideoCodec ||
            v.hasResolution ||
            (v.codecs == null && !anyRes))
          v,
    ];
    if (withVideo.isNotEmpty) pool = withVideo;
  }
  var best = pool.first;
  for (final v in pool.skip(1)) {
    if (lowest ? v.bandwidth < best.bandwidth : v.bandwidth > best.bandwidth) {
      best = v;
    }
  }
  return best.url;
}

/// メディアプレイリストのセグメント URL を並び順のまま返す。
List<String> hlsSegments(String playlistText, String baseUrl) => [
      for (final raw in playlistText.split('\n'))
        if (_isUri(raw.trim())) resolveUrl(baseUrl, raw.trim()),
    ];

/// 変種を持つマスタープレイリストか。
bool hlsIsMaster(String text) => text.contains('#EXT-X-STREAM-INF');

/// fMP4 形式（初期化セグメント #EXT-X-MAP が要る）か。ts のように単純に繋ぐだけでは再生できない。
bool hlsNeedsInitSegment(String text) => text.contains('#EXT-X-MAP');

/// AES などで暗号化されたセグメントか。復号せずに繋ぐと壊れた動画ができるので呼び出し側で止める。
bool hlsIsEncrypted(String text) =>
    RegExp(r'#EXT-X-KEY:[^\n]*METHOD=(?!NONE)', caseSensitive: false)
        .hasMatch(text);
