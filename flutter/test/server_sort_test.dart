import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/grid/media_kind.dart';
import 'package:r2_gallery/src/grid/sort_mode.dart';
import 'package:r2_gallery/src/state/app_state.dart';

MediaItem _it(String key, {int at = 0, int size = 0}) => MediaItem(
      key: key,
      type: 'image',
      url: 'https://w.example/m/$key',
      createdAt: at,
      size: size,
    );

/// リクエストの query を記録し、Worker の応答（sort の返し有無を含む）を差し替える。
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

/// 新しい Worker のつもりで、並び順ごとに2ページへ分けて返す。
class _SortingApi extends ApiClient {
  final List<({String? sort, String? type, String? cursor})> calls = [];
  // 古い Worker は sort を無視して新着順で返し、sort も返さない
  bool oldWorker = false;
  bool failNext = false;
  // 続きのページだけ別の並びで返す(Worker の入れ替わり)
  String? moreSort;
  // 種別絞り込みのテスト用に、画像と動画が混ざった一覧へ切り替える
  bool mixed = false;
  // 先頭ページが全部動画（type を無視する古い Worker で端末側フィルタが空にする場面）
  bool firstPageAllVideo = false;

  static final _newest = [
    _it('m.jpg', at: 5, size: 1),
    _it('B.jpg', at: 4, size: 9),
    _it('a.jpg', at: 3, size: 5),
    _it('z.jpg', at: 2, size: 7),
  ];

  static final _mixed = [
    _it('p1.jpg', at: 5),
    MediaItem(key: 'v1.mp4', type: 'video', url: 'https://w.example/m/v1.mp4', createdAt: 4),
    _it('p2.png', at: 3),
    MediaItem(key: 'v2.mov', type: 'video', url: 'https://w.example/m/v2.mov', createdAt: 2),
  ];

  List<MediaItem> _order(String? sort) {
    if (oldWorker) return _newest;
    final l = [..._newest];
    switch (sort) {
      case 'old':
        l.sort((a, b) => a.createdAt!.compareTo(b.createdAt!));
      case 'name':
        l.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      case 'size':
        l.sort((a, b) => b.size!.compareTo(a.size!));
    }
    return l;
  }

  @override
  Future<FolderPage> folder(String libId,
      {String prefix = '',
      String? cursor,
      bool recursive = false,
      String? sort,
      String? type,
      bool fresh = false}) async {
    calls.add((sort: sort, type: type, cursor: cursor));
    if (failNext) {
      failNext = false;
      throw const ApiError(0, 'offline');
    }
    if (firstPageAllVideo) {
      return cursor == null
          ? FolderPage(items: [_mixed[1], _mixed[3]], cursor: '2')
          : FolderPage(items: [_mixed[0]]);
    }
    var all = mixed ? [..._mixed] : _order(sort);
    // 古い Worker は type も無視する。新しい Worker はここで絞り込む
    if (!oldWorker && type == 'video') {
      all = all.where((i) => i.type == 'video').toList();
    } else if (!oldWorker && type == 'photo') {
      all = all.where((i) => i.type == 'image').toList();
    }
    final from = cursor == null ? 0 : int.parse(cursor);
    final page = all.sublist(from, from + 2);
    return FolderPage(
      items: page,
      cursor: from == 0 ? '2' : null,
      sort: oldWorker ? null : (cursor != null ? (moreSort ?? sort) : sort),
    );
  }

  @override
  Future<void> putThumb(String libId, String key, Uint8List bytes) async {}
}

List<String> _keys(List<MediaItem> l) => [for (final i in l) i.key];

