import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/state/app_state.dart';
import 'package:r2_gallery/src/ui/gallery_tab.dart';
import 'package:r2_gallery/src/ui/media_tile.dart';
import 'package:r2_gallery/src/webdl/detected.dart';
import 'package:r2_gallery/src/webdl/web_fetcher.dart';
import 'package:r2_gallery/src/webdl/web_history.dart';
import 'package:r2_gallery/src/webdl/web_transfer.dart';

class _GalleryApi extends ApiClient {
  final Map<String, List<MediaItem>> items = {};
  final Map<String, int> galleryCalls = {};
  int puts = 0;

  @override
  Future<FolderPage> folder(String libId,
      {String prefix = '', String? cursor, bool recursive = false}) async {
    if (recursive) galleryCalls.update(libId, (n) => n + 1, ifAbsent: () => 1);
    return FolderPage(items: [
      for (final item in items[libId] ?? <MediaItem>[])
        if (item.key.startsWith(prefix)) item,
    ]);
  }

  @override
  Future<void> putFile(String libId, String key, File file, String mime,
      {CancelToken? cancelToken, void Function(int sent, int total)? onProgress}) async {
    final bytes = await file.readAsBytes();
    expect(bytes, [1, 2, 3, 4]);
    puts++;
    (items[libId] ??= []).add(MediaItem(
      key: key,
      lib: libId,
      type: 'video',
      url: 'https://fixture.invalid/m/$key',
      size: bytes.length,
    ));
    onProgress?.call(bytes.length, bytes.length);
  }
}

class _SyntheticFetcher extends WebFetcher {
  @override
  Future<int> download(String url, Map<String, String> headers,
      {required int resumeAt,
      required FutureOr<void> Function(Uint8List chunk) onChunk,
      required void Function(int written) onProgress,
      void Function(int total)? onTotal,
      String? origin,
      CancelToken? cancelToken}) async {
    final bytes = Uint8List.fromList([1, 2, 3, 4]);
    onTotal?.call(bytes.length);
    await onChunk(bytes);
    onProgress(bytes.length);
    return bytes.length;
  }
}

class _App extends AppState {
  @override
  final WebTransferQueue webQueue;
  _App(_GalleryApi api, this.webQueue)
      : super(api: api, bakedEndpoint: '', bakedToken: '');
}

Finder _tile(String key) =>
    find.byWidgetPredicate((w) => w is MediaTile && w.item.key == key);

void main() {
  late Directory tmp;
  late _GalleryApi api;
  late WebTransferQueue queue;
  late _App app;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('r2g-import-gallery-');
    api = _GalleryApi();
    queue = WebTransferQueue(
      api: api,
      fetcher: _SyntheticFetcher(),
      stageDir: tmp,
      history: WebHistoryStore(read: () async => null, write: (_) async {}),
    );
    app = _App(api, queue);
  });

  tearDown(() async {
    queue.dispose();
    app.transfers.dispose();
    app.dispose();
    await tmp.delete(recursive: true);
  });

  Future<void> showGallery(WidgetTester tester, String lib) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: GalleryTab(app: app, lib: lib)),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> importVideo(WidgetTester tester, String lib, String name) async {
    await tester.runAsync(() async {
      queue.enqueue(lib, [DetectedItem('https://fixture.invalid/$name', DetectedKind.video)]);
      await queue.idle().timeout(const Duration(seconds: 10));
    });
    await tester.pumpAndSettle();
    expect(queue.tasks.last.status, WebTaskStatus.done);
  }

  testWidgets('ネット取り込みが完了すると、開いたままの写真一覧に動画が現れる', (tester) async {
    await showGallery(tester, 'personal');
    expect(find.byType(MediaTile), findsNothing);
    expect(api.galleryCalls['personal'], 1);

    await importVideo(tester, 'personal', 'clip.mp4');

    expect(api.puts, 1);
    expect(_tile('downloads/clip.mp4'), findsOneWidget);
    expect(api.galleryCalls['personal'], 2);

    // 完了行の削除でも通知が来るが、同じ取り込みで一覧を繰り返し取り直さない。
    queue.dismiss(queue.tasks.single.id);
    await tester.pumpAndSettle();
    expect(api.galleryCalls['personal'], 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('別ライブラリを表示中に取り込みが完了しても保存先のキャッシュだけを更新する', (tester) async {
    await showGallery(tester, 'personal');
    await showGallery(tester, 'review');
    expect(api.galleryCalls, {'personal': 1, 'review': 1});

    await importVideo(tester, 'personal', 'background.mp4');

    expect(api.galleryCalls, {'personal': 2, 'review': 1});
    expect(_tile('downloads/background.mp4'), findsNothing);

    await showGallery(tester, 'personal');
    expect(_tile('downloads/background.mp4'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
