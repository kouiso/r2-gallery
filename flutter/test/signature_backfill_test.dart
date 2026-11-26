import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/duplicates/signature_backfill.dart';
import 'package:r2_gallery/src/duplicates/signature_source.dart';
import 'package:r2_gallery/src/duplicates/visual_signature.dart';
import 'package:r2_gallery/src/upload/thumbs.dart' show maxThumbSourceBytes;

SimilarTodoItem _todo(
  String key, {
  bool stored = true,
  int size = 1000,
  String? lib,
}) => SimilarTodoItem(
  item: MediaItem(
    key: key,
    type: 'image',
    url: 'https://w.test/m/a/$key?e=1&s=x',
    thumbUrl: 'https://w.test/t/a/$key?e=1&s=x',
    thumbStored: stored,
    lib: lib,
  ),
  etag: 'etag-$key',
  size: size,
  ext: 'jpg',
);

/// todo と署名の受け口だけを持つ偽の Worker。送られた物は todo に二度と出さない（本物と同じ）
class _Api extends ApiClient {
  _Api({Map<int, List<SimilarTodoItem>>? shards}) : shards = shards ?? {};

  final Map<int, List<SimilarTodoItem>> shards;
  final List<(int, String?)> todoCalls = [];
  final List<List<SignatureUpload>> posts = [];
  final Set<String> posted = {};
  final List<String> fetched = [];
  final List<String> putThumbs = [];
  int postsInFlight = 0;
  int maxPostsInFlight = 0;
  Duration postDelay = Duration.zero;
  ApiError? postError;
  Object? fetchError;
  Uint8List fetchBody = Uint8List.fromList([1, 2, 3]);

  @override
  Future<SimilarTodoPage> similarTodo(
    String libId,
    int shard, {
    String? after,
    int? limit,
  }) async {
    todoCalls.add((shard, after));
    final all = [
      for (final t in shards[shard] ?? const <SimilarTodoItem>[])
        if (!posted.contains(t.key) &&
            (after == null || t.key.compareTo(after) > 0))
          t,
    ];
    final page = all.take(limit ?? 300).toList();
    return SimilarTodoPage(
      shard: shard,
      items: page,
      next: all.length > page.length ? page.last.key : null,
      pendingInShard: all.length,
    );
  }

  @override
  Future<SignaturePostResult> postSignatures(
    String libId,
    List<SignatureUpload> items, {
    String alg = similarAlg,
  }) async {
    postsInFlight++;
    if (postsInFlight > maxPostsInFlight) maxPostsInFlight = postsInFlight;
    try {
      await Future<void>.delayed(postDelay);
      final err = postError;
      if (err != null) throw err;
      posts.add(items);
      posted.addAll(items.map((i) => i.key));
      return SignaturePostResult(
        stored: items.where((i) => i.sig != null).length,
        failRecorded: items.where((i) => i.fail != null).length,
      );
    } finally {
      postsInFlight--;
    }
  }

  @override
  Future<Uint8List> fetchBytes(String url, {int? maxBytes}) async {
    fetched.add(url);
    final e = fetchError;
    if (e != null) throw e;
    if (maxBytes != null && fetchBody.length > maxBytes) {
      throw TooLargeError(maxBytes);
    }
    return fetchBody;
  }

  @override
  Future<void> putThumb(String libId, String key, Uint8List bytes) async {
    putThumbs.add('$libId:$key');
  }
}

/// 中身を作らず結果だけ返す偽の取得口。同時に何件走ったかも数える
class _Source implements SignatureSource {
  _Source(this.decide, {this.delay = Duration.zero});
  final SignatureOutcome Function(SimilarTodoItem t) decide;
  final Duration delay;
  int inFlight = 0;
  int maxInFlight = 0;
  final List<String> signed = [];
  void Function(SimilarTodoItem t)? onSign;

  @override
  Future<SignatureOutcome> sign(SimilarTodoItem t) async {
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      onSign?.call(t);
      await Future<void>.delayed(delay);
      signed.add(t.key);
      return decide(t);
    } finally {
      inFlight--;
    }
  }
}

