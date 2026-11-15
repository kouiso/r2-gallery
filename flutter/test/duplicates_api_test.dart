import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';

/// 届いた要求を記録し、決めた応答を返すだけの Worker。本物の Dio で往復させる。
class _Recorder {
  late final HttpServer server;
  final List<({String method, String path, Map<String, String> query, Object? body, String? sha})>
      seen = [];
  final Map<String, (int, Object)> replies = {};

  String get base => 'http://127.0.0.1:${server.port}';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async {
      final raw = await utf8.decoder.bind(r).join();
      Object? body;
      if (r.method == 'POST' && raw.isNotEmpty) body = jsonDecode(raw);
      if (r.method == 'PUT') body = raw.length;
      seen.add((
        method: r.method,
        path: r.uri.path,
        query: r.uri.queryParameters,
        body: body,
        sha: r.headers.value('x-content-sha256'),
      ));
      final reply = replies['${r.method} ${r.uri.path}'] ??
          (200, {'key': r.uri.queryParameters['key'], 'size': raw.length});
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

  const item = {
    'key': 'a/x.jpg',
    'lib': 'lib',
    'type': 'image',
    'url': 'https://w.example/m/x',
    'thumbUrl': null,
    'thumbStored': true,
    'createdAt': 1000,
    'size': 3,
  };

  test('scan は空の本文で POST し、pending/hashed/skipped を読む', () async {
    w.replies['POST /v1/lib/duplicates/scan'] =
        (200, {'pending': 4, 'hashed': 10, 'skipped': 1});
    final r = await api.duplicateScan('lib');
    expect((r.pending, r.hashed, r.skipped), (4, 10, 1));
    expect(w.seen.single.body, <String, Object>{});
  });

  test('古い Worker の 404 は status 404 と not_found で返る', () async {
    w.replies['POST /v1/lib/duplicates/scan'] = (404, {'error': 'not_found'});
    await expectLater(
        api.duplicateScan('lib'),
        throwsA(isA<ApiError>()
            .having((e) => e.status, 'status', 404)
            .having((e) => e.code, 'code', 'not_found')));
  });

  test('一覧は cursor と limit を付けて GET し、組と合計を読む', () async {
    w.replies['GET /v1/lib/duplicates'] = (200, {
      'groups': [
        {'sha256': 'ab', 'size': 3, 'items': [item, {...item, 'key': 'b/x.jpg'}]},
      ],
      'cursor': 'n1',
      'total': 7,
      'reclaimable': 21,
      'pending': 2,
      'skipped': 1,
    });
    final p = await api.duplicates('lib', cursor: 'c0', limit: 20);
    expect(w.seen.single.query, {'cursor': 'c0', 'limit': '20'});
    expect(p.groups.single.items.map((i) => i.key), ['a/x.jpg', 'b/x.jpg']);
    expect((p.cursor, p.total, p.reclaimable, p.pending, p.skipped),
        ('n1', 7, 21, 2, 1));
  });

  test('重複の削除は duplicateOf を添え、409 の理由を code で返す', () async {
    w.replies['POST /v1/lib/ops/trash'] = (200, {'ok': true, 'trashKey': 't/1'});
    expect(await api.trashDuplicate('lib', 'b/x.jpg', keep: 'a/x.jpg'), 't/1');
    expect(w.seen.single.body, {'key': 'b/x.jpg', 'duplicateOf': 'a/x.jpg'});
    w.replies['POST /v1/lib/ops/trash'] = (409, {'error': 'keeper_missing'});
    await expectLater(
        api.trashDuplicate('lib', 'b/x.jpg', keep: 'a/x.jpg'),
        throwsA(isA<ApiError>()
            .having((e) => e.status, 'status', 409)
            .having((e) => e.code, 'code', 'keeper_missing')));
  });

  test('照合は sha256 の無い項目からキーを省いて送る', () async {
    w.replies['POST /v1/lib/objects/check'] = (200, {
      'results': [
        {'sizeMatches': 2, 'matches': []},
        {'sizeMatches': 1, 'matches': [item]},
      ],
      'pending': 3,
    });
    final r = await api.checkObjects(
        'lib', [(size: 5, sha256: null), (size: 3, sha256: 'ab')]);
    expect(w.seen.single.body, {
      'items': [
        {'size': 5},
        {'size': 3, 'sha256': 'ab'},
      ],
    });
    expect(r.results.map((x) => x.sizeMatches), [2, 1]);
    expect(r.results[1].matches.single.key, 'a/x.jpg');
    expect(r.pending, 3);
  });

  test('一括PUTは計算済みの時だけ x-content-sha256 を付ける', () async {
    await api.putObject('lib', 'a.jpg', Uint8List.fromList([1, 2, 3]),
        'image/jpeg', verifyStorage: true, sha256: 'ab12');
    await api.putObject(
        'lib', 'b.jpg', Uint8List.fromList([1, 2, 3]), 'image/jpeg');
    expect(w.seen.map((s) => s.sha), ['ab12', null]);
  });
}
