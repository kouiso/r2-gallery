import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import 'models.dart';
import 'review_meta.dart';

class Connection {
  final String endpoint;
  final String token;
  const Connection(this.endpoint, this.token);
}

/// worker API クライアント。KMP版 ApiClient.kt と同等のエンドポイント群。
class ApiClient {
  /// [dio] と [retryDelay] はテストで通信を差し替え・待ち時間を縮めるための口。
  ApiClient({Dio? dio, this.retryDelay = const Duration(milliseconds: 300)})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              // 大きい動画をワーカー越しにPUTする経路があるので受け側は長めに取る
              receiveTimeout: const Duration(minutes: 5),
              sendTimeout: const Duration(minutes: 5),
            ));

  Connection? conn;

  final Dio _dio;
  final Duration retryDelay;

  /// 一覧系 GET の再試行回数（KMP 版 HttpRequestRetry と同じ 2 回）。
  static const _maxRetries = 2;

  void setConnection(Connection? c) => conn = c;

  // Options.headers への代入は丸ごと置き換わる。後から ..headers = で足すと Authorization が消えて
  // 401 になるので、追加のヘッダはここで一緒に渡す
  Options _auth([Map<String, dynamic>? extra]) {
    final c = conn;
    if (c == null) throw const ApiError(0, 'not configured');
    return Options(headers: {'Authorization': 'Bearer ${c.token}', ...?extra});
  }

  Never _toApiError(Object e) {
    if (e is ApiError) throw e;
    if (e is DioException) {
      throw ApiError(e.response?.statusCode ?? 0, e.message ?? 'network error');
    }
    throw ApiError(0, e.toString());
  }

  String _lib(String id) => '/v1/${Uri.encodeComponent(id)}';

  /// 古い keep-alive 接続の切断や Worker のコールドスタート 5xx のような、やり直せば通る失敗か。
  /// 4xx は入力側の問題なので繰り返しても変わらず、待たせるだけになる。
  bool _isTransient(Object e) {
    if (e is! DioException) return false;
    return switch (e.type) {
      DioExceptionType.connectionError ||
      DioExceptionType.connectionTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.sendTimeout =>
        true,
      DioExceptionType.badResponse => (e.response?.statusCode ?? 0) >= 500,
      _ => false,
    };
  }

  // 再試行は本文を持たない GET の一覧系だけに閉じる。PUT のアップロードはストリーム本文を
  // 使い切っていて再送できず、POST は二重実行になり得るので、ここには載せない
  Future<T> _get<T>(String path, T Function(Response r) read,
      {Map<String, dynamic>? query}) async {
    for (var attempt = 0;; attempt++) {
      try {
        final res = await _dio.get('${conn!.endpoint}$path',
            options: _auth(), queryParameters: query);
        return read(res);
      } catch (e) {
        if (attempt >= _maxRetries || !_isTransient(e)) throw _toApiError(e);
        await Future<void>.delayed(retryDelay);
      }
    }
  }

  Future<T> _post<T>(String path, Object? body, T Function(Response r) read) async {
    try {
      final res = await _dio.post('${conn!.endpoint}$path',
          data: body, options: _auth());
      return read(res);
    } catch (e) {
      throw _toApiError(e);
    }
  }

  /// endpoint+token が有効かを保存せずに試す（接続設定画面の検証用）。
  Future<bool> probe(String endpoint, String token) async {
    try {
      final res = await _dio.get(
        '${endpoint.replaceAll(RegExp(r'/+$'), '')}/v1/libraries',
        options: Options(headers: {'Authorization': 'Bearer ${token.trim()}'}),
      );
      return res.statusCode != null && res.statusCode! < 400;
    } catch (_) {
      return false;
    }
  }

  Future<List<Library>> libraries() => _get('/v1/libraries',
      (r) => ((r.data['libraries'] as List?) ?? const [])
          .map((e) => Library.fromJson(e as Map<String, dynamic>))
          .toList());

  Future<FolderPage> folder(String libId,
      {String prefix = '', String? cursor, bool recursive = false}) {
    return _get('${_lib(libId)}/folders', (r) {
      final items = ((r.data['items'] as List?) ?? const [])
          .map((e) => MediaItem.fromJson(e as Map<String, dynamic>))
          .toList();
      return FolderPage(
        items: items,
        cursor: r.data['cursor'] as String?,
        prefix: (r.data['prefix'] as String?) ?? prefix,
        folders: ((r.data['folders'] as List?) ?? const []).cast<String>(),
      );
    }, query: {
      'prefix': prefix,
      if (recursive) 'recursive': '1',
      // 名前順だとゴミ箱等の先頭キーに新規アップが埋もれて出てこない（新着順に揃える）
      'order': 'recent',
      if (cursor != null) 'cursor': cursor,
    });
  }

  Future<List<Album>> albums(String libId) =>
      _get('${_lib(libId)}/albums', (r) {
        return ((r.data['albums'] as List?) ?? const [])
            .map((e) => Album.fromJson(e as Map<String, dynamic>))
            .toList();
      });

  // アルバム編集とフォルダ作成（KMP 版 ApiClient.kt の albumCreate〜mkdir）。
  // テストの差し替え口を一つにするため、どれも sendJson を通す
  String _albumPath(String lib, String albumId) =>
      '${_lib(lib)}/albums/${Uri.encodeComponent(albumId)}';

  /// 作成したアルバムの id を返す。空の名前は worker が 400、読み取り専用ライブラリは 403 で弾く。
  Future<String> albumCreate(String lib, String title) async {
    final data =
        await sendJson('POST', '${_lib(lib)}/albums', body: {'title': title});
    final id = data is Map ? data['id'] : null;
    if (id is! String || id.isEmpty) {
      throw const ApiError(0, 'アルバムの作成結果を読めませんでした');
    }
    return id;
  }

  Future<void> albumRename(String lib, String albumId, String title) =>
      sendJson('PATCH', _albumPath(lib, albumId), body: {'title': title});

  Future<void> albumDelete(String lib, String albumId) =>
      sendJson('DELETE', _albumPath(lib, albumId));

  /// worker は1回500件まで、同じ項目は重ねず数えない。呼び出し側で [albumAddChunk] ごとに分ける。
  Future<void> albumAdd(String lib, String albumId, List<String> keys) =>
      sendJson('POST', '${_albumPath(lib, albumId)}/items',
          body: {'keys': keys});

  Future<void> albumRemove(String lib, String albumId, List<String> keys) =>
      sendJson('POST', '${_albumPath(lib, albumId)}/items/remove',
          body: {'keys': keys});

  /// 並び順の書き戻し。worker は今の中身と完全に同じ集合でないと 409 を返すので、
  /// 読み込み済みの一部ではなく [albumAll] で取った全件を渡す。
  Future<void> albumOrder(String lib, String albumId, List<MediaItem> items) =>
      sendJson('POST', '${_albumPath(lib, albumId)}/order', body: {
        'items': [
          for (final it in items) {'key': it.key, 'lib': it.lib ?? lib},
        ],
      });

  /// アルバムの中身を最後のページまで取る。並び替えは全件が要るため。
  Future<List<MediaItem>> albumAll(String lib, String albumId) async {
    final out = <MediaItem>[];
    String? cursor;
    do {
      final p = await album(lib, albumId, cursor: cursor, limit: 200);
      out.addAll(p.items);
      cursor = p.cursor;
    } while (cursor != null);
    return out;
  }

  /// 空のフォルダを作る（worker が `<prefix>/.keep` を置く）。
  Future<void> mkdir(String lib, String prefix) =>
      sendJson('POST', '${_lib(lib)}/ops/mkdir', body: {'prefix': prefix});

  Future<AlbumPage> album(String libId, String albumId,
      {String? cursor, int limit = 60}) {
    return _get('${_lib(libId)}/albums/${Uri.encodeComponent(albumId)}', (r) {
      final items = ((r.data['items'] as List?) ?? const [])
          .map((e) => MediaItem.fromJson(e as Map<String, dynamic>))
          .toList();
      return AlbumPage(
        items: items,
        cursor: r.data['cursor'] as String?,
        title: (r.data['title'] as String?) ?? '',
        count: (r.data['count'] as num?)?.toInt() ?? 0,
        readOnly: (r.data['readOnly'] as bool?) ?? true,
      );
    }, query: {
      'limit': limit,
      if (cursor != null) 'cursor': cursor,
    });
  }

  Future<String> trash(String libId, String key) async {
    final res = await _post('${_lib(libId)}/ops/trash', {'key': key},
        (r) => r.data as Map<String, dynamic>);
    return (res['trashKey'] as String?) ?? '';
  }

  Future<String> restore(String libId, String trashKey) async {
    final res = await _post('${_lib(libId)}/ops/restore', {'trashKey': trashKey},
        (r) => r.data as Map<String, dynamic>);
    return (res['key'] as String?) ?? '';
  }

  /// そのキーのファイルが今あれば返す。無ければ null。
  /// 専用の口は無いので、キーそのものを接頭辞にした一覧から同じキーを探す
  /// （ゴミ箱へ移したものは別の接頭辞へ動くので、ここでは見つからない）。
  Future<MediaItem?> objectAt(String libId, String key) async {
    String? cursor;
    do {
      final page = await folder(libId, prefix: key, cursor: cursor);
      for (final it in page.items) {
        if (it.key == key) return it;
      }
      cursor = page.cursor;
    } while (cursor != null);
    return null;
  }

  /// レビュー（AI講評）が無いライブラリ・項目では null が返る。
  Future<ReviewMeta?> meta(String libId, String key) =>
      _get('${_lib(libId)}/meta', (r) {
        final m = r.data['meta'];
        return m is Map<String, dynamic> ? ReviewMeta.fromJson(m) : null;
      }, query: {'key': key});

  /// 署名URLの中身をファイルへ直接落とす。大きい動画をメモリに載せないため。
  Future<void> downloadToFile(String url, String path) async {
    try {
      await _dio.download(url, path);
    } catch (e) {
      throw _toApiError(e);
    }
  }

  /// 同名・同サイズだけでは送信済みと決められない。復旧時だけ中身を照合する。
  /// 大きい動画でも、原本と応答をストリームで読み、メモリには全体を載せない。
  Future<bool> fileMatches(String url, File file, {CancelToken? cancelToken}) async {
    try {
      final size = await file.length();
      final expected = await sha256.bind(file.openRead()).first;
      final res = await _dio.get<ResponseBody>(url,
          options: Options(responseType: ResponseType.stream),
          cancelToken: cancelToken);
      final body = res.data;
      if (body == null) throw const ApiError(502, '保存済みファイルを確認できません');
      var received = 0;
      final actual = await sha256.bind(body.stream.map((chunk) {
        received += chunk.length;
        return chunk;
      })).first;
      if (received != size) {
        throw const ApiError(502, '保存済みファイルを最後まで確認できません');
      }
      return actual == expected;
    } catch (e) {
      throw _toApiError(e);
    }
  }

  void _verifyStoredObject(Object? data, String key, int size) {
    if (data is! Map || data['key'] != key || data['size'] != size) {
      throw const ApiError(502, 'アップロード結果を確認できません。再試行してください');
    }
  }

  Future<TrashPage> trashList(String libId, {String? cursor}) {
    return _get('${_lib(libId)}/trash', (r) {
      final items = ((r.data['items'] as List?) ?? const [])
          .map((e) => TrashItem.fromJson(e as Map<String, dynamic>))
          .toList();
      return TrashPage(items, r.data['cursor'] as String?,
          retentionDays: (r.data['retentionDays'] as num?)?.toInt());
    }, query: {
      if (cursor != null) 'cursor': cursor,
    });
  }

  /// オブジェクト全体を一括PUT。409 は既存キー。
  Future<void> putObject(
    String libId,
    String key,
    Uint8List bytes,
    String contentType, {
    void Function(int sent, int total)? onProgress,
    CancelToken? cancelToken,
    bool verifyStorage = false,
  }) async {
    try {
      final res = await _dio.put(
        '${conn!.endpoint}${_lib(libId)}/objects?key=${Uri.encodeQueryComponent(key)}',
        data: Stream.fromIterable([bytes]),
        options: _auth({
          'Content-Type':
              contentType.isEmpty ? 'application/octet-stream' : contentType,
          'Content-Length': bytes.length,
        }),
        onSendProgress: onProgress,
        cancelToken: cancelToken,
      );
      if (verifyStorage) _verifyStoredObject(res.data, key, bytes.length);
    } catch (e) {
      throw _toApiError(e);
    }
  }

  /// サムネを PUT する。画像は JPEG、動画は WEBP で作るので、表記は中身から決める。
  Future<void> putThumb(String libId, String key, Uint8List bytes) async {
    final type = thumbContentType(bytes);
    try {
      await _putThumb(libId, key, bytes, type);
    } on ApiError catch (e) {
      // webp しか受けん前の worker がまだ動いとる間は、これまでどおり webp の札で送る。
      // 今の worker は札より中身で形式を記録するので、どちらに当たっても保存は正しくなる
      if (e.status != 415 || type != 'image/jpeg') rethrow;
      await _putThumb(libId, key, bytes, 'image/webp');
    }
  }

  Future<void> _putThumb(
      String libId, String key, Uint8List bytes, String contentType) async {
    try {
      await _dio.put(
        '${conn!.endpoint}${_lib(libId)}/thumb?key=${Uri.encodeQueryComponent(key)}',
        data: Stream.fromIterable([bytes]),
        options: _auth(
            {'Content-Type': contentType, 'Content-Length': bytes.length}),
      );
    } catch (e) {
      throw _toApiError(e);
    }
  }

  Future<Uint8List> fetchBytes(String url) async {
    try {
      final res = await _dio.get<Uint8List>(url,
          options: Options(responseType: ResponseType.bytes));
      return res.data ?? Uint8List(0);
    } catch (e) {
      throw _toApiError(e);
    }
  }

  /// 任意メソッドで JSON を送る。アルバム編集など機能ごとのファイルから、認証とエラー変換を揃えて使うため。
  Future<dynamic> sendJson(String method, String path,
      {Object? body, Map<String, dynamic>? query}) async {
    try {
      final res = await _dio.request('${conn?.endpoint}$path',
          data: body,
          queryParameters: query,
          options: _auth().copyWith(method: method));
      return res.data;
    } catch (e) {
      throw _toApiError(e);
    }
  }

  // ---- multipart (大きいファイル用) ----

  Future<String> _multipartCreate(String libId, String key, String contentType) {
    return _post('${_lib(libId)}/objects/multipart',
        {'key': key, 'contentType': contentType},
        (r) => (r.data['uploadId'] as String?) ?? '');
  }

  Future<void> _multipartComplete(String libId, String key, String uploadId,
      List<Map<String, dynamic>> parts, {int? expectedSize}) {
    return _post('${_lib(libId)}/objects/multipart/complete',
        {'key': key, 'uploadId': uploadId, 'parts': parts}, (r) {
      if (expectedSize != null) _verifyStoredObject(r.data, key, expectedSize);
    });
  }

  /// 大きいファイルは multipart で分割アップ（R2 の最小パート 5MB に合わせる）。
  Future<void> putLargeObject(
    String libId,
    String key,
    Uint8List bytes,
    String contentType, {
    void Function(int sent, int total)? onProgress,
  }) {
    return _putMultipart(
      libId,
      key,
      contentType,
      bytes.length,
      (offset, len) async => Uint8List.sublistView(bytes, offset, offset + len),
      onProgress,
      null,
    );
  }

  /// 端末のファイルをそのまま送る。ネットから取り込んだ大きい動画をメモリに載せんよう、
  /// 小さいものだけ一括PUTし、それ以外は1パートぶんずつ読んで multipart に流す。
  Future<void> putFile(
    String libId,
    String key,
    File file,
    String contentType, {
    void Function(int sent, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final size = await file.length();
    if (size <= multipartThreshold) {
      await putObject(libId, key, await file.readAsBytes(), contentType,
          onProgress: onProgress, cancelToken: cancelToken, verifyStorage: true);
      return;
    }
    final raf = await file.open();
    try {
      await _putMultipart(libId, key, contentType, size, (offset, len) async {
        await raf.setPosition(offset);
        // read は要求より短く返ることがある。足りんまま送ると壊れた動画になる
        final buf = Uint8List(len);
        var got = 0;
        while (got < len) {
          final n = await raf.readInto(buf, got, len);
          if (n <= 0) throw const ApiError(0, 'file ended unexpectedly');
          got += n;
        }
        return buf;
      }, onProgress, cancelToken, verifyStorage: true);
    } finally {
      await raf.close();
    }
  }

  /// これを超えるものは multipart に切り替える境目。
  static const multipartThreshold = 8 * 1024 * 1024;

  Future<void> _putMultipart(
    String libId,
    String key,
    String contentType,
    int total,
    Future<Uint8List> Function(int offset, int len) readChunk,
    void Function(int sent, int total)? onProgress,
    CancelToken? cancelToken, {
    bool verifyStorage = false,
  }) async {
    const partSize = 8 * 1024 * 1024;
    final uploadId = await _multipartCreate(libId, key, contentType);
    final parts = <Map<String, dynamic>>[];
    var sent = 0;
    try {
      for (var i = 0; i < total; i += partSize) {
        final end = (i + partSize > total) ? total : i + partSize;
        final chunk = await readChunk(i, end - i);
        final partNo = parts.length + 1;
        // worker の part 受け口は PUT（POST だと届かない）
        try {
          final res = await _dio.put(
            '${conn!.endpoint}${_lib(libId)}/objects/multipart/part'
            '?key=${Uri.encodeQueryComponent(key)}&uploadId=$uploadId&part=$partNo',
            data: Stream.fromIterable([chunk]),
            options: _auth({
              'Content-Type': 'application/octet-stream',
              'Content-Length': chunk.length,
            }),
            cancelToken: cancelToken,
          );
          parts.add({
            'partNumber': res.data['partNumber'] ?? partNo,
            'etag': res.data['etag'],
          });
        } catch (e) {
          throw _toApiError(e);
        }
        sent += chunk.length;
        onProgress?.call(sent, total);
      }
      await _multipartComplete(libId, key, uploadId, parts,
          expectedSize: verifyStorage ? total : null);
    } catch (_) {
      try {
        await _post('${_lib(libId)}/objects/multipart/abort',
            {'key': key, 'uploadId': uploadId}, (r) => r.data);
      } catch (abortError) {
        // 呼び出し側に返すのは元の失敗。abort の失敗は残骸が残ったことだけ記録する
        debugPrint('multipart abort failed for $key: $abortError');
      }
      rethrow;
    }
  }
}

/// 1回の albumAdd に載せるキー数。KMP 版と同じく大きな選択でもリクエストを太らせない。
const albumAddChunk = 200;

/// 仮想アルバム「その他」。中身を書き換えられないので追加先の候補から外す。
const otherAlbumId = '__other__';

/// サムネの先頭バイトから Content-Type を決める。JPEG・WEBP 以外は worker が 415 で弾く
String thumbContentType(Uint8List b) {
  if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
    return 'image/jpeg';
  }
  bool tag(int at, String s) =>
      String.fromCharCodes(b.sublist(at, at + 4)) == s;
  if (b.length >= 12 && tag(0, 'RIFF') && tag(8, 'WEBP')) return 'image/webp';
  return 'application/octet-stream';
}
