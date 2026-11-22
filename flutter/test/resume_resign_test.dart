import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/state/app_state.dart';
import 'package:r2_gallery/src/ui/video_view.dart';
import 'package:r2_gallery/src/viewer/player_system.dart';
import 'package:video_player/video_player.dart';

import 'support/fake_video.dart';

String _url(String tag, {bool expired = false}) =>
    'https://w.example/m/$tag?e=${expired ? 1 : 9999999999}';

/// ページ単位で一覧を返す偽物。各ページのURLは取り直すたび新しい物になる。
class _PageApi extends ApiClient {
  final calls = <String?>[];
  int generation = 0;

  @override
  Future<FolderPage> folder(String libId,
      {String prefix = '',
      String? cursor,
      bool recursive = false,
      String? sort,
      String? type,
      bool fresh = false}) async {
    calls.add(cursor);
    final g = generation;
    if (cursor == null) {
      return FolderPage(
        items: [
          MediaItem(key: 'a.jpg', type: 'image', url: _url('a$g')),
          MediaItem(key: 'b.jpg', type: 'image', url: _url('b$g')),
        ],
        cursor: 'c1',
      );
    }
    return FolderPage(
      items: [
        MediaItem(key: 'c.jpg', type: 'image', url: _url('c$g')),
        MediaItem(key: 'd.jpg', type: 'image', url: _url('d$g')),
      ],
      cursor: null,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('読み込み済みの行が期限切れなら、先頭から取り直してURLだけ差し替える', () async {
    final api = _PageApi();
    final g = GalleryState(api);
    await g.refresh('photos');
    await g.loadMore('photos');
    expect(g.items.length, 4);
    final cursorBefore = g.cursor;

    // 全部期限切れにして、新しい世代のURLで取り直させる
    g.items = [
      for (final it in g.items)
        MediaItem(key: it.key, type: it.type, url: _url('${it.key}-old', expired: true)),
    ];
    api.generation = 1;
    api.calls.clear();
    await g.refreshIfExpired('photos');

    expect(g.items.map((it) => it.key), ['a.jpg', 'b.jpg', 'c.jpg', 'd.jpg']);
    expect(g.items.map((it) => it.url.contains('1')), [true, true, true, true]);
    expect(g.items.every((it) => !it.url.contains('-old')), isTrue);
    // 並び・続きの起点はそのまま
    expect(g.cursor, cursorBefore);
  });

  test('取り直しは載っている行を覆える所までで打ち切る', () async {
    final api = _PageApi();
    final g = GalleryState(api);
    await g.refresh('photos');
    expect(g.items.length, 2);
    g.items = [
      for (final it in g.items)
        MediaItem(key: it.key, type: it.type, url: _url('x', expired: true)),
    ];
    api.calls.clear();
    await g.refreshIfExpired('photos');
    // 2件だけ載っているので2件読んだ所で止まる。全件なめ直しはしない
    expect(api.calls, [null]);
  });

  test('URLが切れていなければ何もしない', () async {
    final api = _PageApi();
    final g = GalleryState(api);
    await g.refresh('photos');
    api.calls.clear();
    await g.refreshIfExpired('photos');
    expect(api.calls, isEmpty);
  });

  test('ロック判定が済んで前面へ戻ると resumed が立つ', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final app = AppState(bakedEndpoint: '', bakedToken: '')..connected = true;
    final seen = Completer<void>();
    final sub = app.resumed.listen((_) {
      if (!seen.isCompleted) seen.complete();
    });
    app.onBackground();
    await app.onForeground();
    await seen.future.timeout(const Duration(seconds: 5));
    await sub.cancel();
    app.dispose();
  });

  test('ロックが掛かったままなら resumed は立たない', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final app = AppState(bakedEndpoint: '', bakedToken: '')
      ..connected = true
      ..locked = true;
    var seen = 0;
    final sub = app.resumed.listen((_) => seen++);
    await app.onForeground();
    await pumpEventQueue();
    expect(seen, 0);
    await sub.cancel();
    app.dispose();
  });

  _videoTests();
}

class _System implements PlayerSystem {
  @override
  Future<double?> volume() async => 1;
  @override
  Future<double?> setVolume(double v) async => v;
  @override
  Future<double?> brightness() async => null;
  @override
  Future<bool> brightnessAuto() async => false;
  @override
  Future<double?> setBrightness(double v) async => v;
  @override
  Future<void> resetBrightness() async {}
}

class _Rig {
  final videos = <FakeVideo>[];
  VideoPlayerController make(String url) {
    final v = FakeVideo();
    videos.add(v);
    return v;
  }
}

void _videoTests() {
  testWidgets('同じ動画のURLが差し替わっても再生位置と停止状態を保つ', (tester) async {
    final rig = _Rig();
    Widget view(String url) => MaterialApp(
          home: Scaffold(
            body: VideoView(url: url, controllerFactory: rig.make, system: _System()),
          ),
        );
    await tester.pumpWidget(view('https://w.example/m/v.mp4?e=1'));
    await tester.pump();
    expect(rig.videos, hasLength(1));
    await rig.videos[0].pause();
    rig.videos[0].value = rig.videos[0].value
        .copyWith(position: const Duration(seconds: 33), isPlaying: false);
    await tester.pump();

    await tester.pumpWidget(view('https://w.example/m/v.mp4?e=2'));
    await tester.pump();
    expect(rig.videos, hasLength(2));
    // 停止していたので動かし直さない。位置は引き継ぐ
    expect(rig.videos[1].plays, 0);
    expect(rig.videos[1].seeks, [const Duration(seconds: 33)]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('同じ動画のURLが差し替わっても再生中なら再生を続ける', (tester) async {
    final rig = _Rig();
    Widget view(String url) => MaterialApp(
          home: Scaffold(
            body: VideoView(url: url, controllerFactory: rig.make, system: _System()),
          ),
        );
    await tester.pumpWidget(view('https://w.example/m/v.mp4?e=1'));
    await tester.pump();
    rig.videos[0].value = rig.videos[0].value
        .copyWith(position: const Duration(seconds: 12), isPlaying: true);

    await tester.pumpWidget(view('https://w.example/m/v.mp4?e=2'));
    await tester.pump();
    expect(rig.videos, hasLength(2));
    expect(rig.videos[1].seeks, [const Duration(seconds: 12)]);
    expect(rig.videos[1].plays, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
