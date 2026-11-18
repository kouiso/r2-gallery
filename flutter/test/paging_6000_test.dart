import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/state/app_state.dart';

MediaItem _it(String key, {int at = 0}) => MediaItem(
  key: key,
  type: 'image',
  url: 'https://w.example/m/$key',
  createdAt: at,
);

/// 6000件を200件ずつ返す実 Worker のつもり。cursor は数値文字列。
class _BigApi extends ApiClient {
  final List<String?> cursors = [];
  String? nextSort;

  @override
  Future<FolderPage> folder(
    String libId, {
    String prefix = '',
    String? cursor,
    bool recursive = false,
    String? sort,
    String? type,
    bool fresh = false,
  }) async {
    cursors.add(cursor);
    final from = cursor == null ? 0 : int.parse(cursor);
    final items = List.generate(
      200,
      (i) => _it('k${from + i}.jpg', at: 6000 - from - i),
    );
    return FolderPage(
      items: items,
      cursor: from + 200 < 6000 ? '${from + 200}' : null,
      sort: nextSort ?? sort,
      total: 6000,
    );
  }

  @override
  Future<void> putThumb(String libId, String key, Uint8List bytes) async {}
}

void main() {
  test('6000件の一覧で続きが loadMore で足される', () async {
    final api = _BigApi();
    final g = GalleryState(api);
    await g.refresh('a');
    expect(g.ordered().length, 200);
    await g.loadMore('a');
    expect(g.ordered().length, 400);
    await g.loadMore('a');
    expect(g.ordered().length, 600);
    expect(api.cursors, [null, '200', '400']);
  });
}
