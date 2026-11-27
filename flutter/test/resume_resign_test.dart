import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/albums/album_states.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/state/app_state.dart';
import 'package:r2_gallery/src/store/kv.dart';
import 'package:r2_gallery/src/store/listing_cache.dart' show signedUrlExpired;
import 'package:r2_gallery/src/ui/video_view.dart';
import 'package:r2_gallery/src/viewer/player_system.dart';
import 'package:video_player/video_player.dart';

import 'support/fake_video.dart';

String _url(String tag, {bool expired = false}) =>
    'https://w.example/m/$tag?e=${expired ? 1 : 9999999999}';

/// ページ単位で一覧を返す偽物。各ページのURLは取り直すたび新しい物になる。
class _PageApi extends ApiClient {
  final calls = <String?>[];
  final objectAtCalls = <String>[];
  int generation = 0;

  @override
  Future<MediaItem?> objectAt(String libId, String key) async {
    objectAtCalls.add(key);
    return MediaItem(key: key, type: 'image', url: _url('$key-one'));
  }

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

/// 2ページ目で回線が切れる一覧。差し替えの途中で失敗した時の扱いを見る。
class _CutApi extends _PageApi {
  Object rejectWith = const ApiError(503, 'offline');
  @override
  Future<FolderPage> folder(String libId,
      {String prefix = '',
      String? cursor,
      bool recursive = false,
      String? sort,
      String? type,
      bool fresh = false}) {
    if (generation > 0 && cursor != null) {
      calls.add(cursor);
      return Future.error(rejectWith);
    }
    return super.folder(libId,
        prefix: prefix,
        cursor: cursor,
        recursive: recursive,
        sort: sort,
        type: type,
        fresh: fresh);
  }
}

/// 初めの [failures] 回は落ち、その後は返すライブラリ一覧。圏外で控えから起動した後の取り直しを見る。
class _FlakyLibApi extends ApiClient {
  var calls = 0;
  var failures = 2;
  Completer<void>? gate;
  @override
  Future<List<Library>> libraries() async {
    calls++;
    await gate?.future;
    if (calls <= failures) throw const ApiError(503, 'offline');
    return const [Library(id: 'photos', title: '写真')];
  }
}

/// 差し替えの1ページ目の返事を外から止めておける一覧。復帰の差し替えの最中に開く場面を作る。
class _GatedApi extends _PageApi {
  Completer<void>? gate;
  @override
  Future<FolderPage> folder(String libId,
      {String prefix = '',
      String? cursor,
      bool recursive = false,
      String? sort,
      String? type,
      bool fresh = false}) async {
    if (generation > 0) await gate?.future;
    return super.folder(libId,
        prefix: prefix,
        cursor: cursor,
        recursive: recursive,
        sort: sort,
        type: type,
        fresh: fresh);
  }
}

/// アルバム一覧（表紙つき）。取り直しの返事を差し替えられる。
class _CoverApi extends ApiClient {
  Object? failWith;
  int albumCalls = 0;
  @override
  Future<List<Album>> albums(String libId) async {
    albumCalls++;
    final f = failWith;
    if (f != null) throw f;
    return [Album(id: 'x', title: '旅', coverUrl: _url('cover-new'))];
  }

  @override
  Future<FolderPage> folder(String libId,
      {String prefix = '',
      String? cursor,
      bool recursive = false,
      String? sort,
      String? type,
      bool fresh = false}) async =>
      const FolderPage(items: [], folders: ['f/']);
}

/// 表紙の取り直しの返事を外から止めておけるアルバム一覧。取り直しの最中に手元で作成・削除する場面を作る。
class _GatedCoverApi extends _CoverApi {
  final gate = Completer<void>();
  bool armed = false;
  @override
  Future<List<Album>> albums(String libId) async {
    final stale = await super.albums(libId);
    if (armed) await gate.future;
    return stale;
  }

  @override
  Future<void> albumDelete(String lib, String albumId) async {}

