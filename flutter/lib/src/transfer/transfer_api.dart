import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../api/client.dart';
import '../api/models.dart';

/// multipart の確定済みパート。再開時に送り直さないよう台帳に残す。
class UploadPart {
  final int partNumber;
  final String etag;
  const UploadPart(this.partNumber, this.etag);

  Map<String, Object> toJson() => {'partNumber': partNumber, 'etag': etag};

  static UploadPart? fromJson(Object? j) {
    if (j is! Map) return null;
    final n = j['partNumber'], e = j['etag'];
    if (n is! num || e is! String) return null;
    return UploadPart(n.toInt(), e);
  }
}

/// 転送キューが使う worker API の一部。KMP 版 QueueApi に対応し、テストで差し替えられる。
abstract class TransferApi {
  Future<String> multipartCreate(String lib, String key, String contentType);
  Future<UploadPart> putPart(String lib, String key, String uploadId, int part,
      Uint8List bytes,
      {CancelToken? cancelToken, void Function(int sent)? onProgress});
  Future<void> multipartComplete(
      String lib, String key, String uploadId, List<UploadPart> parts);
  Future<void> multipartAbort(String lib, String key, String uploadId);

  /// 積んだ時の接続へ abort を送る。行が覚えている接続に送るのが正しいので、
  /// 送り先ごと渡す。接続を切り替えられる実装を持たない場合は今の接続へ送る
  Future<void> multipartAbortOn(String endpoint, String token, String lib,
          String key, String uploadId) =>
      multipartAbort(lib, key, uploadId);
  /// [sha256] は重複確認で計算済みの時だけ渡す（Worker へ x-content-sha256 で添える）。
  Future<void> putObject(String lib, String key, Uint8List bytes, String mime,
      {CancelToken? cancelToken,
      void Function(int sent)? onProgress,
      String? sha256});
  Future<void> putThumb(String lib, String key, Uint8List bytes);
  Future<Uint8List> fetchBytes(String url,
      {CancelToken? cancelToken, void Function(int got, int total)? onProgress});

  /// そのキーに今ある物が、手元の中身（local）と同じか。無ければ false。
  /// 同名・同サイズだけでは同じと決められないので、中身をストリームで逐次照合する。
  /// 違うバイトで打ち切るので、別物なら最後まで読まない。[onProgress] には
  /// 照合の済んだバイト数が来る（#144）。
  Future<bool> storedMatches(
      String lib, String key, int size, Stream<List<int>> Function() local,
      {CancelToken? cancelToken, void Function(int matched)? onProgress});

  /// 署名URLは期限が切れるので、一覧から取り直す。見つからなければ null。
  Future<String?> itemUrl(String lib, String key);

  /// JPEG の写しの署名 URL を一覧から取り直す。写しが無ければ null。
  Future<String?> itemViewUrl(String lib, String key);

  /// アップロード確定後に、そのキーをアルバムへ入れる（#102）。
  /// 失敗しても上げ直しにはしないので、呼び出し側が結果だけ記録する。
  Future<void> albumAdd(String lib, String albumId, List<String> keys);
}

