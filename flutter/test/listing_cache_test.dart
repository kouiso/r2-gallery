import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/grid/sort_mode.dart';
import 'package:r2_gallery/src/state/app_state.dart';
import 'package:r2_gallery/src/store/listing_cache.dart';

// 2026-01-01 00:00:00 UTC
const _past = 1767225600;
final _future = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 7200;

MediaItem _it(String key, {int e = 0}) => MediaItem(
      key: key,
      type: 'image',
      url: 'https://w.example/m/$key?e=${e == 0 ? _future : e}&s=sig',
      thumbUrl: 'https://w.example/t/$key?e=${e == 0 ? _future : e}&s=sig',
    );

/// 先頭ページの返事を手で返せる Worker。返すまで一覧は控えのまま待つ。
class _GateApi extends ApiClient {
  _GateApi(String endpoint) {
    setConnection(Connection(endpoint, 'tk'));
  }

  final List<Completer<FolderPage>> pending = [];
  final List<({String lib, String? sort, bool fresh})> calls = [];

  @override
  Future<FolderPage> folder(String libId,
      {String prefix = '',
      String? cursor,
      bool recursive = false,
      String? sort,
      String? type,
      bool fresh = false}) {
    calls.add((lib: libId, sort: sort, fresh: fresh));
    final c = Completer<FolderPage>();
    pending.add(c);
    return c.future;
  }

  void answer(List<MediaItem> items, {String? cursor, String sort = 'new'}) =>
      pending.removeAt(0).complete(
          FolderPage(items: items, cursor: cursor, sort: sort, total: 51000));

  void fail() => pending.removeAt(0).completeError(const ApiError(0, 'offline'));

  @override
  Future<String> trash(String libId, String key) async => 'tk-$key';
}

List<String> _keys(GalleryState g) => [for (final i in g.items) i.key];

/// 1回目の起動で一覧を取り、控えを書き終えるまで進める。
Future<void> _seed(ListingCache cache, List<MediaItem> items,
    {String endpoint = 'https://w1', String lib = 'a'}) async {
  final api = _GateApi(endpoint);
  final g = GalleryState(api, cache: cache);
  final f = g.refresh(lib);
  api.answer(items);
  await f;
  await pumpEventQueue();
}

