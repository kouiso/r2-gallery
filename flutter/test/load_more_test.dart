import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/grid/media_grid.dart';
import 'package:r2_gallery/src/state/app_state.dart';
import 'package:r2_gallery/src/state/load_more_backoff.dart';
import 'package:r2_gallery/src/store/listing_cache.dart';

MediaItem _it(String key) => MediaItem(
      key: key,
      type: 'image',
      url: 'https://w.example/m/$key',
      thumbUrl: 'https://w.example/t/$key',
    );

/// 先頭・続きの返事を手で返せる Worker。#181 の続き読み込みの検査用。
class _ScriptApi extends ApiClient {
  _ScriptApi(String endpoint) {
    setConnection(Connection(endpoint, 'tk'));
  }

  final List<Completer<FolderPage>> pending = [];
  final List<({String? cursor, String? sort})> calls = [];
  bool failAll = false;

  @override
  Future<FolderPage> folder(String libId,
      {String prefix = '',
      String? cursor,
      bool recursive = false,
      String? sort,
      String? type,
      bool fresh = false}) {
    calls.add((cursor: cursor, sort: sort));
    if (failAll) return Future.error(const ApiError(0, 'offline'));
    final c = Completer<FolderPage>();
    pending.add(c);
    return c.future;
  }

  void answerAt(int i, List<MediaItem> items,
          {String? cursor, String sort = 'new'}) =>
      pending.removeAt(i).complete(
          FolderPage(items: items, cursor: cursor, sort: sort, total: 51000));

  void answer(List<MediaItem> items, {String? cursor, String sort = 'new'}) =>
      answerAt(0, items, cursor: cursor, sort: sort);

  void failAt(int i) =>
      pending.removeAt(i).completeError(const ApiError(0, 'offline'));

  void fail() => failAt(0);
}

List<String> _keys(GalleryState g) => [for (final i in g.items) i.key];

/// 控えに先頭ページを書き込む（listing_cache_test.dart の _seed と同じ手順）。
/// [settle] で書き込みの終わりを待つ（test では pumpEventQueue、testWidgets では tester.pump）。
Future<void> _seed(ListingCache cache, List<MediaItem> items,
    {String endpoint = 'https://w1', String lib = 'a', Future<void> Function()? settle}) async {
  final api = _ScriptApi(endpoint);
  final g = GalleryState(api, cache: cache);
  final f = g.refresh(lib);
  api.answer(items);
  await f;
  await (settle ?? pumpEventQueue)();
}

