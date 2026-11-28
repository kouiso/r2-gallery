import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';

/// 届いた要求を記録し、決めた応答を返すだけの Worker。本物の Dio で往復させる。
class _Recorder {
  late final HttpServer server;
  final List<
    ({
      String method,
      String path,
      Map<String, String> query,
      Object? body,
      String? auth,
    })
  >
  seen = [];
  final Map<String, (int, Object)> replies = {};

  String get base => 'http://127.0.0.1:${server.port}';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async {
      final raw = await utf8.decoder.bind(r).join();
      seen.add((
        method: r.method,
        path: r.uri.path,
        query: r.uri.queryParameters,
        body: raw.isEmpty ? null : jsonDecode(raw),
        auth: r.headers.value('authorization'),
      ));
      final reply =
          replies['${r.method} ${r.uri.path}'] ?? (404, {'error': 'not_found'});
      r.response.statusCode = reply.$1;
      r.response.headers.contentType = ContentType.json;
      r.response.write(jsonEncode(reply.$2));
      await r.response.close();
    });
  }
}

void main() {
  late _Recorder w;
  late ApiClient api;

  setUp(() async {
    w = _Recorder();
    await w.start();
    api = ApiClient(retryDelay: Duration.zero)
      ..setConnection(Connection(w.base, 'tok'));
  });
  tearDown(() => w.server.close(force: true));

  Map<String, Object?> media(String key, {int size = 100}) => {
    'key': key,
    'lib': 'lib',
    'type': 'image',
    'url': 'https://w.example/m/$key',
    'thumbUrl': 'https://w.example/t/$key',
    'thumbStored': true,
    'viewUrl': null,
    'note': null,
    'createdAt': 1000,
    'size': size,
  };

  Matcher apiError(int status, String code) => throwsA(
    isA<ApiError>()
        .having((e) => e.status, 'status', status)
        .having((e) => e.code, 'code', code),
  );

  group('status', () {
    test('GET /similar/status を認証付きで読み、全項目を数で返す', () async {
      w.replies['GET /v1/lib/similar/status'] = (
        200,
        {
          'alg': 'vs1',
          'params': 'p1',
          'images': 120,
          'signed': 90,
          'failed': 3,
          'flat': 2,
          'pending': 25,
          'pendingWithThumb': 20,
          'pendingNoThumb': 5,
          'pendingBytesEstimate': 819200 + 5 * 1024 * 1024,
          'sigBatch': 50,
          'trashBatch': 10,
          'maxNodes': 40000,
          'tooMany': true,
        },
      );
      final s = await api.similarStatus('lib');
      expect((s.sigBatch, s.trashBatch), (50, 10));
      expect((s.maxNodes, s.tooMany), (40000, true));
      expect(w.seen.single.method, 'GET');
      expect(w.seen.single.auth, 'Bearer tok');
      expect(
        (s.alg, s.params, s.images, s.signed, s.failed, s.flat),
        ('vs1', 'p1', 120, 90, 3, 2),
      );
      expect((s.pending, s.pendingWithThumb, s.pendingNoThumb), (25, 20, 5));
      expect(s.pendingBytesEstimate, 819200 + 5 * 1024 * 1024);
    });

    test('ライブラリ名は URL に入る前に符号化される', () async {
      w.replies['GET /v1/a%20b/similar/status'] = (200, {'images': 1});
      final s = await api.similarStatus('a b');
      expect(s.images, 1);
      expect(s.pending, 0);
      // 古い Worker は上限を返さない。アプリは自分の上限で送る
      expect((s.sigBatch, s.trashBatch), (null, null));
      expect((s.maxNodes, s.tooMany), (null, false));
    });

    test('古い Worker の 404 は status 404 の ApiError になり、再試行しない', () async {
      await expectLater(api.similarStatus('lib'), apiError(404, 'not_found'));
      expect(w.seen, hasLength(1));
    });

    test('大きすぎるライブラリの 413 は code で見分けられる', () async {
      w.replies['GET /v1/lib/similar'] = (
        413,
        {'error': 'too_many_for_similar'},
      );
      await expectLater(
        api.similarGroups('lib', 'dup'),
        apiError(413, 'too_many_for_similar'),
      );
    });
  });

  group('todo', () {
    test('shard・after・limit を付けて GET し、項目を MediaItem 付きで読む', () async {
      w.replies['GET /v1/lib/similar/todo'] = (
        200,
        {
          'shard': 7,
          'items': [
            {
              'key': 'a/x.jpg',
              'etag': 'e1',
              'size': 2048,
              'ext': 'jpg',
              'url': 'https://w.example/m/a/x.jpg',
              'thumbUrl': 'https://w.example/t/a/x.jpg',
              'thumbStored': true,
            },
            {
              'key': 'a/y.png',
              'etag': 'e2',
              'size': 4096,
              'ext': 'png',
              'url': 'https://w.example/m/a/y.png',
              'thumbUrl': 'https://w.example/t/a/y.png',
              'thumbStored': false,
            },
          ],
          'next': 'a/y.png',
          'pendingInShard': 40,
        },
      );
      final p = await api.similarTodo('lib', 7, after: 'a/w.jpg', limit: 300);
      expect(w.seen.single.query, {
        'shard': '7',
        'after': 'a/w.jpg',
        'limit': '300',
      });
      expect((p.shard, p.next, p.pendingInShard), (7, 'a/y.png', 40));
      expect(p.items.map((i) => (i.key, i.etag, i.size, i.ext)), [
        ('a/x.jpg', 'e1', 2048, 'jpg'),
        ('a/y.png', 'e2', 4096, 'png'),
      ]);
      final first = p.items.first.item;
      // todo は type と lib を省くので、画像としてこのライブラリの物に寄せる
      expect((first.type, first.lib, first.size), ('image', 'lib', 2048));
      expect(first.thumbUrl, 'https://w.example/t/a/x.jpg');
      expect(p.items.map((i) => i.item.thumbStored), [true, false]);
    });

    test('after と limit を省くと付けず、読み切った shard は next が null', () async {
      w.replies['GET /v1/lib/similar/todo'] = (
        200,
        {'shard': 0, 'items': [], 'next': null, 'pendingInShard': 0},
      );
      final p = await api.similarTodo('lib', 0);
      expect(w.seen.single.query, {'shard': '0'});
      expect(p.items, isEmpty);
      expect(p.next, isNull);
    });
  });

  group('signatures', () {
    test('alg と署名・失敗の印を送り、stored/stale/failRecorded を読む', () async {
      w.replies['POST /v1/lib/similar/signatures'] = (
        200,
        {'stored': 1, 'stale': 1, 'failRecorded': 1},
      );
      final sig = 'A' * 396;
      final r = await api.postSignatures('lib', [
        SignatureUpload.signed(key: 'a/x.jpg', etag: 'e1', src: 't', sig: sig),
        const SignatureUpload.failed(
          key: 'a/y.png',
          etag: 'e2',
          src: 'o',
          fail: 'too_large',
        ),
        const SignatureUpload.failed(
          key: 'a/z.gif',
          etag: 'e3',
          src: 'o',
          fail: 'decode',
        ),
      ]);
      expect(w.seen.single.method, 'POST');
      expect(w.seen.single.body, {
        'alg': 'vs1',
        'items': [
          {'key': 'a/x.jpg', 'etag': 'e1', 'src': 't', 'sig': sig},
          {'key': 'a/y.png', 'etag': 'e2', 'src': 'o', 'fail': 'too_large'},
          {'key': 'a/z.gif', 'etag': 'e3', 'src': 'o', 'fail': 'decode'},
        ],
      });
      expect((r.stored, r.stale, r.failRecorded), (1, 1, 1));
    });

    test('方式の食い違いは 409 alg_mismatch、形の誤りは 400 bad_items', () async {
      w.replies['POST /v1/lib/similar/signatures'] = (
        409,
        {'error': 'alg_mismatch'},
      );
      await expectLater(
        api.postSignatures('lib', const []),
        apiError(409, 'alg_mismatch'),
      );
      expect(w.seen.single.body, {'alg': 'vs1', 'items': <Object>[]});
      w.replies['POST /v1/lib/similar/signatures'] = (
        400,
        {'error': 'bad_items'},
      );
      await expectLater(
        api.postSignatures('lib', const [
          SignatureUpload.signed(key: 'k', etag: 'e', src: 't', sig: 'x'),
        ]),
        apiError(400, 'bad_items'),
      );
    });

    test('POST は 5xx でも繰り返さない（二重の書き込みを避ける）', () async {
      w.replies['POST /v1/lib/similar/signatures'] = (503, {'error': 'busy'});
      await expectLater(
        api.postSignatures('lib', const []),
        apiError(503, 'busy'),
      );
      expect(w.seen, hasLength(1));
    });
  });

  group('groups', () {
    final page = {
      'groups': [
        {
          'id': 'a/keep.png',
          'tier': 'dup',
          'reclaim': 300,
          'items': [
            {
              ...media('a/keep.png', size: 500),
              'match': 'keeper',
              'ow': 2000,
              'oh': 1500,
            },
            {...media('b/copy.png', size: 500), 'match': 'identical'},
            {
              ...media('b/re.jpg', size: 200),
              'match': 'same',
              'ph': 2,
              'dh': 3,
              'variant': false,
              'ow': 1000,
              'oh': 750,
            },
            {
              ...media('b/edit.png', size: 450),
              'match': 'same',
              'ph': 1,
              'dh': 0,
              'variant': true,
              'ow': 2000,
              'oh': 1500,
            },
            {
              ...media('b/flip.jpg', size: 180),
              'match': 'mirror',
              'ph': 30,
              'dh': 40,
            },
          ],
          'more': 3,
        },
        {
          'id': 'v/a.mp4',
          'tier': 'dup',
          'reclaim': 9000,
          'items': [
            {
              ...media('v/a.mp4', size: 9000),
              'type': 'video',
              'match': 'keeper',
            },
            {
              ...media('v/b.mp4', size: 9000),
              'type': 'video',
              'match': 'identical',
            },
          ],
          'more': 0,
        },
      ],
      'cursor': 'WzMwMCwiYS9rZWVwLnBuZyJd',
      'total': 12,
      'summary': {
        'dup': {'groups': 12, 'items': 40, 'reclaimable': 123456},
        'similar': {'groups': 5, 'items': 14},
        'crowded': 1,
        'coverage': {
          'images': 100,
          'signed': 80,
          'pending': 15,
          'failed': 3,
          'flat': 2,
        },
        'hashPending': 6,
        'hashSkipped': 4,
      },
    };

    test('tab・cursor・limit を付けて GET し、組・札・合計を読む', () async {
      w.replies['GET /v1/lib/similar'] = (200, page);
      final p = await api.similarGroups('lib', 'dup', cursor: 'c0', limit: 100);
      expect(w.seen.single.query, {
        'tab': 'dup',
        'cursor': 'c0',
        'limit': '100',
      });
      expect((p.cursor, p.total), ('WzMwMCwiYS9rZWVwLnBuZyJd', 12));

      final g = p.groups.first;
      expect((g.id, g.tier, g.reclaim, g.more), ('a/keep.png', 'dup', 300, 3));
      expect(g.members.map((m) => (m.key, m.match, m.size)), [
        ('a/keep.png', 'keeper', 500),
        ('b/copy.png', 'identical', 500),
        ('b/re.jpg', 'same', 200),
        ('b/edit.png', 'same', 450),
        ('b/flip.jpg', 'mirror', 180),
      ]);
      expect(g.members.map((m) => m.isKeeper), [
        true,
        false,
        false,
        false,
        false,
      ]);
      final keeper = g.members[0];
      expect(
        (keeper.ph, keeper.dh, keeper.variant, keeper.ow, keeper.oh),
        (null, null, false, 2000, 1500),
      );
      final re = g.members[2];
      expect(
        (re.ph, re.dh, re.variant, re.ow, re.oh),
        (2, 3, false, 1000, 750),
      );
      expect(g.members[3].variant, isTrue);
      final copy = g.members[1];
      expect((copy.ph, copy.dh, copy.ow, copy.oh), (null, null, null, null));
      expect(copy.item.url, 'https://w.example/m/b/copy.png');
      expect(copy.item.size, 500);

      final v = p.groups[1];
      expect(v.members.map((m) => m.item.isVideo), [true, true]);

      final s = p.summary;
      expect((s.dup.groups, s.dup.items, s.dup.reclaimable), (12, 40, 123456));
      expect(
        (s.similar.groups, s.similar.items, s.similar.reclaimable),
        (5, 14, 0),
      );
      expect(s.crowded, 1);
      expect(
        (
          s.coverage.images,
          s.coverage.signed,
          s.coverage.pending,
          s.coverage.failed,
          s.coverage.flat,
        ),
        (100, 80, 15, 3, 2),
      );
      expect((s.hashPending, s.hashSkipped), (6, 4));
    });

    test('似ている段は tab=similar で読み、最後のページは cursor が null', () async {
      w.replies['GET /v1/lib/similar'] = (
        200,
        {
          'groups': [
            {
              'id': 'a/k.jpg',
              'tier': 'similar',
              'reclaim': 0,
              'items': [
                {...media('a/k.jpg'), 'match': 'keeper'},
                {...media('a/s.jpg'), 'match': 'similar', 'ph': 8, 'dh': 10},
              ],
              'more': 0,
            },
          ],
          'cursor': null,
          'total': 1,
          'summary': {
            'dup': {'groups': 0, 'items': 0, 'reclaimable': 0},
            'similar': {'groups': 1, 'items': 1},
            'crowded': 0,
            'coverage': {
              'images': 2,
              'signed': 2,
              'pending': 0,
              'failed': 0,
              'flat': 0,
            },
            'hashPending': 0,
            'hashSkipped': 0,
          },
        },
      );
      final p = await api.similarGroups('lib', 'similar');
      expect(w.seen.single.query, {'tab': 'similar'});
      expect(p.cursor, isNull);
      expect(p.groups.single.tier, 'similar');
      expect(p.groups.single.members.last.match, 'similar');
      expect(p.groups.single.members.last.ph, 8);
    });

    test('summary を省く応答でも既定値で読める', () async {
      w.replies['GET /v1/lib/similar'] = (200, {'groups': []});
      final p = await api.similarGroups('lib', 'dup');
      expect(p.groups, isEmpty);
      expect((p.cursor, p.total), (null, 0));
      expect((p.summary.dup.groups, p.summary.coverage.images), (0, 0));
    });
  });

  group('relabel', () {
    test('keep と keys を送り、付け直した札と null の札を読む', () async {
      w.replies['POST /v1/lib/similar/relabel'] = (
        200,
        {
          'labels': {
            'a/old.png': {
              'match': 'identical',
              'ph': 0,
              'dh': 0,
              'variant': false,
            },
            'b/re.jpg': {'match': 'same', 'ph': 3, 'dh': 4, 'variant': true},
            'b/far.jpg': {'match': null},
          },
        },
      );
      final l = await api.similarRelabel('lib', 'b/new.png', [
        'a/old.png',
        'b/re.jpg',
        'b/far.jpg',
      ]);
      expect(w.seen.single.body, {
        'keep': 'b/new.png',
        'keys': ['a/old.png', 'b/re.jpg', 'b/far.jpg'],
      });
      expect(l.keys, ['a/old.png', 'b/re.jpg', 'b/far.jpg']);
      expect((l['a/old.png']!.match, l['a/old.png']!.ph), ('identical', 0));
      final re = l['b/re.jpg']!;
      expect((re.match, re.ph, re.dh, re.variant), ('same', 3, 4, true));
      final far = l['b/far.jpg']!;
      expect(
        (far.match, far.ph, far.dh, far.variant),
        (null, null, null, false),
      );
    });
  });

  group('trash', () {
    test('key と keep の組を送り、成功と失敗を項目ごとに読む', () async {
      w.replies['POST /v1/lib/similar/trash'] = (
        200,
        {
          'results': [
            {
              'key': 'b/copy.png',
              'ok': true,
              'trashKey': '.trash/1/b/copy.png',
              'kind': 'identical',
            },
            {
              'key': 'b/re.jpg',
              'ok': true,
              'trashKey': '.trash/1/b/re.jpg',
              'kind': 'same',
            },
            {'key': 'b/x.jpg', 'ok': false, 'error': 'not_similar'},
            {'key': 'b/y.jpg', 'ok': false, 'error': 'keeper_missing'},
          ],
        },
      );
      final r = await api.similarTrash('lib', [
        (key: 'b/copy.png', keep: 'a/keep.png'),
        (key: 'b/re.jpg', keep: 'a/keep.png'),
        (key: 'b/x.jpg', keep: 'a/keep.png'),
        (key: 'b/y.jpg', keep: 'a/gone.png'),
      ]);
      expect(w.seen.single.body, {
        'items': [
          {'key': 'b/copy.png', 'keep': 'a/keep.png'},
          {'key': 'b/re.jpg', 'keep': 'a/keep.png'},
          {'key': 'b/x.jpg', 'keep': 'a/keep.png'},
          {'key': 'b/y.jpg', 'keep': 'a/gone.png'},
        ],
      });
      expect(r.map((x) => (x.key, x.ok, x.trashKey, x.kind, x.error)), [
        ('b/copy.png', true, '.trash/1/b/copy.png', 'identical', null),
        ('b/re.jpg', true, '.trash/1/b/re.jpg', 'same', null),
        ('b/x.jpg', false, null, null, 'not_similar'),
        ('b/y.jpg', false, null, null, 'keeper_missing'),
      ]);
    });

    test('読み取り専用は 403、件数超えは 400 bad_items', () async {
      w.replies['POST /v1/lib/similar/trash'] = (403, {'error': 'read_only'});
      await expectLater(
        api.similarTrash('lib', [(key: 'k', keep: 'j')]),
        apiError(403, 'read_only'),
      );
      w.replies['POST /v1/lib/similar/trash'] = (400, {'error': 'bad_items'});
      await expectLater(
        api.similarTrash('lib', const []),
        apiError(400, 'bad_items'),
      );
      expect(w.seen.last.body, {'items': <Object>[]});
    });
  });

  group('undo', () {
    test('trashKeys を送り、戻せた物と戻せなかった物を status 付きで読む', () async {
      w.replies['POST /v1/lib/similar/undo'] = (
        200,
        {
          'results': [
            {
              'trashKey': '.trash/1/b/copy.png',
              'ok': true,
              'key': 'b/copy.png',
            },
            {
              'trashKey': '.trash/1/b/re.jpg',
              'ok': false,
              'error': 'target_exists',
              'status': 409,
            },
          ],
        },
      );
      final r = await api.similarUndo('lib', [
        '.trash/1/b/copy.png',
        '.trash/1/b/re.jpg',
      ]);
      expect(w.seen.single.body, {
        'trashKeys': ['.trash/1/b/copy.png', '.trash/1/b/re.jpg'],
      });
      expect(r.map((x) => (x.trashKey, x.ok, x.key, x.error, x.status)), [
        ('.trash/1/b/copy.png', true, 'b/copy.png', null, null),
        ('.trash/1/b/re.jpg', false, null, 'target_exists', 409),
      ]);
    });

    test('古い Worker の 404 は status 404 で返る', () async {
      await expectLater(
        api.similarUndo('lib', ['t']),
        apiError(404, 'not_found'),
      );
    });
  });
}
