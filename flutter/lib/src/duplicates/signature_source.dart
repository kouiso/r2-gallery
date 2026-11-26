import 'package:flutter/foundation.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../ui/media_tile.dart';
import '../upload/image_thumb.dart';
import '../upload/thumbs.dart' show maxThumbSourceBytes;
import 'visual_signature.dart';

/// 保存済みサムネを読む上限。Worker は 512px の JPEG / WebP しか置かないので、これを超えるのは壊れた物
const maxStoredThumbBytes = 4 * 1024 * 1024;

enum SignatureOutcomeKind {
  /// 署名ができた。送る
  signed,

  /// 中身が読めない・大きすぎる。失敗の印を送り、次回から取り直さない
  failed,

  /// この端末では作れない（Web でサムネが無い）。何も送らず、Android か PC に任せる
  deferred,

  /// 通信の失敗など、やり直せば済むかもしれない物。記録せず次の周回で拾い直す
  error,
}

/// todo 1 件を処理した結果。[upload] は送る物がある時（signed / failed）だけ入る
class SignatureOutcome {
  final SignatureOutcomeKind kind;
  final SignatureUpload? upload;
  final Object? error;
  const SignatureOutcome._(this.kind, this.upload, this.error);

  factory SignatureOutcome.signed(
    SimilarTodoItem t,
    String src,
    Uint8List sig,
  ) => SignatureOutcome._(
    SignatureOutcomeKind.signed,
    SignatureUpload.signed(
      key: t.key,
      etag: t.etag,
      src: src,
      sig: encodeVs1(sig),
    ),
    null,
  );

  factory SignatureOutcome.failed(SimilarTodoItem t, String src, String fail) =>
      SignatureOutcome._(
        SignatureOutcomeKind.failed,
        SignatureUpload.failed(key: t.key, etag: t.etag, src: src, fail: fail),
        null,
      );

  static const deferred = SignatureOutcome._(
    SignatureOutcomeKind.deferred,
    null,
    null,
  );

  factory SignatureOutcome.error(Object e) =>
      SignatureOutcome._(SignatureOutcomeKind.error, null, e);
}

/// 1 件ぶんの署名を作る口。[SignatureBackfill] のテストで差し替えるために分けてある
abstract interface class SignatureSource {
  Future<SignatureOutcome> sign(SimilarTodoItem item);
}

typedef ThumbCacheReader = Future<Uint8List?> Function(String cacheKey);
typedef ThumbMaker = Future<Uint8List?> Function(Uint8List original);
typedef SignatureEncoder =
    Future<Uint8List?> Function(Uint8List bytes, {bool fromOriginal});

/// 一覧と同じ置き場から読む。一覧で一度見たサムネは取り直さずに済み、初回の通信量（最大 2 GB 級）が減る
Future<Uint8List?> readStoredThumbCache(String cacheKey) async {
  final info = await thumbCache.getFileFromCache(cacheKey);
  if (info == null) return null;
  return info.file.readAsBytes();
}

/// 本物の取得経路。どの端末も「保存済みの 512px サムネ」のバイト列から署名を作るので、
/// Web・Android・PC ツールで同じ入力を数えることになる。
class ApiSignatureSource implements SignatureSource {
  ApiSignatureSource({
    required this.api,
    required this.lib,
    required this.writable,
    bool? isWeb,
    ThumbCacheReader? readCache,
    ThumbMaker? makeThumb,
    SignatureEncoder? encode,
  }) : isWeb = isWeb ?? kIsWeb,
       _readCache = readCache ?? readStoredThumbCache,
       _makeThumb = makeThumb ?? makeImageThumb,
       _encode = encode ?? vs1FromEncoded;

  final ApiClient api;
  final String lib;

  /// 書けるライブラリだけ、原本から作ったサムネを置き直す（読み取り専用だと 403 になるだけなので投げない）
  final bool writable;
  final bool isWeb;
  final ThumbCacheReader _readCache;
  final ThumbMaker _makeThumb;
  final SignatureEncoder _encode;

  @override
  Future<SignatureOutcome> sign(SimilarTodoItem t) {
    final thumbUrl = t.item.thumbUrl;
    if (t.item.thumbStored && thumbUrl != null) return _fromStored(t, thumbUrl);
    // Web はエンジンの ImageDescriptor が使えず（#58）原本からサムネを作れないので、手を付けずに残す
    if (isWeb) return Future.value(SignatureOutcome.deferred);
    return _fromOriginal(t);
  }

  Future<SignatureOutcome> _fromStored(SimilarTodoItem t, String url) async {
    Uint8List? bytes;
    if (!isWeb) {
      try {
        bytes = await _readCache(thumbCacheKey(url));
      } on Object catch (e) {
        // 置き場が壊れていても通信で取れば済む
        debugPrint('signature cache read failed: ${t.key}: $e');
      }
    }
    if (bytes == null || bytes.isEmpty) {
      try {
        bytes = await api.fetchBytes(url, maxBytes: maxStoredThumbBytes);
      } on TooLargeError {
        return SignatureOutcome.failed(t, 't', 'too_large');
      } on Object catch (e) {
        return SignatureOutcome.error(e);
      }
    }
    final sig = await _encode(bytes);
    if (sig == null) return SignatureOutcome.failed(t, 't', 'decode');
    return SignatureOutcome.signed(t, 't', sig);
  }

  Future<SignatureOutcome> _fromOriginal(SimilarTodoItem t) async {
    // 一覧の大きさで先に弾き、巨大な原本を落とし始めない（サムネ補完と同じ上限 #1 作業2）
    if (t.size > maxThumbSourceBytes) {
      return SignatureOutcome.failed(t, 'o', 'too_large');
    }
    final Uint8List original;
    try {
      original = await api.fetchBytes(
        t.item.url,
        maxBytes: maxThumbSourceBytes,
      );
    } on TooLargeError {
      return SignatureOutcome.failed(t, 'o', 'too_large');
    } on Object catch (e) {
      return SignatureOutcome.error(e);
    }
    final jpeg = await _makeThumb(original);
    if (jpeg == null || jpeg.isEmpty) {
      return SignatureOutcome.failed(t, 'o', 'decode');
    }
    if (writable) {
      // 置いておけば一覧も軽くなり、次からはどの端末もこの同じバイト列から署名を作れる。
      // 置けなくても署名は作れるので、失敗は捨てる
      try {
        await api.putThumb(t.item.lib ?? lib, t.key, jpeg);
      } on Object catch (e) {
        debugPrint('signature thumb put failed: ${t.key}: $e');
      }
    }
    // 置いたサムネと同じバイト列から作る。原本を直接数えると、後で他の端末がサムネから作った署名とずれる
    final sig = await _encode(jpeg, fromOriginal: true);
    if (sig == null) return SignatureOutcome.failed(t, 'o', 'decode');
    return SignatureOutcome.signed(t, 'o', sig);
  }
}