void main() {
  group('続きの取得の待ち', () {
    test('待ち時間は失敗のたびに倍になり60秒で止まる', () {
      const base = Duration(seconds: 3);
      final got = [
        for (var n = 0; n <= 7; n++) loadMoreBackoffAfter(base, n),
      ];
      expect(got, [
        Duration.zero,
        const Duration(seconds: 3),
        const Duration(seconds: 6),
        const Duration(seconds: 12),
        const Duration(seconds: 24),
        const Duration(seconds: 48),
        const Duration(seconds: 60),
        const Duration(seconds: 60),
      ]);
    });

    test('続きの失敗が続くと、倍の待ちを空けてから頼み直す', () async {
      final api = _ScriptApi('https://w1');
      final g = GalleryState(api,
          loadMoreBackoff: const Duration(milliseconds: 200));
      final f = g.refresh('a');
      api.answer([_it('a.jpg')], cursor: 'c1');
      await f;
      expect(api.calls, hasLength(1));

      api.failAll = true;
      await g.loadMore('a'); // 1回目の失敗（次は200msの待ち）
      expect(api.calls, hasLength(2));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await g.loadMore('a'); // 2回目の失敗（次は400msの待ち）
      expect(api.calls, hasLength(3));

      await Future<void>.delayed(const Duration(milliseconds: 200));
      await g.loadMore('a'); // 待ちの途中なので取りに行かない
      expect(api.calls, hasLength(3));

      await Future<void>.delayed(const Duration(milliseconds: 300));
      await g.loadMore('a'); // 待ちが明けたので取りに行く
      expect(api.calls, hasLength(4));
    });

    test('控えの後の先頭の失敗にも待ちをかけ、取り直しを回し続けない', () async {
      final cache = MemoryListingCache();
      await _seed(cache, [_it('a.jpg'), _it('b.jpg')]);

      final api = _ScriptApi('https://w1');
      final g = GalleryState(api, cache: cache,
          loadMoreBackoff: const Duration(seconds: 30));
      final f = g.refresh('a');
      await pumpEventQueue();
      expect(g.showingCached, isTrue);
      api.fail();
      await f;
      expect(g.error, isNotNull);

      api.failAll = true;
      await g.loadMore('a'); // 最初の取り直し。これも失敗する
      for (var i = 0; i < 10; i++) {
        await g.loadMore('a'); // 待ちの途中は取り直さない
      }
      // 起動の取り直しと、最初の loadMore の取り直しの2回だけ
      expect(api.calls, hasLength(2));
    });

    test('cursor が進まない応答で続きを終える', () async {
      final api = _ScriptApi('https://w1');
      final g = GalleryState(api);
      final f = g.refresh('a');
      api.answer([_it('a.jpg')], cursor: 'c1');
      await f;

      final m1 = g.loadMore('a');
      api.answer([_it('b.jpg')], cursor: 'c1'); // 送った cursor をそのまま返す
      await m1;
      await g.loadMore('a');

      expect(g.cursor, isNull);
      expect(api.calls.where((c) => c.cursor != null), hasLength(1));
    });

    test('並びの違う続きで取り直した後は、待ちを空けてから続きを頼む', () async {
      final api = _ScriptApi('https://w1');
      final g = GalleryState(api,
          loadMoreBackoff: const Duration(seconds: 30));
      final f = g.refresh('a');
      api.answer([_it('a.jpg')], cursor: 'c1');
      await f;

      final m = g.loadMore('a');
      api.answer([_it('b.jpg')], cursor: 'c2', sort: 'old'); // 並びが違う
      await pumpEventQueue();
      api.answer([_it('a.jpg')], cursor: 'c1'); // 取り直しの先頭ページ
      await m;
      await pumpEventQueue();

      await g.loadMore('a');
      await g.loadMore('a');
      // 取り直しの後は待ちに入るので、cursor 付きの呼び出しは1回のまま
      expect(api.calls.where((c) => c.cursor != null), hasLength(1));
    });
  });

  group('帯の再試行', () {
    test('続きの失敗なら先頭へ戻さず続きを頼み直す', () async {
      final api = _ScriptApi('https://w1');
      final g = GalleryState(api);
      final f = g.refresh('a');
      api.answer([_it('a.jpg')], cursor: 'c1');
      await f;
      final m1 = g.loadMore('a');
      api.answer([_it('b.jpg')], cursor: 'c2');
      await m1;
      expect(g.items, hasLength(2));

      api.failAll = true;
      await g.loadMore('a');
      expect(g.error, isNotNull);
      api.failAll = false;

      final r = g.retry('a');
      api.answer([_it('c.jpg')]);
      await r;
      await pumpEventQueue();

      expect(_keys(g), ['a.jpg', 'b.jpg', 'c.jpg']);
      // 先頭（cursor なし）への取り直しは増えず、続き（cursor c2）だけを頼み直した
      expect(api.calls.where((c) => c.cursor == null), hasLength(1));
      expect(api.calls.where((c) => c.cursor == 'c2'), hasLength(2));
    });

    test('続きが成功したら、続きの失敗の帯を消す', () async {
      final api = _ScriptApi('https://w1');
      final g = GalleryState(api);
      final f = g.refresh('a');
      api.answer([_it('a.jpg')], cursor: 'c1');
      await f;

      api.failAll = true;
      await g.loadMore('a');
      expect(g.error, isNotNull);
      api.failAll = false;

      final r = g.retry('a');
      api.answer([_it('b.jpg')], cursor: 'c2');
      await r;
      expect(g.error, isNull);
    });
  });

  group('一覧の置き換わり', () {
    test('続きを取っている間に重ならない先頭ページへ置き換わったら、古い続きは継ぎ足さない', () async {
      final api = _ScriptApi('https://w1');
      final g = GalleryState(api);
      final f = g.refresh('a');
      api.answer([_it('a.jpg'), _it('b.jpg'), _it('c.jpg'), _it('d.jpg'), _it('e.jpg')],
          cursor: 'c1');
      await f;

      // 続きの取得を答えずに置いたまま、先頭ページの取り直しを始める
      final m = g.loadMore('a');
      final s = g.softRefresh('a');
      // 先頭ページは今の一覧と重ならない（置き換わる）
      api.answerAt(1, [_it('x.jpg'), _it('y.jpg'), _it('z.jpg')], cursor: 'c9');
      await s;
      // 遅れて届いた古い続き（置き換わる前の cursor の分）
      api.answerAt(0, [_it('f.jpg'), _it('g.jpg'), _it('h.jpg'), _it('i.jpg'), _it('j.jpg')],
          cursor: 'c2');
      await m;

      expect(_keys(g), ['x.jpg', 'y.jpg', 'z.jpg']);
      expect(g.cursor, 'c9');
    });

    testWidgets('控えを出している間に末尾近くで頼んでも、先頭ページが届いた後に2ページ目を頼む',
        (tester) async {
      final cache = MemoryListingCache();
      await _seed(cache, [for (var i = 0; i < 200; i++) _it('c$i.jpg')],
          settle: () => tester.pump());

      final api = _ScriptApi('https://w1');
      final g = GalleryState(api, cache: cache);
      unawaited(g.refresh('a'));
      await tester.pump();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: g,
              builder: (_, _) => MediaGrid(
                items: g.ordered(),
                dateHeaders: false,
                selection: const {},
                selectionMode: false,
                selLib: 'a',
                onOpenItem: (_) {},
                onToggleSelect: (_) {},
                onLongPress: (_) {},
                onNearEnd: () => g.loadMore('a'),
                onRefresh: () async {},
                loadingMore: g.loadingMore,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(g.showingCached, isTrue);
      // 控えの200件の末尾へ。読み込み中なのでここでは頼めない
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -3000));
      await tester.pump();

      api.answer([for (var i = 0; i < 200; i++) _it('c$i.jpg')], cursor: 'c1');
      // 続きの読み込み中は読み込み帯が回り続けるので pumpAndSettle ではなく有限の pump で
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }

      expect(api.calls.where((c) => c.cursor == 'c1'), hasLength(1));
    });
  });
}