  @override
  Future<String> albumCreate(String lib, String title) async => 'new-id';
}

/// アルバムの中身を1件ずつ返し、取り直しの2ページ目で回線が切れる偽物。
class _AlbumApi extends ApiClient {
  int generation = 0;
  Completer<void>? gate;
  Object rejectWith = const ApiError(503, 'offline');
  final objectAtCalls = <String>[];
  @override
  Future<MediaItem?> objectAt(String libId, String key) async {
    objectAtCalls.add(key);
    return MediaItem(key: key, type: 'image', url: _url('$key-fresh'));
  }

  @override
  Future<AlbumPage> album(String libId, String albumId,
      {String? cursor, int limit = 60}) async {
    if (generation > 0) await gate?.future;
    if (generation > 0 && cursor != null) throw rejectWith;
    final key = cursor == null ? 'a.jpg' : 'b.jpg';
    return AlbumPage(
        items: [MediaItem(key: key, type: 'image', url: _url('$key$generation'))],
        cursor: cursor == null ? '1' : null,
        title: 't',
        count: 2,
        readOnly: false);
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

  test('ロック中に戻っても resumed は立つ（差し替えはロックの裏で進める）', () async {
    // 長く裏にいた後はふつうロックが掛かる。そこで止めると一番要る場面で差し替えが走らない。
    // 一覧は Offstage で残り画面はロックが覆うので、#24 の設計どおり裏で進める
    FlutterSecureStorage.setMockInitialValues({});
    final app = AppState(bakedEndpoint: '', bakedToken: '')
      ..connected = true
      ..locked = true;
    var seen = 0;
    final sub = app.resumed.listen((_) => seen++);
    await app.onForeground();
    await pumpEventQueue();
    expect(seen, 1);
    expect(app.locked, isTrue);
    await sub.cancel();
    app.dispose();
  });

  test('差し替えの途中で回線が切れても帯を出さず、取れた分だけ替える', () async {
    final api = _CutApi();
    final g = GalleryState(api);
    await g.refresh('photos');
    await g.loadMore('photos');
    expect(g.items.length, 4);
    g.items = [
      for (final it in g.items)
        MediaItem(key: it.key, type: it.type, url: _url('${it.key}-old', expired: true)),
    ];
    api.generation = 1;
    await g.refreshIfExpired('photos');
    expect(g.error, isNull);
    // 1ページ目の2件は新しいURL、取れなかった2件は元のまま（開く時に1件ずつ引き直す）
    expect(g.items.map((it) => it.url.contains('-old')), [false, false, true, true]);
  });

  test('差し替えが断られた（401）時は今まで通り帯で見せる', () async {
    final api = _CutApi()..rejectWith = const ApiError(401, 'unauthorized');
    final g = GalleryState(api);
    await g.refresh('photos');
    await g.loadMore('photos');
    g.items = [
      for (final it in g.items)
        MediaItem(key: it.key, type: it.type, url: _url('${it.key}-old', expired: true)),
    ];
    api.generation = 1;
    await g.refreshIfExpired('photos');
    expect(g.error, contains('401'));
  });

  test('アルバムの差し替えも途中で回線が切れたら帯を出さず取れた分だけ替える', () async {
    final api = _AlbumApi();
    final s = AlbumDetailState(api, 'photos', 'al');
    await s.refresh();
    await s.loadMore();
    expect(s.items.length, 2);
    s.items = [
      for (final it in s.items)
        MediaItem(key: it.key, type: it.type, url: _url('${it.key}-old', expired: true)),
    ];
    api.generation = 1;
    await s.refreshIfExpired();
    expect(s.error, isNull);
    expect(s.items.map((it) => it.url.contains('-old')), [false, true]);

    // 替わらずに残った行は、開く時にその1件だけ引き直す
    final t = await s.openTarget(s.items[1]);
    expect(api.objectAtCalls, ['b.jpg']);
    expect(t!.index, 1);
    expect(signedUrlExpired(t.items[1].url), isFalse);
    // 期限内の行は引き直さない
    await s.openTarget(s.items[0]);
    expect(api.objectAtCalls, ['b.jpg']);
    s.dispose();
  });

  test('ライブラリの控えの形が違えば（v が 1 でない）使わない', () async {
    FlutterSecureStorage.setMockInitialValues({
      Keys.endpoint: 'https://w.example',
      Keys.token: 'tk',
      Keys.libraries:
          '{"v":2,"endpoint":"https://w.example","activeLib":"photos","libraries":[{"id":"photos","title":"写真","readOnly":false}]}',
    });
    final api = _FlakyLibApi()..failures = 1 << 30;
    final app = AppState(api: api, bakedEndpoint: '', bakedToken: '');
    await app.init();
    expect(app.libraries, isEmpty);
    await pumpEventQueue();
    app.dispose();
  });

  test('控えだけで起動して一覧を取れていなければ、前面へ戻った時に取り直す', () async {
    FlutterSecureStorage.setMockInitialValues({
      Keys.endpoint: 'https://w.example',
      Keys.token: 'tk',
      Keys.libraries:
          '{"v":1,"endpoint":"https://w.example","activeLib":"photos","libraries":[{"id":"photos","title":"写真","readOnly":false}]}',
    });
    // 起動・解除・間の無い解除の 3 回は圏外で落ちる
    final api = _FlakyLibApi()..failures = 3;
    final app = AppState(api: api, bakedEndpoint: '', bakedToken: '');
    var now = DateTime(2026, 1, 1);
    app.nowForRetry = () => now;
    await app.init();
    await pumpEventQueue();
    // 起動の先読みと解除の取り直しが2回とも圏外で落ちる
    expect(app.locked, isTrue);
    app.unlock();
    await pumpEventQueue();
    final before = api.calls;
    expect(before, 2);
    expect(app.librariesFromNet, isFalse);

    // 失敗の直後（30 秒以内）の復帰では、圏外のまま取りに行かない
    now = now.add(const Duration(seconds: 10));
    app.onBackground();
    await app.onForeground();
    await pumpEventQueue();
    expect(api.calls, before);
    // 解除は間を空けず取り直す
    app.lockNow();
    app.unlock();
    await pumpEventQueue();
    expect(api.calls, before + 1);
    expect(app.librariesFromNet, isFalse);

    now = now.add(const Duration(seconds: 31));
    app.onBackground();
    await app.onForeground();
    await pumpEventQueue();
    expect(api.calls, before + 2);
    expect(app.librariesFromNet, isTrue);

    // 取れた後の復帰では頼まない
    app.onBackground();
    await app.onForeground();
    await pumpEventQueue();
    expect(api.calls, before + 2);
    app.dispose();
  });

  test('一覧の取得中に解除・復帰しても、同じ要求を重ねない', () async {
    FlutterSecureStorage.setMockInitialValues({
      Keys.endpoint: 'https://w.example',
      Keys.token: 'tk',
      Keys.libraries:
          '{"v":1,"endpoint":"https://w.example","activeLib":"photos","libraries":[{"id":"photos","title":"写真","readOnly":false}]}',
    });
    final api = _FlakyLibApi()
      ..failures = 0
      ..gate = Completer<void>();
    final app = AppState(api: api, bakedEndpoint: '', bakedToken: '');
    await app.init();
    expect(api.calls, 1);
    expect(app.librariesLoading, isTrue);
    app.unlock();
    app.onBackground();
    await app.onForeground();
    await pumpEventQueue();
    expect(api.calls, 1);
    api.gate!.complete();
    await pumpEventQueue();
    // 先の答えが捨てられずに使われる
    expect(app.librariesFromNet, isTrue);
    expect(api.calls, 1);
    app.dispose();
  });

  test('429（待てば通る）で差し替えが止まっても帯を出さず、取れた分だけ替える', () async {
    final api = _CutApi()..rejectWith = const ApiError(429, 'too many');
    final g = GalleryState(api);
    await g.refresh('photos');
    await g.loadMore('photos');
    g.items = [
      for (final it in g.items)
        MediaItem(key: it.key, type: it.type, url: _url('${it.key}-old', expired: true)),
    ];
    api.generation = 1;
    await g.refreshIfExpired('photos');
    expect(g.error, isNull);
    expect(g.items.map((it) => it.url.contains('-old')), [false, false, true, true]);
  });

  test('断られ方の分け方: 利用者の手が要る 401/403/404/410 だけ帯の対象', () {
    for (final s in [401, 403, 404, 410]) {
      expect(isClientRejection(ApiError(s, 'x')), isTrue, reason: '$s');
    }
    for (final s in [0, 408, 429, 500, 503]) {
      expect(isClientRejection(ApiError(s, 'x')), isFalse, reason: '$s');
    }
    expect(isClientRejection(StateError('x')), isFalse);
  });

  test('アルバムの差し替えも 429 なら帯を出さない', () async {
    final api = _AlbumApi()..rejectWith = const ApiError(429, 'too many');
    final s = AlbumDetailState(api, 'photos', 'al');
    await s.refresh();
    await s.loadMore();
    s.items = [
      for (final it in s.items)
        MediaItem(key: it.key, type: it.type, url: _url('${it.key}-old', expired: true)),
    ];
    api.generation = 1;
    await s.refreshIfExpired();
    expect(s.error, isNull);
    expect(s.items.map((it) => it.url.contains('-old')), [false, true]);
    s.dispose();
  });

  test('アルバム一覧の復帰は、回線の不調なら帯を出さず今のアルバムを残す', () async {
    final api = _CoverApi();
    final h = AlbumsHomeState(api);
    await h.load('photos');
    h.albums = [
      Album(id: 'x', title: '旅', coverUrl: _url('cover-old', expired: true)),
    ];
    api.failWith = const ApiError(503, 'offline');
    await h.refreshIfExpired('photos');
    expect(h.error, isNull);
    expect(h.loading, isFalse);
    expect(h.albums.single.coverUrl, contains('cover-old'));

    api.failWith = const ApiError(429, 'too many');
    await h.refreshIfExpired('photos');
    expect(h.error, isNull);

    // 通れば表紙のURLだけ新しくなる
    api.failWith = null;
    await h.refreshIfExpired('photos');
    expect(h.albums.single.coverUrl, contains('cover-new'));
    expect(h.error, isNull);
    h.dispose();
  });

  for (final op in ['delete', 'create']) {
    test('表紙の取り直しの最中に手元で$opしたら、古い答えで一覧を戻さない', () async {
      final api = _GatedCoverApi();
      final h = AlbumsHomeState(api);
      await h.load('photos');
      h.albums = [
        Album(id: 'x', title: '旅', coverUrl: _url('cover-old', expired: true)),
      ];
      api.armed = true;
      final refresh = h.refreshIfExpired('photos');
      if (op == 'delete') {
        await h.delete('photos', 'x');
      } else {
        await h.create('photos', '新しい');
      }
      final expected = h.albums.map((a) => a.id).toList();
      api.gate.complete();
      await refresh;
      expect(h.albums.map((a) => a.id), expected);
      expect(h.albums.any((a) => a.coverUrl?.contains('cover-new') ?? false),
          isFalse);
      h.dispose();
    });
  }

  test('アルバム一覧の復帰が断られた（401）時は帯で見せる', () async {
    final api = _CoverApi();
    final h = AlbumsHomeState(api);
    await h.load('photos');
    h.albums = [
      Album(id: 'x', title: '旅', coverUrl: _url('cover-old', expired: true)),
    ];
    api.failWith = const ApiError(401, 'unauthorized');
    await h.refreshIfExpired('photos');
    expect(h.error, contains('401'));
    expect(h.albums, isNotEmpty);
    h.dispose();
  });

  test('開く時に復帰の差し替えが走っていれば終わりを待ち、直っていれば引き直さない', () async {
    final api = _GatedApi();
    final g = GalleryState(api);
    await g.refresh('photos');
    g.items = [
      for (final it in g.items)
        MediaItem(key: it.key, type: it.type, url: _url('${it.key}-old', expired: true)),
    ];
    api.generation = 1;
    api.gate = Completer<void>();
    final resign = g.refreshIfExpired('photos');
    await pumpEventQueue();

    var opened = false;
    final open = g.openTarget(g.ordered(), 0, lib: 'photos').then((t) {
      opened = true;
      return t;
    });
    await pumpEventQueue();
    // 差し替えが終わるまで待つ。その間に1件だけ引き直したりしない
    expect(opened, isFalse);
    expect(api.objectAtCalls, isEmpty);

    api.gate!.complete();
    await resign;
    final t = await open;
    expect(t, isNotNull);
    expect(signedUrlExpired(t!.items[t.index].url), isFalse);
    expect(api.objectAtCalls, isEmpty);
    g.dispose();
  });

  test('差し替えを待っても直らなかった行は、その1件だけ引き直して開く', () async {
    final api = _CutApi();
    final g = GalleryState(api);
    await g.refresh('photos');
    await g.loadMore('photos');
    g.items = [
      for (final it in g.items)
        MediaItem(key: it.key, type: it.type, url: _url('${it.key}-old', expired: true)),
    ];
    api.generation = 1;
    final resign = g.refreshIfExpired('photos');
    // 3件目（c.jpg）は2ページ目で回線が切れて差し替えでは直らない
    final t = await g.openTarget(g.ordered(), 2, lib: 'photos');
    await resign;
    expect(api.objectAtCalls, ['c.jpg']);
    expect(t!.items[t.index].key, 'c.jpg');
    expect(signedUrlExpired(t.items[t.index].url), isFalse);
    g.dispose();
  });

  test('アルバムの中でも、開く時に差し替えの終わりを待つ', () async {
    final api = _AlbumApi();
    final s = AlbumDetailState(api, 'photos', 'al');
    await s.refresh();
    s.items = [
      for (final it in s.items)
        MediaItem(key: it.key, type: it.type, url: _url('${it.key}-old', expired: true)),
    ];
    api.generation = 1;
    api.gate = Completer<void>();
    final resign = s.refreshIfExpired();
    await pumpEventQueue();

    var opened = false;
    final open = s.openTarget(s.items[0]).then((t) {
      opened = true;
      return t;
    });
    await pumpEventQueue();
    expect(opened, isFalse);
    expect(api.objectAtCalls, isEmpty);

    api.gate!.complete();
    await resign;
    final t = await open;
    expect(signedUrlExpired(t!.items[t.index].url), isFalse);
    // 差し替えで直ったので、その1件だけの引き直しは要らない
    expect(api.objectAtCalls, isEmpty);
    s.dispose();
  });

  test('一覧が全く無い時は、取得中でも解除で頼み直す（固まった要求を待たない）', () async {
    FlutterSecureStorage.setMockInitialValues({
      Keys.endpoint: 'https://w.example',
      Keys.token: 'tk',
    });
    final api = _FlakyLibApi()
      ..failures = 0
      ..gate = Completer<void>();
    final app = AppState(api: api, bakedEndpoint: '', bakedToken: '');
    await app.init();
    expect(app.libraries, isEmpty);
    expect(api.calls, 1);
    expect(app.librariesLoading, isTrue);
    app.unlock();
    expect(api.calls, 2);
    api.gate!.complete();
    await pumpEventQueue();
    expect(app.librariesFromNet, isTrue);
    app.dispose();
  });

  test('一覧が全く無い時は、取得中でも前面への復帰で頼み直す', () async {
    FlutterSecureStorage.setMockInitialValues({
      Keys.endpoint: 'https://w.example',
      Keys.token: 'tk',
    });
    final api = _FlakyLibApi()
      ..failures = 0
      ..gate = Completer<void>();
    final app = AppState(api: api, bakedEndpoint: '', bakedToken: '');
    await app.init();
    expect(api.calls, 1);
    app.onBackground();
    await app.onForeground();
    await pumpEventQueue();
    expect(api.calls, 2);
    api.gate!.complete();
    await pumpEventQueue();
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
