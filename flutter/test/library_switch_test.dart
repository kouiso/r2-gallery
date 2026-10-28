import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/state/app_state.dart';
import 'package:r2_gallery/src/ui/gallery_tab.dart';
import 'package:r2_gallery/src/ui/media_tile.dart';

MediaItem _video(String key) =>
    MediaItem(key: key, type: 'video', url: 'https://w.example/m/$key');

class _LibApi extends ApiClient {
  final Map<String, int> folderCalls = {};
  // 2回目以降の取得を止めておき、取り直し中でも手元の一覧が出ているかを見る
  Completer<void>? hold;

  @override
  Future<FolderPage> folder(String libId,
      {String prefix = '', String? cursor, bool recursive = false}) async {
    final n = folderCalls[libId] = (folderCalls[libId] ?? 0) + 1;
    if (n > 1 && hold != null) await hold!.future;
    return FolderPage(items: [_video('$libId-$n.mp4')]);
  }
}

class _Host extends StatefulWidget {
  final AppState app;
  final String lib;
  const _Host({required this.app, required this.lib});
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  @override
  Widget build(BuildContext context) =>
      MaterialApp(home: Scaffold(body: GalleryTab(app: widget.app, lib: widget.lib)));
}

Finder _tileOf(String key) =>
    find.byWidgetPredicate((w) => w is MediaTile && w.item.key == key);

void main() {
  testWidgets('ライブラリを切り替えて戻ると、取り直しを待たずに前の一覧をすぐ出す', (tester) async {
    final api = _LibApi();
    final app = AppState(api: api, bakedEndpoint: '', bakedToken: '');

    await tester.pumpWidget(_Host(app: app, lib: 'review'));
    await tester.pumpAndSettle();
    expect(find.byType(MediaTile), findsOneWidget);

    await tester.pumpWidget(_Host(app: app, lib: 'personal'));
    await tester.pumpAndSettle();
    expect(api.folderCalls['personal'], 1);

    api.hold = Completer<void>();
    await tester.pumpWidget(_Host(app: app, lib: 'review'));
    await tester.pump();

    // 裏で取り直し中（2回目の取得は止まっている）でも、スピナーではなく一覧が出ている
    expect(api.folderCalls['review'], 2);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(_tileOf('review-1.mp4'), findsOneWidget);
    expect(_tileOf('personal-1.mp4'), findsNothing);

    api.hold!.complete();
    await tester.pumpAndSettle();
  });

  test('署名クエリが変わってもサムネのキャッシュキーは同じ', () {
    expect(
      thumbCacheKey('https://w.example/t/review/a.jpg?e=100&s=x'),
      thumbCacheKey('https://w.example/t/review/a.jpg?e=200&s=y'),
    );
  });

  test('サムネのバックフィルは同時に1本しか走らせない', () async {
    final g = GalleryState(ApiClient());
    g.items = [
      for (var i = 0; i < 4; i++)
        MediaItem(
            key: '$i.jpg',
            type: 'image',
            url: 'https://w.example/m/$i.jpg',
            thumbStored: false),
    ];
    var running = 0, peak = 0, done = 0;
    final finished = Completer<void>();
    g.backfillThumbs('review', makeThumb: (_) async {
      running++;
      if (running > peak) peak = running;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      running--;
      if (++done == 4) finished.complete();
      return null;
    });
    await finished.future;
    expect(peak, 1);
  });
}