/// 本物の ApiClient の接続情報を使う実装。パート単位の呼び出しは ApiClient に無いのでここで持つ。
class ApiClientTransferApi implements TransferApi {
  ApiClientTransferApi(this.api);
  final ApiClient api;

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(minutes: 5),
    sendTimeout: const Duration(minutes: 5),
  ));

  Connection get _conn {
    final c = api.conn;
    if (c == null) throw const ApiError(0, 'not configured');
    return c;
  }

  String _base(String lib) => '${_conn.endpoint}/v1/${Uri.encodeComponent(lib)}';

  Options _auth([Map<String, Object>? extra]) =>
      Options(headers: {'Authorization': 'Bearer ${_conn.token}', ...?extra});

  ApiError _err(Object e) {
    if (e is ApiError) return e;
    if (e is DioException) {
      final body = e.response?.data;
      final code = body is Map ? body['error'] : null;
      final o = e.requestOptions;
      return ApiError(e.response?.statusCode ?? 0, e.message ?? 'network error',
          code: code is String ? code : null,
          request: '${o.method} ${o.uri.path}',
          kind: e.type.name);
    }
    return ApiError(0, e.toString());
  }

  Future<Map<String, Object?>> _postJson(String url, Object body) =>
      _postJsonConn(_conn, url, body);

  Future<Map<String, Object?>> _postJsonConn(
      Connection conn, String url, Object body) async {
    try {
      final res = await _dio.post<Object?>(url,
          data: body,
          options: Options(headers: {'Authorization': 'Bearer ${conn.token}'}));
      final d = res.data;
      return d is Map<String, Object?> ? d : const {};
    } catch (e) {
      throw _err(e);
    }
  }

  @override
  Future<String> multipartCreate(String lib, String key, String contentType) async {
    final d = await _postJson('${_base(lib)}/objects/multipart',
        {'key': key, 'contentType': contentType});
    final id = d['uploadId'];
    if (id is! String || id.isEmpty) throw const ApiError(0, 'no uploadId');
    return id;
  }

  @override
  Future<UploadPart> putPart(String lib, String key, String uploadId, int part,
      Uint8List bytes,
      {CancelToken? cancelToken, void Function(int sent)? onProgress}) async {
    try {
      // worker の part 受け口は PUT（POST だと届かない）
      final res = await _dio.put<Object?>(
        '${_base(lib)}/objects/multipart/part'
        '?key=${Uri.encodeQueryComponent(key)}&uploadId=${Uri.encodeQueryComponent(uploadId)}&part=$part',
        data: Stream.fromIterable([bytes]),
        options: _auth({
          'Content-Type': 'application/octet-stream',
          'Content-Length': bytes.length,
        }),
        cancelToken: cancelToken,
        onSendProgress: onProgress == null ? null : (s, _) => onProgress(s),
      );
      final d = res.data;
      final n = d is Map ? d['partNumber'] : null;
      final etag = d is Map ? d['etag'] : null;
      if (etag is! String) throw const ApiError(0, 'no etag');
      return UploadPart(n is num ? n.toInt() : part, etag);
    } catch (e) {
      throw _err(e);
    }
  }

  @override
  Future<void> multipartComplete(
      String lib, String key, String uploadId, List<UploadPart> parts) async {
    await _postJson('${_base(lib)}/objects/multipart/complete', {
      'key': key,
      'uploadId': uploadId,
      'parts': [for (final p in parts) p.toJson()],
    });
  }

  @override
  Future<void> multipartAbort(String lib, String key, String uploadId) async {
    await _postJson('${_base(lib)}/objects/multipart/abort',
        {'key': key, 'uploadId': uploadId});
  }

  @override
  Future<void> multipartAbortOn(String endpoint, String token, String lib,
      String key, String uploadId) async {
    final conn = Connection(endpoint, token);
    await _postJsonConn(
        conn,
        '${conn.endpoint}/v1/${Uri.encodeComponent(lib)}/objects/multipart/abort',
        {'key': key, 'uploadId': uploadId});
  }

  @override
  Future<void> putObject(String lib, String key, Uint8List bytes, String mime,
          {CancelToken? cancelToken,
          void Function(int sent)? onProgress,
          String? sha256}) =>
      api.putObject(lib, key, bytes, mime,
          cancelToken: cancelToken,
          onProgress: onProgress == null ? null : (s, _) => onProgress(s),
          sha256: sha256);

  @override
  Future<void> putThumb(String lib, String key, Uint8List bytes) =>
      api.putThumb(lib, key, bytes);

  @override
  Future<void> albumAdd(String lib, String albumId, List<String> keys) =>
      api.albumAdd(lib, albumId, keys);

  @override
  Future<Uint8List> fetchBytes(String url,
      {CancelToken? cancelToken,
      void Function(int got, int total)? onProgress}) async {
    try {
      // 署名URLなのでトークンは付けない（別ホストへ漏らさない）
      final res = await _dio.get<List<int>>(url,
          options: Options(responseType: ResponseType.bytes),
          cancelToken: cancelToken,
          onReceiveProgress: onProgress);
      final d = res.data;
      if (d == null) return Uint8List(0);
      return d is Uint8List ? d : Uint8List.fromList(d);
    } catch (e) {
      throw _err(e);
    }
  }

  @override
  Future<bool> storedMatches(
      String lib, String key, int size, Stream<List<int>> Function() local,
      {CancelToken? cancelToken,
      void Function(int matched)? onProgress}) async {
    final there = await api.objectAt(lib, key);
    if (there == null || (there.size != null && there.size != size)) return false;
    try {
      final res = await _dio.get<ResponseBody>(there.url,
          options: Options(responseType: ResponseType.stream),
          cancelToken: cancelToken);
      final body = res.data;
      if (body == null) throw const ApiError(502, '保存済みファイルを確認できません');
      // 両側をストリームで逐次比べる。違うバイトが出た時点で切り、
      // 「同じ」と決める時だけ全体を読む（#144）
      final it = StreamIterator(local());
      var rest = const <int>[];
      var matched = 0;
      var localHasMore = false;
      try {
        await for (final rc in body.stream) {
          var off = 0;
          while (off < rc.length) {
            while (rest.length < rc.length - off) {
              if (!await it.moveNext()) return false; // 手元が短い＝別物
              rest = [...rest, ...it.current];
            }
            final need = rc.length - off;
            for (var i = 0; i < need; i++) {
              if (rest[i] != rc[off + i]) return false;
            }
            rest = rest.sublist(need);
            off += need;
          }
          matched += rc.length;
          onProgress?.call(matched);
        }
        // 受け側が尽きた後に手元に余りがあれば別物
        localHasMore = rest.isNotEmpty || await it.moveNext();
      } finally {
        await it.cancel();
      }
      // 受け取った量が公称サイズと違う、または手元に残りがあれば別物
      if (matched != size || localHasMore) return false;
      return true;
    } catch (e) {
      throw _err(e);
    }
  }

  @override
  Future<String?> itemUrl(String lib, String key) async {
    String? cursor;
    do {
      final page = await api.folder(lib, cursor: cursor, recursive: true);
      for (final it in page.items) {
        if (it.key == key) return it.url;
      }
      cursor = page.cursor;
    } while (cursor != null);
    return null;
  }

  @override
  Future<String?> itemViewUrl(String lib, String key) async {
    String? cursor;
    do {
      final page = await api.folder(lib, cursor: cursor, recursive: true);
      for (final it in page.items) {
        if (it.key == key) return it.viewUrl;
      }
      cursor = page.cursor;
    } while (cursor != null);
    return null;
  }
}