void main() {
  test('ApiClient.folder は sort を query に載せ、応答の sort を読む', () async {
    final adapter = _Adapter({'items': <Object>[], 'sort': 'old'});
    final api = ApiClient(dio: Dio()..httpClientAdapter = adapter)
      ..setConnection(const Connection('https://w.example', 'tk'));
    final page = await api.folder('a', sort: 'old');
    expect(adapter.queries.single['sort'], 'old');
    expect(page.sort, 'old');
    await api.folder('a');
    expect(adapter.queries.last.containsKey('sort'), isFalse);
  });

  test('並び順を Worker に渡し、続きのページも同じ順で取って並べ直さない', () async {
    final api = _SortingApi();
    final g = GalleryState(api, sort: SortMode.dateOld);
    await g.refresh('a');
    await g.loadMore('a');
    expect(api.calls.map((c) => c.sort), ['old', 'old']);
    expect(api.calls.last.cursor, '2');
    // 並べ直さない: 読み込み済みの分は届いた順のまま、続きは後ろに付く
    expect(_keys(g.ordered()), ['z.jpg', 'a.jpg', 'B.jpg', 'm.jpg']);
  });

  test('並び順を変えると先頭から取り直し、続きは新しい順で取る', () async {
    final api = _SortingApi();
    final g = GalleryState(api);
    await g.refresh('a');
    await g.changeSort(SortMode.size, 'a');
    expect(api.calls.last, (sort: 'size', type: null, cursor: null));
    expect(_keys(g.ordered()), ['B.jpg', 'z.jpg']);
    await g.loadMore('a');
    expect(api.calls.last, (sort: 'size', type: null, cursor: '2'));
    expect(_keys(g.ordered()), ['B.jpg', 'z.jpg', 'a.jpg', 'm.jpg']);
    // 同じ順なら取り直さない
    final n = api.calls.length;
    await g.changeSort(SortMode.size, 'a');
    expect(api.calls.length, n);
  });

  test('ApiClient.folder は type を query に載せる', () async {
    final adapter = _Adapter({'items': <Object>[]});
    final api = ApiClient(dio: Dio()..httpClientAdapter = adapter)
      ..setConnection(const Connection('https://w.example', 'tk'));
    await api.folder('a', type: 'photo');
    expect(adapter.queries.single['type'], 'photo');
    await api.folder('a');
    expect(adapter.queries.last.containsKey('type'), isFalse);
  });

  test('種別を変えると Worker に type を渡して先頭から取り直す(#26)', () async {
    final api = _SortingApi()..mixed = true;
    final g = GalleryState(api, kind: MediaKind.video);
    await g.refresh('a');
    expect(api.calls.single.type, 'video');
    expect(_keys(g.items), ['v1.mp4', 'v2.mov']);
    // 「すべて」へ戻すと type を外して全件取り直す（先頭ページは2件）
    await g.changeKind(MediaKind.all, 'a');
    expect(api.calls.last.type, isNull);
    expect(api.calls.last.cursor, isNull);
    expect(g.items, hasLength(2));
    await g.loadMore('a');
    expect(g.items, hasLength(4));
    // 同じ種別なら取り直さない
    final n = api.calls.length;
    await g.changeKind(MediaKind.all, 'a');
    expect(api.calls.length, n);
  });

  test('type を無視する古い Worker では、混ざった行を端末側で除く(#26)', () async {
    final api = _SortingApi()
      ..mixed = true
      ..oldWorker = true;
    final g = GalleryState(api, kind: MediaKind.photo);
    await g.refresh('a');
    // 古い Worker は絞り込まずに返すので、混ざった動画を端末側で除く
    expect(_keys(g.items), ['p1.jpg']);
    await g.loadMore('a');
    expect(_keys(g.items), ['p1.jpg', 'p2.png']);
  });

  test('古い Worker で先頭ページが全部除かれても、続きを読み進めて 0 件にしない(#26)', () async {
    final api = _SortingApi()
      ..mixed = true
      ..oldWorker = true
      ..firstPageAllVideo = true;
    final g = GalleryState(api, kind: MediaKind.photo);
    await g.refresh('a');
    // 1ページ目は全部動画で端末側が空にするが、2ページ目の画像まで読み進める
    expect(api.calls.length, 2);
    expect(_keys(g.items), ['p1.jpg']);
  });

  test('sort を返さない古い Worker では、端末側で並べ直す', () async {
    final api = _SortingApi()..oldWorker = true;
    final g = GalleryState(api, sort: SortMode.name);
    await g.refresh('a');
    expect(_keys(g.ordered()), ['B.jpg', 'm.jpg']);
  });

  test('並び替え直後の取得が失敗しても、古い cursor を新しい並びで送らない', () async {
    final api = _SortingApi();
    final g = GalleryState(api);
    await g.refresh('a');
    expect(g.cursor, '2');
    api.failNext = true;
    await g.changeSort(SortMode.dateOld, 'a');
    expect(g.cursor, isNull);
    await g.loadMore('a');
    // 続きではなく先頭から取り直す
    expect(api.calls.last, (sort: 'old', type: null, cursor: null));
    expect(_keys(g.ordered()), ['z.jpg', 'a.jpg']);
  });

  test('続きのページが別の並びで返ったら、継ぎ足さず先頭から取り直す', () async {
    final api = _SortingApi();
    final g = GalleryState(api, sort: SortMode.dateOld);
    await g.refresh('a');
    api.moreSort = 'new';
    await g.loadMore('a');
    expect(api.calls.map((c) => c.cursor), [null, '2', null]);
    expect(_keys(g.ordered()), ['z.jpg', 'a.jpg']);
  });

  test('古い Worker の続きは、並びが返らなくてもそのまま継ぎ足す', () async {
    final api = _SortingApi()..oldWorker = true;
    final g = GalleryState(api);
    await g.refresh('a');
    await g.loadMore('a');
    expect(api.calls.map((c) => c.cursor), [null, '2']);
    expect(g.items, hasLength(4));
  });

  test('サムネ取り込みは今の並び順で辿る', () async {
    final api = _SortingApi();
    final g = GalleryState(api, sort: SortMode.dateOld);
    g.items = [
      const MediaItem(
        key: 'v.mp4',
        type: 'video',
        url: 'https://w.example/m/v.mp4',
        thumbStored: false,
      ),
    ];
    g.backfillThumbs('a', makeThumb: (_) async => Uint8List.fromList([1]));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(api.calls, isNotEmpty);
    expect(api.calls.every((c) => c.sort == 'old'), isTrue);
  });
}
