import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/state/app_state.dart';

MediaItem _item(String key, String type, {bool stored = true}) => MediaItem(
      key: key,
      type: type,
      url: 'https://w.example/m/$key',
      thumbStored: stored,
    );

class _PagedApi extends ApiClient {
  int folderCalls = 0;
  bool failFolder = false;
  final List<String> thumbPuts = [];

  @override
  Future<FolderPage> folder(String libId,
      {String prefix = '', String? cursor, bool recursive = false, String? sort, bool fresh = false}) async {
    folderCalls++;
    if (failFolder) throw const ApiError(0, 'offline');
    return FolderPage(items: [_item('a.mp4', 'video')], cursor: 'next');
  }

  @override
  Future<void> putThumb(String libId, String key, Uint8List bytes) async {
    thumbPuts.add(key);
  }
}

/// 1 ページ目に画像、2 ページ目にサムネ未保存の動画がある一覧。
/// 動画のサムネを PUT すると、次に引いた行から thumbUrl が付く。
class _ThreePageApi extends _PagedApi {
  bool videoStored = false;

  @override
  Future<FolderPage> folder(String libId,
      {String prefix = '', String? cursor, bool recursive = false, String? sort, bool fresh = false}) async {
    folderCalls++;
    if (cursor == null) {
      return FolderPage(items: [_item('p1-0.jpg', 'image')], cursor: 'c1');
    }
    return FolderPage(items: [
      videoStored
          ? MediaItem(
              key: 'p2-0.mp4',
              type: 'video',
              url: 'https://w.example/m/p2-0.mp4',
              thumbUrl: 'https://w.example/t/p2-0.mp4')
          : _item('p2-0.mp4', 'video', stored: false),
      _item('p2-1.jpg', 'image'),
    ], cursor: 'c2');
  }

  @override
  Future<void> putThumb(String libId, String key, Uint8List bytes) async {
    await super.putThumb(libId, key, bytes);
    videoStored = true;
  }
}

/// ページ数の決まった一覧。failAt 以降のページ取得は落とす。
class _MultiPageApi extends _PagedApi {
  _MultiPageApi(this.pages, {this.failAt = -1});
  final int pages;
  final int failAt;
  int calls = 0;

  @override
  Future<FolderPage> folder(String libId,
      {String prefix = '', String? cursor, bool recursive = false, String? sort, bool fresh = false}) async {
    folderCalls++;
    final i = calls++;
    if (failAt >= 0 && i >= failAt) throw const ApiError(0, 'offline');
    return FolderPage(
      items: [_item('p$i.jpg', 'image')],
      cursor: i + 1 < pages ? 'c$i' : null,
    );
  }
}

/// 最初の 1 件だけ worker に断られる。
class _FailingThumbApi extends _PagedApi {
  @override
  Future<void> putThumb(String libId, String key, Uint8List bytes) async {
    if (key == '1.jpg') throw const ApiError(415, 'thumb_must_be_webp');
    await super.putThumb(libId, key, bytes);
  }
}

final _thumb = Uint8List.fromList([1, 2, 3]);

