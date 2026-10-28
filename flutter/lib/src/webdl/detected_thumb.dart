import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/foundation.dart';
import 'package:get_thumbnail_video/index.dart';
import 'package:get_thumbnail_video/video_thumbnail.dart';
import 'package:path_provider/path_provider.dart';

import 'detected.dart';
import '../upload/image_thumb.dart';
import 'hls.dart';
import 'web_fetcher.dart';

/// 動画（端末内のファイルか URL）から 1 コマ抜いた画像。取れなければ null。
typedef VideoFrame = Future<Uint8List?> Function(
    String video, Map<String, String> headers);

Future<Uint8List?> _nativeVideoFrame(
    String video, Map<String, String> headers) async {
  if (kIsWeb) return null;
  final data = await VideoThumbnail.thumbnailData(
    video: video,
    headers: headers.isEmpty ? null : headers,
    imageFormat: ImageFormat.JPEG,
    maxWidth: 192,
    timeMs: 1000,
    quality: 70,
  );
  return data.isEmpty ? null : data;
}

/// 取り込みの検出一覧（#164）に出すサムネを作る。
///
/// - 画像: ページが表示に使った URL を取り、縮小した物を持つ
/// - 動画: ブラウザ側で video 要素から抜いた実コマが一番優先。無ければ動画本体の先頭を
///   取得役（Cookie 込み）で取って端末の再生部品で 1 コマ抜き、それも駄目ならサイトの表紙
///   （video の poster）、最後に Cookie 無しで URL 直渡しのコマ抜きの順で試す
/// - HLS: 実コマか表紙があれば優先。無ければ一番軽い画質の最初のセグメントだけ取って、そこから 1 コマ抜く
///
/// 取れない物（音声・暗号化や fMP4 の HLS・大きすぎる画像・通信失敗）は null を返し、一覧はアイコンを出す。
/// 一覧はスクロールで行を作り直すので、同じ URL は 1 回だけ取りに行く。
class DetectedThumbs {
  DetectedThumbs({
    required this.fetcher,
    VideoFrame? videoFrame,
    Future<Uint8List?> Function(Uint8List bytes)? shrinkImage,
    Future<Directory> Function()? tempDir,
    this.maxParallel = 2,
    this.maxCached = 120,
    this.maxImageBytes = 16 * 1024 * 1024,
    this.maxSegmentBytes = 16 * 1024 * 1024,
    this.maxPlaylistBytes = 1024 * 1024,
    this.maxVideoPrefixBytes = 8 * 1024 * 1024,
  })  : _videoFrame = videoFrame ?? _nativeVideoFrame,
        _shrink = shrinkImage ?? makeImageThumb,
        _tempDir = tempDir ?? getTemporaryDirectory;

  final WebFetcher fetcher;
  final VideoFrame _videoFrame;
  final Future<Uint8List?> Function(Uint8List bytes) _shrink;
  final Future<Directory> Function() _tempDir;

  /// 同時に取りに行く数。検出は 1 ページ 300 件まであるので、回線と端末の再生部品を詰まらせない
  final int maxParallel;
  final int maxCached;

  /// 画像の上限。サムネのために巨大な原寸を丸ごと読み込まない
  final int maxImageBytes;

  /// HLS のセグメントの上限。最初の 1 本だけなので、普通は数 MB に収まる
  final int maxSegmentBytes;

  /// プレイリスト（m3u8）の上限。文字だけなので 1 MB あれば足りる
  final int maxPlaylistBytes;

  /// 実コマ抜きのために取る動画本体の先頭の上限。moov が先頭の MP4 や TS なら
  /// 数 MB で最初のコマが抜ける。全体は取らない
  final int maxVideoPrefixBytes;

  final LinkedHashMap<String, Future<Uint8List?>> _cache = LinkedHashMap();
  int _running = 0;
  final Queue<Completer<void>> _waiting = Queue();
  int _seq = 0;

  Future<Uint8List?> of(DetectedItem d) {
    // 表紙や実コマが後から届いて項目が差し代わっても、古いサムネを使い回さないようキーに含める
    // （実コマの中身そのものはキーに入れない。届いたかどうかだけ見る）
    final key = '${d.url}|${d.poster}|${d.frame.isEmpty ? 0 : 1}';
    final hit = _cache.remove(key);
    if (hit != null) {
      _cache[key] = hit;
      return hit;
    }
    final f = _limited(() => _make(d));
    _cache[key] = f;
    while (_cache.length > maxCached) {
      _cache.remove(_cache.keys.first);
    }
    return f;
  }