void main() {
  group('signedUrlExpired', () {
    final now = DateTime.fromMillisecondsSinceEpoch(_past * 1000 + 10);
    test('e= が今より前なら切れている', () {
      expect(signedUrlExpired('https://x/t/a.jpg?e=${_past - 1}&s=z', now: now),
          isTrue);
      expect(signedUrlExpired('https://x/t/a.jpg?e=${_past + 60}&s=z', now: now),
          isFalse);
    });
    test('期限が読めない URL は切れていない扱い', () {
      expect(signedUrlExpired('https://x/t/a.jpg', now: now), isFalse);
      expect(signedUrlExpired('https://x/t/a.jpg?e=abc', now: now), isFalse);
    });
  });

  group('控えの置き場', () {
    test('読み戻すと同じ行になり、上限を超えたら古い物から捨てる', () async {
      final cache = MemoryListingCache(maxEntries: 2);
      ListingScope scope(String lib) => ListingScope(
          endpoint: 'e', lib: lib, prefix: '', recursive: true, sort: 'new');
      final item = MediaItem(
          key: 'd/a.mp4',
          type: 'video',
          url: 'u',
          thumbUrl: 't',
          note: 'n',
          createdAt: 5,
          size: 9,
          lib: 'a',
          thumbStored: false);
      await cache.write(scope('a'),
          CachedListing(items: [item], folders: ['d/'], serverSort: 'new', total: 3, savedAt: 1));
      final back = await cache.read(scope('a'));
      expect(back!.items.single.toJson(), item.toJson());
      expect(back.folders, ['d/']);
      expect(back.serverSort, 'new');
      expect(back.total, 3);

      await cache.write(scope('b'), const CachedListing(items: [], savedAt: 2));
      await cache.write(scope('c'), const CachedListing(items: [], savedAt: 3));
      expect(await cache.read(scope('a')), isNull);
      expect(await cache.read(scope('c')), isNotNull);
    });

    test('壊れた中身は読まずに null を返す（一覧の表示は止めない）', () async {
      final cache = MemoryListingCache();
      const scope = ListingScope(
          endpoint: 'e', lib: 'a', prefix: '', recursive: true, sort: 'new');
      cache.entries[scope.id] = '{not json';
      expect(await cache.read(scope), isNull);
    });
  });

  group('起動直後の一覧（控えを先に出して裏で取り直す）', () {
    test('回線の返事より前に控えの先頭ページが出て、返事が来たら置き換わる', () async {
      final cache = MemoryListingCache();
      await _seed(cache, [_it('a.jpg'), _it('b.jpg')]);

      final api = _GateApi('https://w1');
      final g = GalleryState(api, cache: cache);
      final f = g.refresh('a');
      await pumpEventQueue();
      expect(api.pending, hasLength(1), reason: '回線にはまだ答えさせていない');
      expect(_keys(g), ['a.jpg', 'b.jpg']);
      expect(g.showingCached, isTrue);
      expect(g.loading, isTrue);

      api.answer([_it('new.jpg'), _it('a.jpg')], cursor: 'c1');
      await f;
      expect(_keys(g), ['new.jpg', 'a.jpg']);
      expect(g.showingCached, isFalse);
      expect(g.cursor, 'c1');
      expect(g.total, 51000);
    });

    test('取り直しに失敗しても控えの一覧は残し、帯で知らせる', () async {
      final cache = MemoryListingCache();
      await _seed(cache, [_it('a.jpg'), _it('b.jpg')]);

      final api = _GateApi('https://w1');
      final g = GalleryState(api, cache: cache);
      final f = g.refresh('a');
      await pumpEventQueue();
      api.fail();
      await f;
      expect(_keys(g), ['a.jpg', 'b.jpg']);
      expect(g.error, isNotNull);
      expect(g.loading, isFalse);
      // 控えの cursor は使わず、続きは先頭ページを取り直してから
      expect(g.cursor, isNull);
      final more = g.loadMore('a');
      expect(api.calls.last.lib, 'a');
      api.answer([_it('a.jpg')], cursor: 'c1');
      await more;
      expect(g.showingCached, isFalse);
      expect(g.cursor, 'c1');
    });

    test('別の接続先・ライブラリ・並び順の控えは出さない', () async {
      final cache = MemoryListingCache();
      await _seed(cache, [_it('a.jpg')]);

      Future<List<String>> shownBeforeAnswer(String endpoint, String lib,
          {SortMode sort = SortMode.dateNew}) async {
        final api = _GateApi(endpoint);
        final g = GalleryState(api, cache: cache, sort: sort);
        unawaited(g.refresh(lib));
        await pumpEventQueue();
        return _keys(g);
      }

      expect(await shownBeforeAnswer('https://w2', 'a'), isEmpty);
      expect(await shownBeforeAnswer('https://w1', 'b'), isEmpty);
      expect(await shownBeforeAnswer('https://w1', 'a', sort: SortMode.dateOld),
          isEmpty);
      expect(await shownBeforeAnswer('https://w1', 'a'), ['a.jpg']);
    });

    test('ゴミ箱へ送った行は、次の起動で控えから蘇らない', () async {
      final cache = MemoryListingCache();
      final api1 = _GateApi('https://w1');
      final g1 = GalleryState(api1, cache: cache);
      final f = g1.refresh('a');
      api1.answer([_it('a.jpg'), _it('b.jpg'), _it('c.jpg')]);
      await f;
      await g1.trashOptimistic('a', [const SelKey('a', 'b.jpg')]).done;
      await pumpEventQueue();

      final api2 = _GateApi('https://w1');
      final g2 = GalleryState(api2, cache: cache);
      unawaited(g2.refresh('a'));
      await pumpEventQueue();
      expect(_keys(g2), ['a.jpg', 'c.jpg']);
    });

    test('切断すると控えを全部捨てる', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final cache = MemoryListingCache();
      await _seed(cache, [_it('a.jpg')]);
      expect(cache.entries, isNotEmpty);
      final app = AppState(
          api: _GateApi('https://w1'),
          bakedEndpoint: '',
          bakedToken: '',
          listingCache: cache);
      await app.disconnect();
      expect(cache.entries, isEmpty);
    });

    test('控えの行の署名URLが切れていたら、取り直しを待って同じキーの新しい行で開く', () async {
      final cache = MemoryListingCache();
      await _seed(cache, [_it('a.jpg', e: _past), _it('b.jpg', e: _past)]);

      final api = _GateApi('https://w1');
      final g = GalleryState(api, cache: cache);
      unawaited(g.refresh('a'));
      await pumpEventQueue();
      final shown = g.ordered();
      var opened = false;
      final target = g.openTarget(shown, 1).then((t) {
        opened = true;
        return t;
      });
      await pumpEventQueue();
      expect(opened, isFalse, reason: '取り直しが終わるまで開かない');

      api.answer([_it('x.jpg'), _it('b.jpg')]);
      final t = await target;
      expect(t!.index, 1);
      expect(t.items[1].key, 'b.jpg');
      expect(signedUrlExpired(t.items[1].url), isFalse);
    });

    test('取り直したら消えていた行は開かない', () async {
      final cache = MemoryListingCache();
      await _seed(cache, [_it('a.jpg', e: _past)]);
      final api = _GateApi('https://w1');
      final g = GalleryState(api, cache: cache);
      unawaited(g.refresh('a'));
      await pumpEventQueue();
      final target = g.openTarget(g.ordered(), 0);
      api.answer([_it('z.jpg')]);
      expect(await target, isNull);
    });

    test('期限内の行は待たずにそのまま開く', () async {
      final cache = MemoryListingCache();
      await _seed(cache, [_it('a.jpg')]);
      final api = _GateApi('https://w1');
      final g = GalleryState(api, cache: cache);
      unawaited(g.refresh('a'));
      await pumpEventQueue();
      final t = await g.openTarget(g.ordered(), 0);
      expect(t!.items.single.key, 'a.jpg');
      expect(api.pending, hasLength(1));
    });
  });

  group('Worker の fresh と total', () {
    test('fresh=1 は立てた時だけ送り、total を読む', () async {
      final adapter = _Adapter({'items': <Object>[], 'total': 51234});
      final api = ApiClient(dio: Dio()..httpClientAdapter = adapter)
        ..setConnection(const Connection('https://w.example', 'tk'));
      final page = await api.folder('a', fresh: true);
      expect(adapter.queries.single['fresh'], '1');
      expect(page.total, 51234);
      await api.folder('a');
      expect(adapter.queries.last.containsKey('fresh'), isFalse);
    });

    test('引っ張った取り直しだけ fresh を立て、自動の取り直しは立てない', () async {
      final api = _GateApi('https://w1');
      final g = GalleryState(api);
      final f1 = g.refresh('a', fresh: true);
      api.answer([_it('a.jpg')], cursor: 'c1');
      await f1;
      final f2 = g.softRefresh('a');
      api.answer([_it('a.jpg')], cursor: 'c1');
      await f2;
      expect([for (final c in api.calls) c.fresh], [true, false]);
    });

    test('古い Worker は total を返さない', () async {
      final adapter = _Adapter({'items': <Object>[]});
      final api = ApiClient(dio: Dio()..httpClientAdapter = adapter)
        ..setConnection(const Connection('https://w.example', 'tk'));
      expect((await api.folder('a')).total, isNull);
    });
  });
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.body);
  final Map<String, Object?> body;
  final List<Map<String, dynamic>> queries = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    queries.add(Map.of(options.uri.queryParameters));
    return ResponseBody.fromString(jsonEncode(body), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}