final _sig = Uint8List(vs1SigBytes);
SignatureOutcome _ok(SimilarTodoItem t) =>
    SignatureOutcome.signed(t, 't', _sig);

List<SimilarTodoItem> _items(String prefix, int n) => [
  for (var i = 0; i < n; i++)
    _todo('$prefix/${i.toString().padLeft(4, '0')}.jpg'),
];

Uint8List _png() {
  final image = img.Image(width: 40, height: 30);
  for (final p in image) {
    p
      ..r = p.x * 6
      ..g = p.y * 8
      ..b = 90;
  }
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ApiSignatureSource', () {
    ApiSignatureSource sourceOf(
      _Api api, {
      bool isWeb = false,
      bool writable = true,
      Map<String, CachedThumb> cache = const {},
      List<String>? cacheReads,
      Uint8List? thumb,
      String? Function(String url)? version,
      List<String>? versionChecks,
    }) => ApiSignatureSource(
      api: api,
      lib: 'a',
      writable: writable,
      isWeb: isWeb,
      readCache: (k) async {
        cacheReads?.add(k);
        return cache[k];
      },
      thumbVersion: (url) async {
        versionChecks?.add(url);
        return version?.call(url);
      },
      makeThumb: (_) async => thumb,
      encode: (b, {bool fromOriginal = false}) async {
        encodedFromOriginal.add(fromOriginal);
        return b.isEmpty ? null : _sig;
      },
    );

    setUp(encodedFromOriginal.clear);

    test('保存済みサムネは置き場を先に見て、今のサムネと同じ版なら本文を取り直さない', () async {
      final api = _Api();
      final reads = <String>[];
      final checks = <String>[];
      final t = _todo('x/1.jpg');
      final src = sourceOf(
        api,
        cache: {
          'https://w.test/t/a/x/1.jpg': (
            bytes: Uint8List.fromList([9]),
            etag: '"thumb-1"',
          ),
        },
        cacheReads: reads,
        version: (_) => '"thumb-1"',
        versionChecks: checks,
      );
      final out = await src.sign(t);
      // 署名 URL のクエリは毎回変わるので、一覧と同じくパスだけの鍵で引く
      expect(reads, ['https://w.test/t/a/x/1.jpg']);
      // 版は署名 URL のまま HEAD で聞く（本文は取らない）
      expect(checks, ['https://w.test/t/a/x/1.jpg?e=1&s=x']);
      expect(api.fetched, isEmpty);
      expect(out.kind, SignatureOutcomeKind.signed);
      expect(out.upload!.toJson(), {
        'key': 'x/1.jpg',
        'etag': 'etag-x/1.jpg',
        'src': 't',
        'sig': encodeVs1(_sig),
      });
    });

    test('同じ key に前に居た別の絵のサムネが置き場に残っていても、それで署名を作らない', () async {
      // cam/1.jpg を A のままゴミ箱へ送り、後で別の写真 B を同じ名前で上げた。置き場はパスだけで
      // 引くので A のサムネが残る。それで B の etag の署名を作ると、B が A の写しと「ほぼ同じ」になる
      final oldThumb = Uint8List.fromList([1, 1, 1]);
      final newThumb = Uint8List.fromList([2, 2, 2]);
      final api = _Api()..fetchBody = newThumb;
      final encoded = <List<int>>[];
      for (final cached in <CachedThumb>[
        (bytes: oldThumb, etag: '"thumb-A"'),
        // 版の分からない古い置き場も信じない
        (bytes: oldThumb, etag: null),
      ]) {
        api.fetched.clear();
        final src = ApiSignatureSource(
          api: api,
          lib: 'a',
          writable: true,
          isWeb: false,
          readCache: (_) async => cached,
          thumbVersion: (_) async => '"thumb-B"',
          encode: (b, {bool fromOriginal = false}) async {
            encoded.add(b);
            return _sig;
          },
        );
        final out = await src.sign(_todo('cam/1.jpg'));
        expect(api.fetched, ['https://w.test/t/a/cam/1.jpg?e=1&s=x']);
        expect(out.upload!.etag, 'etag-cam/1.jpg');
        expect(encoded.last, newThumb);
      }
      expect(encoded.where((b) => b == oldThumb), isEmpty);
    });

    test('サムネの版を聞けない時は置き場を使わず取り直す', () async {
      final api = _Api()..fetchBody = Uint8List.fromList([5]);
      final encoded = <List<int>>[];
      final out = await ApiSignatureSource(
        api: api,
        lib: 'a',
        writable: true,
        isWeb: false,
        readCache: (_) async =>
            (bytes: Uint8List.fromList([9]), etag: '"thumb-1"'),
        thumbVersion: (_) async => throw const ApiError(0, 'offline'),
        encode: (b, {bool fromOriginal = false}) async {
          encoded.add(b);
          return _sig;
        },
      ).sign(_todo('x/1.jpg'));
      expect(api.fetched, ['https://w.test/t/a/x/1.jpg?e=1&s=x']);
      expect(encoded.single, [5]);
      expect(out.kind, SignatureOutcomeKind.signed);
    });

    test('etag の引用符と弱い印は比べる時に外す', () {
      expect(sameThumbVersion('"a"', 'a'), isTrue);
      expect(sameThumbVersion('W/"a"', '"a"'), isTrue);
      expect(sameThumbVersion('"a"', '"b"'), isFalse);
      expect(sameThumbVersion(null, null), isFalse);
      expect(sameThumbVersion('""', '""'), isFalse);
    });

    test('置き場に無ければサムネを通信で取る（原本は取らない）', () async {
      final api = _Api();
      final out = await sourceOf(api).sign(_todo('x/1.jpg'));
      expect(api.fetched, ['https://w.test/t/a/x/1.jpg?e=1&s=x']);
      expect(out.upload!.src, 't');
      expect(api.putThumbs, isEmpty);
    });

    test('Web は置き場を使わず通信で取る', () async {
      final api = _Api();
      final reads = <String>[];
      final out = await sourceOf(
        api,
        isWeb: true,
        cacheReads: reads,
      ).sign(_todo('x/1.jpg'));
      expect(reads, isEmpty);
      expect(api.fetched, hasLength(1));
      expect(out.kind, SignatureOutcomeKind.signed);
    });

    test('大きすぎる原本は落とさずに too_large を付ける', () async {
      final api = _Api();
      final out = await sourceOf(
        api,
        thumb: Uint8List.fromList([1]),
      ).sign(_todo('x/big.jpg', stored: false, size: maxThumbSourceBytes + 1));
      expect(api.fetched, isEmpty);
      expect(out.kind, SignatureOutcomeKind.failed);
      expect(out.upload!.toJson(), {
        'key': 'x/big.jpg',
        'etag': 'etag-x/big.jpg',
        'src': 'o',
        'fail': 'too_large',
      });
    });

    test('取ってみて上限を超えた原本も too_large', () async {
      final api = _Api()..fetchError = const TooLargeError(maxThumbSourceBytes);
      final out = await sourceOf(
        api,
        thumb: Uint8List.fromList([1]),
      ).sign(_todo('x/big.jpg', stored: false, size: 0));
      expect(out.upload!.fail, 'too_large');
    });

    test('サムネの無い原本は Android で縮小し、書けるライブラリにだけサムネを置く', () async {
      final api = _Api();
      final jpeg = Uint8List.fromList([7, 7]);
      final out = await sourceOf(
        api,
        thumb: jpeg,
      ).sign(_todo('x/o.png', stored: false));
      expect(api.fetched, ['https://w.test/m/a/x/o.png?e=1&s=x']);
      expect(api.putThumbs, ['a:x/o.png']);
      expect(out.upload!.src, 'o');
      expect(encodedFromOriginal, [true]);

      final ro = _Api();
      final out2 = await sourceOf(
        ro,
        writable: false,
        thumb: jpeg,
      ).sign(_todo('x/o.png', stored: false));
      expect(ro.putThumbs, isEmpty);
      expect(out2.kind, SignatureOutcomeKind.signed);
    });

    test('保存済みサムネのある物にはサムネを置き直さない', () async {
      final api = _Api();
      await sourceOf(
        api,
        thumb: Uint8List.fromList([1]),
      ).sign(_todo('x/1.jpg'));
      expect(api.putThumbs, isEmpty);
    });

    test('サムネを置けなくても署名は送る', () async {
      final api = _ThrowingPutApi();
      final out = await ApiSignatureSource(
        api: api,
        lib: 'a',
        writable: true,
        isWeb: false,
        makeThumb: (_) async => Uint8List.fromList([1]),
        encode: (b, {bool fromOriginal = false}) async => _sig,
      ).sign(_todo('x/o.png', stored: false));
      expect(out.kind, SignatureOutcomeKind.signed);
    });

    test('Web でサムネの無い物は手を付けずに残す', () async {
      final api = _Api();
      final out = await sourceOf(
        api,
        isWeb: true,
        thumb: Uint8List.fromList([1]),
      ).sign(_todo('x/o.png', stored: false));
      expect(out.kind, SignatureOutcomeKind.deferred);
      expect(out.upload, isNull);
      expect(api.fetched, isEmpty);
      expect(api.putThumbs, isEmpty);
    });

    test('縮小できない原本と読めないサムネは decode を付ける', () async {
      final api = _Api();
      final o = await sourceOf(api).sign(_todo('x/o.png', stored: false));
      expect((o.upload!.src, o.upload!.fail), ('o', 'decode'));
      final t = await sourceOf(
        _Api()..fetchBody = Uint8List(0),
      ).sign(_todo('x/1.jpg'));
      expect((t.upload!.src, t.upload!.fail), ('t', 'decode'));
    });

    test('通信の失敗は記録しない', () async {
      final api = _Api()..fetchError = const ApiError(503, 'down');
      final t = await sourceOf(api).sign(_todo('x/1.jpg'));
      expect(t.kind, SignatureOutcomeKind.error);
      expect(t.upload, isNull);
      final o = await sourceOf(
        api,
        thumb: Uint8List.fromList([1]),
      ).sign(_todo('x/o.png', stored: false));
      expect(o.kind, SignatureOutcomeKind.error);
    });

    test('本物の vs1FromEncoded で作った署名を送る', () async {
      final png = _png();
      final api = _Api()..fetchBody = png;
      final out = await ApiSignatureSource(
        api: api,
        lib: 'a',
        writable: true,
        isWeb: false,
        readCache: (_) async => null,
      ).sign(_todo('x/1.png'));
      final sig = base64Url.decode(out.upload!.sig!);
      expect(sig, await vs1FromEncoded(png));
      expect(sig[296] & vs1FlagFromOriginal, 0);
    });
  });

  group('SignatureBackfill', () {
    test('全 shard を順に読み、ページの終わりと 100 件ごとに送る', () async {
      final api = _Api(shards: {0: _items('s0', 250), 5: _items('s5', 30)});
      final src = _Source(_ok);
      final progress = <BackfillProgress>[];
      final b = SignatureBackfill(
        api: api,
        lib: 'a',
        source: src,
        total: 280,
        onProgress: progress.add,
      );
      final r = await b.run();
      expect(r.end, BackfillEnd.completed);
      expect(api.posts.map((p) => p.length), [100, 100, 50, 30]);
      expect(api.posted, hasLength(280));
      expect(api.todoCalls.map((c) => c.$1).toSet(), {
        for (var i = 0; i < 32; i++) i,
      });
      expect(r.progress.done, 280);
      expect(r.progress.stored, 280);
      expect(progress.last.total, 280);
      expect(progress.map((p) => p.done), containsAllInOrder([1, 100, 280]));
    });

    test('Worker が下げた上限（postLimit）を超えて送らない', () async {
      final api = _Api(shards: {0: _items('s0', 250), 5: _items('s5', 30)});
      final b = SignatureBackfill(
        api: api,
        lib: 'a',
        source: _Source(_ok),
        postLimit: 40,
      );
      final r = await b.run();
      expect(r.end, BackfillEnd.completed);
      expect(api.posts.every((p) => p.length <= 40), isTrue);
      expect(api.posted, hasLength(280));
    });

    test('ページを跨いで after を渡して読み進める', () async {
      final api = _Api(shards: {3: _items('s3', 7)});
      final b = SignatureBackfill(
        api: api,
        lib: 'a',
        source: _Source(_ok),
        pageLimit: 3,
        postEvery: 100,
      );
      await b.run();
      expect(api.todoCalls.where((c) => c.$1 == 3).toList(), [
        (3, null),
        (3, 's3/0002.jpg'),
        (3, 's3/0005.jpg'),
      ]);
      expect(api.posts.map((p) => p.length), [3, 3, 1]);
    });

    test('作るのは最大 6 件ずつ、送るのは常に 1 本', () async {
      final api = _Api(shards: {0: _items('s0', 400)})
        ..postDelay = const Duration(milliseconds: 5);
      final src = _Source(_ok, delay: const Duration(milliseconds: 1));
      final b = SignatureBackfill(
        api: api,
        lib: 'a',
        source: src,
        concurrency: 6,
      );
      await b.run();
      expect(src.maxInFlight, 6);
      expect(api.maxPostsInFlight, 1);
      expect(api.posted, hasLength(400));
      expect(
        api.posts.every((p) => p.length <= SignatureBackfill.maxPostBatch),
        isTrue,
      );
    });

    test('Web は既定で 3 件ずつ、Android は 6 件ずつ', () {
      final b = SignatureBackfill(api: _Api(), lib: 'a', source: _Source(_ok));
      // テストは端末側（非 Web）で走る
      expect(b.concurrency, 6);
    });

    test('失敗の印も送る', () async {
      final items = _items('s0', 4);
      final api = _Api(shards: {0: items});
      final b = SignatureBackfill(
        api: api,
        lib: 'a',
        source: _Source(
          (t) => t.key.endsWith('1.jpg')
              ? SignatureOutcome.failed(t, 'o', 'decode')
              : _ok(t),
        ),
      );
      final r = await b.run();
      final sent = api.posts.expand((p) => p).toList();
      expect(sent.where((u) => u.fail != null).map((u) => u.toJson()), [
        {
          'key': 's0/0001.jpg',
          'etag': 'etag-s0/0001.jpg',
          'src': 'o',
          'fail': 'decode',
        },
      ]);
      expect(r.progress.failed, 1);
      expect(r.progress.done, 4);
      expect(r.end, BackfillEnd.completed);
    });

    test('この端末で作れない物は送らずに数えるだけ', () async {
      final api = _Api(
        shards: {
          0: [
            _todo('a.jpg'),
            _todo('b.jpg', stored: false),
            _todo('c.jpg', stored: false),
          ],
        },
      );
      final b = SignatureBackfill(
        api: api,
        lib: 'a',
        source: ApiSignatureSource(
          api: api,
          lib: 'a',
          writable: true,
          isWeb: true,
          encode: (b, {bool fromOriginal = false}) async => _sig,
        ),
      );
      final r = await b.run();
      expect(r.end, BackfillEnd.completed);
      expect(r.progress.deferredHere, 2);
      expect(api.posted, {'a.jpg'});
      expect(api.putThumbs, isEmpty);
    });

    test('止めたら作り終えた分を送って止まり、次はその場所から続ける', () async {
      final api = _Api(
        shards: {0: _items('s0', 5), 4: _items('s4', 40), 9: _items('s9', 5)},
      );
      late SignatureBackfill b;
      final src = _Source(_ok);
      var n = 0;
      src.onSign = (t) {
        if (++n == 12) b.cancel();
      };
      b = SignatureBackfill(api: api, lib: 'a', source: src, concurrency: 2);
      final first = await b.run();
      expect(first.end, BackfillEnd.cancelled);
      // 走っていた分は送ってから止まる。shard 9 にはまだ手を付けていない
      expect(api.posted.length, 12);
      expect(api.posted.any((k) => k.startsWith('s9/')), isFalse);
      final callsBefore = api.todoCalls.length;

      src.onSign = null;
      final second = await b.run();
      expect(second.end, BackfillEnd.completed);
      // 最初からではなく、止めた shard 4 のページの頭から読み直す
      expect(api.todoCalls[callsBefore], (4, null));
      expect(api.posted, hasLength(50));
      // 同じ物を二度は作らない
      expect(src.signed.toSet(), hasLength(src.signed.length));
      expect(second.progress.done, 50);
    });

    test('進まない周回が 3 回続いたら打ち切る', () async {
      final api = _Api(shards: {2: _items('s2', 3)});
      final b = SignatureBackfill(
        api: api,
        lib: 'a',
        source: _Source(
          (t) => SignatureOutcome.error(const ApiError(0, 'offline')),
        ),
      );
      final r = await b.run();
      expect(r.end, BackfillEnd.stalled);
      expect(
        api.todoCalls.where((c) => c.$1 == 2),
        hasLength(SignatureBackfill.stallLimit),
      );
      expect(api.posts, isEmpty);
      expect(r.progress.errors, 3);
    });

    test('一度失敗しても次の周回で作れれば最後まで進む', () async {
      final api = _Api(shards: {1: _items('s1', 4)});
      final flaky = <String>{'s1/0002.jpg'};
      final b = SignatureBackfill(
        api: api,
        lib: 'a',
        source: _Source(
          (t) => flaky.remove(t.key)
              ? SignatureOutcome.error(const ApiError(503, 'busy'))
              : _ok(t),
        ),
      );
      final r = await b.run();
      expect(r.end, BackfillEnd.completed);
      expect(api.posted, hasLength(4));
      expect(r.progress.errors, 0);
    });

    test('送るのに失敗した分は作り直す', () async {
      final api = _Api(shards: {0: _items('s0', 3)})
        ..postError = const ApiError(503, 'busy');
      final b = SignatureBackfill(api: api, lib: 'a', source: _Source(_ok));
      final r = await b.run();
      expect(r.end, BackfillEnd.stalled);
      expect(r.progress.done, 0);
      api.postError = null;
      final again = await b.run();
      expect(again.end, BackfillEnd.completed);
      expect(api.posted, hasLength(3));
    });

    test('409 alg_mismatch はアプリの更新が要るとして止まる', () async {
      final api = _Api(shards: {0: _items('s0', 3), 1: _items('s1', 3)})
        ..postError = const ApiError(409, 'alg_mismatch', code: 'alg_mismatch');
      final b = SignatureBackfill(api: api, lib: 'a', source: _Source(_ok));
      final r = await b.run();
      expect(r.end, BackfillEnd.appUpdateNeeded);
      expect(api.todoCalls.map((c) => c.$1), [0]);
      expect(r.progress.done, 0);
    });

    test('todo が読めない（古い Worker の 404）は failed で返す', () async {
      final b = SignatureBackfill(
        api: _NoTodoApi(),
        lib: 'a',
        source: _Source(_ok),
      );
      final r = await b.run();
      expect(r.end, BackfillEnd.failed);
      expect((r.error as ApiError).status, 404);
    });

    test('走っている間に run を呼んでも二重に回さない', () async {
      final api = _Api(shards: {0: _items('s0', 20)});
      final src = _Source(_ok, delay: const Duration(milliseconds: 1));
      final b = SignatureBackfill(api: api, lib: 'a', source: src);
      final f1 = b.run();
      final f2 = b.run();
      expect(identical(f1, f2), isTrue);
      await f1;
      expect(src.signed, hasLength(20));
      expect(b.running, isFalse);
    });
  });
}

/// 偽の encode が受けた fromOriginal。原本から作った時だけ印を立てるかを見る
final encodedFromOriginal = <bool>[];

class _ThrowingPutApi extends _Api {
  @override
  Future<void> putThumb(String libId, String key, Uint8List bytes) async {
    throw const ApiError(403, 'read_only_library', code: 'read_only_library');
  }
}

class _NoTodoApi extends _Api {
  @override
  Future<SimilarTodoPage> similarTodo(
    String libId,
    int shard, {
    String? after,
    int? limit,
  }) => Future.error(const ApiError(404, 'not found'));
}