  Future<Uint8List?> _limited(Future<Uint8List?> Function() job) async {
    if (_running >= maxParallel) {
      final c = Completer<void>();
      _waiting.add(c);
      await c.future;
    }
    _running++;
    try {
      return await job();
    } finally {
      _running--;
      if (_waiting.isNotEmpty) _waiting.removeFirst().complete();
    }
  }

  Future<Uint8List?> _make(DetectedItem d) async {
    try {
      return switch (d.kind) {
        DetectedKind.image => await _image(d),
        DetectedKind.video => await _video(d),
        DetectedKind.hls => await _hls(d),
        DetectedKind.audio || DetectedKind.other => null,
      };
    } on Exception catch (e) {
      // サムネは飾り。取れなければアイコンのままにする
      debugPrint('detected thumb skipped: $e');
      return null;
    }
  }

  /// サイトが動画に付けた表紙。端末の再生部品は Cookie を外すので、ブラウザでは見えていても
  /// コマが取れない動画でも、表紙なら取得役（Cookie を引き直す）で取れる。無ければ null。
  Future<Uint8List?> _poster(DetectedItem d) async {
    if (d.poster.isEmpty) return null;
    try {
      final bytes =
          await _fetchBounded(d.poster, d.headers, maxImageBytes, origin: d.url);
      if (bytes.isNotEmpty) return _shrink(bytes);
    } on Exception {
      // 表紙が取れなければ、従来の取り方に回る
    }
    return null;
  }

  Future<Uint8List?> _video(DetectedItem d) async {
    // 実体のコマを優先する（ブラウザで抜いた物 → 本体の先頭から抜いた物）。
    // どちらも無理な時だけサイトの表紙や、Cookie を外した直抜きに回る
    return await _frameData(d) ??
        await _prefixFrame(d) ??
        await _poster(d) ??
        _videoFrame(d.url, _withoutCookie(d.headers));
  }

  /// ブラウザ側で video 要素から canvas に描いて送ってもらった実コマ（JPEG の data URL）。
  /// ブラウザが既にデコードした絵なので、Cookie 必須のサイトでも余分な通信無しで使える。
  Future<Uint8List?> _frameData(DetectedItem d) async {
    if (d.frame.isEmpty) return null;
    try {
      final i = d.frame.indexOf(',');
      if (i < 0) return null;
      final bytes = base64Decode(d.frame.substring(i + 1));
      if (bytes.isEmpty) return null;
      return await _shrink(bytes);
    } on Exception {
      return null;
    }
  }

  /// 動画本体の先頭だけ取得役（Cookie 込み）で取り、そこから 1 コマ抜く。
  /// canvas が汚れてブラウザ側では送れない別ドメイン動画や、通信でだけ拾った URL でも
  /// 実体の絵が出る。先頭だけでは画にならない形（moov が末尾の MP4 など）は null で次に回す。
  Future<Uint8List?> _prefixFrame(DetectedItem d) async {
    try {
      final bytes =
          await _fetchPrefix(d.url, d.headers, maxVideoPrefixBytes, origin: d.url);
      if (bytes.isEmpty) return null;
      final dir = await _tempDir();
      final f = File(
          '${dir.path}/r2-detected-thumb-${identityHashCode(this)}-${_seq++}${_suffix(d.url)}');
      try {
        await f.writeAsBytes(bytes, flush: true);
        return await _videoFrame(f.path, const {});
      } finally {
        if (await f.exists()) await f.delete();
      }
    } on Exception {
      return null;
    }
  }

  /// 端末の再生部品が拡張子で中身を推測するので、URL の末尾から拾う。取れなければ .mp4。
  static String _suffix(String url) {
    final path = url.split('?').first.split('#').first;
    final i = path.lastIndexOf('.');
    if (i < 0 || i < path.lastIndexOf('/')) return '.mp4';
    final e = path.substring(i);
    return e.length <= 6 ? e : '.mp4';
  }

