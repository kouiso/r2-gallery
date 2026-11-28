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

/// 置き場にあったサムネと、それを取った時の応答の etag（サムネの版）。etag が無ければ版が分からない
typedef CachedThumb = ({Uint8List bytes, String? etag});
typedef ThumbCacheReader = Future<CachedThumb?> Function(String cacheKey);

/// 今 Worker が出すサムネの etag を聞く（本文は取らない）。分からなければ null
typedef ThumbVersionReader = Future<String?> Function(String url);
typedef ThumbMaker = Future<Uint8List?> Function(Uint8List original);
typedef SignatureEncoder =
    Future<Uint8List?> Function(Uint8List bytes, {bool fromOriginal});

/// 一覧と同じ置き場から読む。一覧で一度見たサムネは取り直さずに済み、初回の通信量（最大 2 GB 級）が減る
Future<CachedThumb?> readStoredThumbCache(String cacheKey) async {
  final info = await thumbCache.getFileFromCache(cacheKey);
  if (info == null) return null;
  final meta = await thumbCache.store.retrieveCacheData(cacheKey);
  return (bytes: await info.file.readAsBytes(), etag: meta?.eTag);
}

/// 弱い印（W/）と引用符を外して比べる。どちらかが無ければ同じとは言わない
bool sameThumbVersion(String? a, String? b) {
  String? norm(String? v) {
    if (v == null) return null;
    var s = v.trim();
    if (s.startsWith('W/')) s = s.substring(2);
    if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
      s = s.substring(1, s.length - 1);
    }
    return s.isEmpty ? null : s;
  }

  final x = norm(a);
  return x != null && x == norm(b);
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
    ThumbVersionReader? thumbVersion,
    ThumbMaker? makeThumb,
    SignatureEncoder? encode,
  }) : isWeb = isWeb ?? kIsWeb,
       _readCache = readCache ?? readStoredThumbCache,
       _thumbVersion = thumbVersion ?? api.headEtag,
       _makeThumb = makeThumb ?? makeImageThumb,
       _encode = encode ?? vs1FromEncoded;

  final ApiClient api;
  final String lib;

  /// 書けるライブラリだけ、原本から作ったサムネを置き直す（読み取り専用だと 403 になるだけなので投げない）
  final bool writable;
  final bool isWeb;
  final ThumbCacheReader _readCache;
  final ThumbVersionReader _thumbVersion;
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
        bytes = await _cachedIfCurrent(url);
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

  /// 置き場のサムネを、今 Worker が出すサムネと同じ版の時だけ返す。
  /// 置き場はパス（ライブラリと key）だけで引くので、key を使い回すと（ゴミ箱へ送った後に同じ名前で
  /// 上げ直す・名前を変えて重ねる）、前に同じ key に居た別の絵のサムネが残っている。それで作った署名を
  /// 新しい etag で送ると、Worker は別の絵を「ほぼ同じ」と判定し、まとめてゴミ箱へ送ってしまう
  Future<Uint8List?> _cachedIfCurrent(String url) async {
    final cached = await _readCache(thumbCacheKey(url));
    if (cached == null || cached.bytes.isEmpty || cached.etag == null) {
      return null;
    }
    String? current;
    try {
      current = await _thumbVersion(url);
    } on Object catch (e) {
      // 版を確かめられない時は置き場を使わず取り直す
      debugPrint('signature thumb version check failed: $url: $e');
      return null;
    }
    return sameThumbVersion(cached.etag, current) ? cached.bytes : null;
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
