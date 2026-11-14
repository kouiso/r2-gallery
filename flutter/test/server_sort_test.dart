import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
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
  final List<({String? sort, String? cursor})> calls = [];
  // 古い Worker は sort を無視して新着順で返し、sort も返さない
  bool oldWorker = false;

  static final _newest = [
    _it('m.jpg', at: 5, size: 1),
    _it('B.jpg', at: 4, size: 9),
    _it('a.jpg', at: 3, size: 5),
    _it('z.jpg', at: 2, size: 7),
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
      String? sort}) async {
    calls.add((sort: sort, cursor: cursor));
    final all = _order(sort);
    final from = cursor == null ? 0 : int.parse(cursor);
    final page = all.sublist(from, from + 2);
    return FolderPage(
      items: page,
      cursor: from == 0 ? '2' : null,
      sort: oldWorker ? null : sort,
    );
  }
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
    expect(api.calls.last, (sort: 'size', cursor: null));
    expect(_keys(g.ordered()), ['B.jpg', 'z.jpg']);
    await g.loadMore('a');
    expect(api.calls.last, (sort: 'size', cursor: '2'));
    expect(_keys(g.ordered()), ['B.jpg', 'z.jpg', 'a.jpg', 'm.jpg']);
    // 同じ順なら取り直さない
    final n = api.calls.length;
    await g.changeSort(SortMode.size, 'a');
    expect(api.calls.length, n);
  });

  test('sort を返さない古い Worker では、端末側で並べ直す', () async {
    final api = _SortingApi()..oldWorker = true;
    final g = GalleryState(api, sort: SortMode.name);
    await g.refresh('a');
    expect(_keys(g.ordered()), ['B.jpg', 'm.jpg']);
  });
}
