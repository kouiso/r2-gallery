import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'url_policy.dart';

/// サーバーが Range を無視した。呼び出し側はファイルを最初から取り直す
/// （部分ファイルに全体を追記して壊さんため）。
class RangeUnsupported implements Exception {
  @override
  String toString() => 'server ignored Range request';
}

/// 取得先が 2xx 以外を返した。
class WebFetchError implements Exception {
  final int status;
  const WebFetchError(this.status);
  @override
  String toString() => 'HTTP $status';
}

/// http/https 以外への取得やリダイレクト。ページが用意した URL なので、端末内へ向くものは取らない。
class UnsupportedWebUrl implements Exception {
  final String url;
  const UnsupportedWebUrl(this.url);
  @override
  String toString() => 'http/https 以外の URL は取得できません';
}

/// 送り先の URL に載せる Cookie を引く。ブラウザと同じく、その URL のホストの Cookie だけを返す。
typedef CookieLookup = Future<String?> Function(String url);

/// ブラウザで見つけたメディアを取る素の HTTP 取得役（アプリの認証は付けない）。
/// ページが再生する時と同じ UA / Referer / Cookie を載せるので、
/// ホットリンク対策のある動画も同じように取れる。KMP 版 WebFetcher.kt に対応。
///
/// KMP 版は検出時の Cookie を、HLS のセグメントやリダイレクト先など別のホストへもそのまま送っていた。
/// それだと閲覧サイトのログイン Cookie が CDN など第三者に漏れるので、Cookie は送り先ごとに引き直し、
/// 検出時の Cookie は検出元と同じホストにだけ送る。リダイレクトも自前でたどって毎回付け直す。
class WebFetcher {
  WebFetcher({Dio? dio, this.cookieFor})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 30),
              // 大きい動画はゆっくり流れるので受け側は長めに取る
              receiveTimeout: const Duration(minutes: 5),
              // 2xx 以外は自前で WebFetchError にする（ボディを捨てるため）
              validateStatus: (_) => true,
            ));

  final Dio _dio;
  final CookieLookup? cookieFor;

  static const maxRedirects = 5;

  // Host などは HTTP クライアントが決める。載せると接続先と食い違って壊れる。
  // Range は再生中のリクエストの一部分（bytes=0-1 など）を引き継ぐと欠けたファイルになるので、続きから取る時だけ自前で付ける。
  // Cookie は送り先ごとに決め直す
  static const _skipHeaders = {
    'host',
    'connection',
    'content-length',
    'range',
    'cookie',
  };

  Future<Map<String, String>> _headersFor(
    Uri target,
    Map<String, String> h,
    Uri origin, {
    int resumeAt = 0,
  }) async {
    String? captured;
    final out = <String, String>{};
    for (final e in h.entries) {
      final k = e.key.toLowerCase();
      if (k == 'cookie') captured = e.value;
      if (!_skipHeaders.contains(k)) out[e.key] = e.value;
    }
    final lookup = cookieFor;
    final fresh = lookup == null ? null : await lookup(target.toString());
    final cookie =
        fresh ?? (target.host.toLowerCase() == origin.host.toLowerCase() ? captured : null);
    if (cookie != null && cookie.isNotEmpty) out['Cookie'] = cookie;
    if (resumeAt > 0) out['Range'] = 'bytes=$resumeAt-';
    return out;
  }

  /// リダイレクトをたどって GET する。[origin] は検出時の Cookie が属するページ側の URL。
  Future<Response<T>> _get<T>(
    String url,
    Map<String, String> headers, {
    required ResponseType type,
    String? origin,
    int resumeAt = 0,
    CancelToken? cancelToken,
  }) async {
    if (!isWebUrl(url)) throw UnsupportedWebUrl(url);
    final from = Uri.parse(origin ?? url);
    var target = Uri.parse(url);
    for (var hop = 0;; hop++) {
      final res = await _dio.getUri<T>(
        target,
        options: Options(
          responseType: type,
          followRedirects: false,
          headers: await _headersFor(target, headers, from, resumeAt: resumeAt),
        ),
        cancelToken: cancelToken,
      );
      final code = res.statusCode ?? 0;
      final loc = res.headers.value('location');
      if (code < 300 || code > 399 || loc == null) return res;
      final body = res.data;
      if (body is ResponseBody) await _discard(body);
      if (hop >= maxRedirects) throw WebFetchError(code);
      target = target.resolve(loc);
      if (!isWebUrl(target.toString())) throw UnsupportedWebUrl(target.toString());
    }
  }

  Future<Uint8List> fetchBytes(String url, Map<String, String> headers,
      {String? origin, CancelToken? cancelToken}) async {
    final res = await _get<List<int>>(url, headers,
        type: ResponseType.bytes, origin: origin, cancelToken: cancelToken);
    final code = res.statusCode ?? 0;
    if (code < 200 || code > 299) throw WebFetchError(code);
    return Uint8List.fromList(res.data ?? const []);
  }

  Future<String> fetchText(String url, Map<String, String> headers,
      {String? origin, CancelToken? cancelToken}) async {
    final bytes = await fetchBytes(url, headers,
        origin: origin, cancelToken: cancelToken);
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// [url] をチャンクごとに [onChunk] へ流す（呼び出し側がファイルに追記する）。
  /// [resumeAt] が 0 でなければ Range で続きから。[onProgress] には（再開位置を含む）
  /// 書き込み済みバイト数を渡す。総バイト数が分かれば [onTotal] で先に知らせる。全体を RAM に載せんので大きい動画でもメモリは増えない。
  /// 戻り値は期待する総バイト数（不明なら書き込んだ量）。
  Future<int> download(
    String url,
    Map<String, String> headers, {
    required int resumeAt,
    required FutureOr<void> Function(Uint8List chunk) onChunk,
    required void Function(int written) onProgress,
    void Function(int total)? onTotal,
    String? origin,
    CancelToken? cancelToken,
  }) async {
    final res = await _get<ResponseBody>(
      url,
      headers,
      type: ResponseType.stream,
      origin: origin,
      resumeAt: resumeAt,
      cancelToken: cancelToken,
    );
    final body = res.data!;
    final code = res.statusCode ?? 0;
    if (code < 200 || code > 299) {
      await _discard(body);
      throw WebFetchError(code);
    }
    if (resumeAt > 0 && code != 206) {
      await _discard(body);
      throw RangeUnsupported();
    }
    final total = int.tryParse(res.headers.value('content-length') ?? '');
    if (total != null) onTotal?.call(resumeAt + total);
    var written = resumeAt;
    await for (final chunk in body.stream) {
      await onChunk(chunk);
      written += chunk.length;
      onProgress(written);
    }
    return total != null ? resumeAt + total : written;
  }

  // 要らん応答のボディは読み切らずに捨てる（巨大な動画を無駄に落とさんため）
  Future<void> _discard(ResponseBody body) async {
    try {
      await body.stream.listen((_) {}).cancel();
    } on Exception catch (e) {
      // 既に閉じた流れの後始末で失敗しても、取得の結果には関係ない
      debugPrint('web fetch: discard failed: $e');
    }
  }
}