void main() {
  group('続きページの取得失敗', () {
    test('失敗した直後はスクロール通知が来ても再試行せず、間を空けたら再試行する', () async {
      final api = _PagedApi();
      final g = GalleryState(api,
          loadMoreBackoff: const Duration(milliseconds: 80));
      await g.refresh('review');
      expect(api.folderCalls, 1);

      api.failFolder = true;
      await g.loadMore('review');
      expect(api.folderCalls, 2);

      // 圏外のあいだ、スクロールのたびに叩かない
      await g.loadMore('review');
      await g.loadMore('review');
      expect(api.folderCalls, 2);

      await Future<void>.delayed(const Duration(milliseconds: 100));
      await g.loadMore('review');
      expect(api.folderCalls, 3);
    });

    test('成功すれば待ち時間は残らず、取り直しでも解ける', () async {
      final api = _PagedApi();
      final g = GalleryState(api,
          loadMoreBackoff: const Duration(seconds: 30));
      await g.refresh('review');
      api.failFolder = true;
      await g.loadMore('review');
      expect(api.folderCalls, 2);

      // 引っ張って取り直せば、待ち時間の途中でも続きを取れる
      api.failFolder = false;
      await g.refresh('review');
      await g.loadMore('review');
      expect(api.folderCalls, 4);
    });
  });

  group('サムネのバックフィル', () {
    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));

    test('動画のサムネを保存できたら、その行だけ差し替えて読み込み済みの続きページは残す', () async {
      final api = _ThreePageApi();
      final g = GalleryState(api);
      await g.refresh('review');
      await g.loadMore('review');
      expect(g.items.map((e) => e.key), ['p1-0.jpg', 'p2-0.mp4', 'p2-1.jpg']);
      expect(g.cursor, 'c2');
      expect(g.items[1].thumbUrl, isNull);

      g.backfillThumbs('review', makeThumb: (_) async => _thumb);
      await settle();

      expect(api.thumbPuts, ['p2-0.mp4']);
      // 先頭 1 ページに巻き戻らず、並びと続きの cursor はそのまま
      expect(g.items.map((e) => e.key), ['p1-0.jpg', 'p2-0.mp4', 'p2-1.jpg']);
      expect(g.cursor, 'c2');
      expect(g.items[1].thumbUrl, 'https://w.example/t/p2-0.mp4');
      expect(g.items[1].thumbStored, isTrue);
    });

    test('画像だけのバックフィルでは一覧を取り直さない（画像は元から thumbUrl を持つ）', () async {
      final api = _PagedApi();
      final g = GalleryState(api);
      g.items = [_item('1.jpg', 'image', stored: false)];
      g.backfillThumbs('review', makeThumb: (_) async => _thumb);
      await settle();

      expect(api.thumbPuts, ['1.jpg']);
      expect(api.folderCalls, 0);
    });

    test('サムネを作れなかった動画だけなら取り直さない', () async {
      final api = _PagedApi();
      final g = GalleryState(api);
      g.items = [_item('1.mp4', 'video', stored: false)];
      g.backfillThumbs('review', makeThumb: (_) async => null);
      await settle();

      expect(api.thumbPuts, isEmpty);
      expect(api.folderCalls, 0);
    });

    test('サムネを保存できた画像ごとに後始末を呼ぶ（保存できなかった分は呼ばない）', () async {
      final api = _PagedApi();
      final g = GalleryState(api);
      g.items = [
        _item('1.jpg', 'image', stored: false),
        _item('2.jpg', 'image', stored: false),
      ];
      final cleaned = <String>[];
      g.backfillThumbs(
        'review',
        makeThumb: (it) async => it.key == '1.jpg' ? _thumb : null,
        onThumbStored: (it) async => cleaned.add(it.key),
      );
      await settle();

      expect(cleaned, ['1.jpg']);
    });

    test('バックフィルの失敗は握りつぶさず数え、残りの行は続ける', () async {
      final api = _FailingThumbApi();
      final g = GalleryState(api);
      g.items = [
        _item('1.jpg', 'image', stored: false),
        _item('2.jpg', 'image', stored: false),
      ];
      g.backfillThumbs('review', makeThumb: (_) async => _thumb);
      await settle();

      expect(g.thumbBackfillFailures, 1);
      expect(api.thumbPuts, ['2.jpg']);
    });

    test('1件ずつ順に流し、途中の失敗で後ろの分を止めない', () async {
      final api = _PagedApi();
      final g = GalleryState(api);
      g.items = [
        _item('1.jpg', 'image', stored: false),
        _item('2.jpg', 'image', stored: false),
        _item('3.mp4', 'video', stored: false),
      ];
      var running = 0;
      var peak = 0;
      g.backfillThumbs('review', makeThumb: (it) async {
        running++;
        peak = running > peak ? running : peak;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        running--;
        if (it.key == '1.jpg') throw StateError('decode failed');
        return _thumb;
      });
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(peak, 1);
      expect(g.thumbBackfillFailures, 1);
      expect(api.thumbPuts, ['2.jpg', '3.mp4']);
    });
  });

  group('すべて選択', () {
    test('続きページが残っていても、全部取り切ってから全件を選ぶ', () async {
      final api = _MultiPageApi(3);
      final g = GalleryState(api);
      await g.refresh('review');
      expect(g.items, hasLength(1));
      expect(g.cursor, isNotNull);

      await g.selectAllFully('review');

      expect(api.folderCalls, 3);
      expect(g.items, hasLength(3));
      expect(g.selection.length, 3);
      expect(g.allSelected('review'), isTrue);
      expect(g.selectAllBusy, isFalse);
    });

    test('続きの取得に失敗したら、取れた分だけ選んで帯で知らせる', () async {
      final api = _MultiPageApi(5, failAt: 2);
      final g = GalleryState(api);
      await g.refresh('review');

      await g.selectAllFully('review');

      // 1,2 ページ目までは取れた分だけ選ぶ。失敗は黙らせず一覧の帯へ
      expect(g.items, hasLength(2));
      expect(g.selection.length, 2);
      expect(g.error, isNotNull);
      expect(g.selectAllBusy, isFalse);
    });

    test('選択の読み込み中にスクロール由来の続き読み込みが割り込まない', () async {
      final api = _MultiPageApi(4);
      final g = GalleryState(api);
      await g.refresh('review');

      final f = g.selectAllFully('review');
      // selectAllBusy は await の前に立つので、ここでの loadMore は二重取得にならない
      await g.loadMore('review');
      await f;

      expect(api.folderCalls, 4);
      expect(g.selection.length, 4);
    });
  });
}