  Future<Uint8List?> _image(DetectedItem d) async {
    final bytes = await _fetchBounded(d.url, d.headers, maxImageBytes);
    if (bytes.isEmpty) return null;
    // 原寸のまま持つと、一覧を見ている間に最大 120 件分の画像がメモリに残る。縮小した物だけ持つ
    return _shrink(bytes);
  }

  Future<Uint8List?> _hls(DetectedItem d) async {
    // HLS も実コマかサイトの表紙があればそれを優先。コマ抜きは暗号化や fMP4 で画にならないことがある
    final p = await _frameData(d) ?? await _poster(d);
    if (p != null) return p;
    var text = await _fetchText(d.url, d.headers);
    var base = d.url;
    if (hlsIsMaster(text)) {
      final v = hlsVariant(text, base, lowest: true);
      if (v == null) return null;
      text = await _fetchText(v, d.headers, origin: d.url);
      base = v;
    }
    // 暗号化や初期化セグメントの要る形は、最初のセグメントだけでは画にならない
    if (hlsIsEncrypted(text) || hlsNeedsInitSegment(text)) return null;
    final segs = hlsSegments(text, base);
    if (segs.isEmpty) return null;
    final seg =
        await _fetchBounded(segs.first, d.headers, maxSegmentBytes, origin: d.url);
    if (seg.isEmpty) return null;
    final dir = await _tempDir();
    final f = File('${dir.path}/r2-detected-thumb-${identityHashCode(this)}-${_seq++}.ts');
    try {
      await f.writeAsBytes(seg, flush: true);
      return await _videoFrame(f.path, const {});
    } finally {
      if (await f.exists()) await f.delete();
    }
  }

  Future<String> _fetchText(String url, Map<String, String> headers,
          {String? origin}) async =>
      utf8.decode(
          await _fetchBounded(url, headers, maxPlaylistBytes, origin: origin),
          allowMalformed: true);

  /// 受け取りながら上限を見る。全部受け取ってから大きさを見ると、巨大な原本を丸ごとメモリに載せてしまう
  Future<Uint8List> _fetchBounded(
      String url, Map<String, String> headers, int limit,
      {String? origin}) async {
    final token = CancelToken();
    final buf = BytesBuilder(copy: false);
    try {
      await fetcher.download(
        url,
        headers,
        resumeAt: 0,
        origin: origin,
        cancelToken: token,
        onTotal: (n) {
          if (n > limit) throw const _TooLarge();
        },
        onChunk: (c) {
          buf.add(c);
          if (buf.length > limit) throw const _TooLarge();
        },
        onProgress: (_) {},
      );
    } on _TooLarge {
      token.cancel();
      rethrow;
    }
    return buf.takeBytes();
  }

  /// [_fetchBounded] と同じだが、上限に達した所で受け取りをやめて「そこまでの先頭分」を返す。
  /// 動画の実コマを抜くのに先頭だけ欲しい時に使う。本体の総バイト数は関係ないので
  /// Content-Length で先に分かっても止めない
  Future<Uint8List> _fetchPrefix(
      String url, Map<String, String> headers, int limit,
      {String? origin}) async {
    final token = CancelToken();
    final buf = BytesBuilder(copy: false);
    try {
      await fetcher.download(
        url,
        headers,
        resumeAt: 0,
        origin: origin,
        cancelToken: token,
        onChunk: (c) {
          buf.add(c);
          if (buf.length > limit) throw const _TooLarge();
        },
        onProgress: (_) {},
      );
    } on _TooLarge {
      token.cancel();
    }
    final all = buf.takeBytes();
    // 最後の塊で上限をはみ出した分は切り捨てる
    return all.length <= limit ? all : Uint8List.sublistView(all, 0, limit);
  }

  // 端末の再生部品はリダイレクト先の別ホストにもヘッダをそのまま送る。
  // 閲覧サイトのログイン Cookie を第三者に渡さないよう、Cookie は外す（取得役の WebFetcher と同じ考え方）
  static Map<String, String> _withoutCookie(Map<String, String> h) => {
        for (final e in h.entries)
          if (e.key.toLowerCase() != 'cookie') e.key: e.value,
      };
}

/// サムネのために取る物が上限を超えた。途中で受け取りをやめる合図
class _TooLarge implements Exception {
  const _TooLarge();
}
