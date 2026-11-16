import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/state/app_state.dart';
import 'package:r2_gallery/src/state/pairing.dart';
import 'package:r2_gallery/src/transfer/transfer_queue.dart';
import 'package:r2_gallery/src/ui/gallery_tab.dart';
import 'package:r2_gallery/src/ui/home_shell.dart';
import 'package:r2_gallery/src/ui/media_tile.dart';
import 'package:r2_gallery/src/ui/theme.dart';
import 'package:r2_gallery/src/ui/trash_tab.dart';

// 同じライブラリ id を持つ別の接続先へ切り替えた時の HomeShell の振る舞い
class _Api extends ApiClient {
  final folderCalls = <String>[];
  final trashed = <String>[];
  final albumCalls = <String>[];
  final trashCalls = <String>[];
  final putCalls = <String>[];
  // 一覧取得を失敗させる接続先（ホストの頭1区切りで指定）
  final failLibs = <String>{};
  String get _host => Uri.parse(conn!.endpoint).host.split('.').first;

  @override
  Future<bool> probe(String endpoint, String token) async => true;
  @override
  Future<ProbeOutcome> probeOutcome(String endpoint, String token) async =>
      const ProbeOutcome.ok(libraryCount: 1);
  @override
  Future<List<Library>> libraries() async {
    if (failLibs.contains(_host)) throw const ApiError(0, 'down');
    return const [Library(id: 'photos', title: 'Photos')];
  }

  @override
  Future<void> putObject(
    String libId,
    String key,
    Uint8List bytes,
    String contentType, {
    void Function(int sent, int total)? onProgress,
    CancelToken? cancelToken,
    String? sha256,
    bool verifyStorage = false,
  }) async {
    putCalls.add('$_host/$libId/$key');
  }

  @override
  Future<FolderPage> folder(String libId,
      {String prefix = '',
      String? cursor,
      bool recursive = false,
      bool fresh = false,
      String? sort}) async {
    folderCalls.add('$_host/$libId');
    return FolderPage(items: [
      MediaItem(
          key: '$_host-only.mp4',
          type: 'video',
          url: 'https://$_host.example/m/x.mp4'),
    ]);
  }

  @override
  Future<List<Album>> albums(String libId) async {
    albumCalls.add('$_host/$libId');
    return [Album(id: '$_host-album', title: '$_host のアルバム')];
  }

  @override
  Future<TrashPage> trashList(String libId, {String? cursor}) async {
    trashCalls.add('$_host/$libId');
    return const TrashPage([], null);
  }

  @override
  Future<String> trash(String libId, String key) async {
    trashed.add('$_host/$libId/$key');
    return '.trash/$key';
  }
}

Finder _tile(String key) =>
    find.byWidgetPredicate((w) => w is MediaTile && w.item.key == key);

GalleryState _gallery(WidgetTester t) =>
    (t.state(find.byType(GalleryTab)) as dynamic).g as GalleryState;

void main() {
  for (final viaSave in [false, true]) {
    testWidgets(
        '同じ id のライブラリを持つ別の接続先へ切り替えると、一覧は新しい接続先から取り直し選択は空になる'
        '（${viaSave ? 'saveConnection' : 'connect'}）', (t) async {
      FlutterSecureStorage.setMockInitialValues({});
      t.view.physicalSize = const Size(390, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final api = _Api();
      final app = AppState(api: api, bakedEndpoint: '', bakedToken: '');
      expect(await app.connect('https://a.example', 'ta'), isNull);
      await t.pumpWidget(MaterialApp(
          theme: buildAppTheme(),
          home: HomeShell(app: app, initialTab: HomeShell.photosTab)));
      await t.pumpAndSettle();
      expect(_tile('a-only.mp4'), findsOneWidget);
      final g = _gallery(t);
      g.toggleSelect(g.items.first, 'photos');
      expect(g.selection, isNotEmpty);

      final err = viaSave
          ? await app.saveConnection('https://b.example', 'tb')
          : await app.connect('https://b.example', 'tb');
      expect(err, isNull);
      await t.pumpAndSettle();

      expect(app.activeLib, 'photos');
      expect(api.folderCalls.last, 'b/photos');
      expect(_tile('a-only.mp4'), findsNothing);
      expect(_tile('b-only.mp4'), findsOneWidget);
      expect(_gallery(t).selection, isEmpty);
      expect(api.trashed, isEmpty);
    });
  }

  testWidgets('アルバムタブでゴミ箱を開いたまま別の接続先へ切り替えると、ゴミ箱は閉じアルバムを新しい接続先から取り直す',
      (t) async {
    FlutterSecureStorage.setMockInitialValues({});
    t.view.physicalSize = const Size(390, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final api = _Api();
    final app = AppState(api: api, bakedEndpoint: '', bakedToken: '');
    expect(await app.connect('https://a.example', 'ta'), isNull);
    await t.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: HomeShell(app: app, initialTab: HomeShell.albumsTab)));
    await t.pumpAndSettle();
    expect(find.text('a のアルバム'), findsOneWidget);
    await t.tap(find.text('ゴミ箱'));
    await t.pumpAndSettle();
    expect(find.byType(TrashTab), findsOneWidget);
    expect(api.trashCalls.last, 'a/photos');

    // ゴミ箱は同じライブラリなら残す画面。接続先が替わった時は同じ id でも別物なので捨てる
    expect(await app.saveConnection('https://b.example', 'tb'), isNull);
    await t.pumpAndSettle();

    expect(find.byType(TrashTab), findsNothing);
    expect(api.albumCalls.last, 'b/photos');
    expect(find.text('a のアルバム'), findsNothing);
    expect(find.text('b のアルバム'), findsOneWidget);
    expect(api.trashed, isEmpty);
  });

  test('同じ送り先の判定はパスまで見る', () {
    expect(isSameEndpoint('https://a.example/x', 'https://a.example/x/'), isTrue);
    expect(isSameEndpoint('https://a.example', 'a.example'), isTrue);
    expect(isSameEndpoint('https://a.example/x', 'https://a.example/y'), isFalse);
    expect(isSameEndpoint('https://a.example', 'https://a.example/x'), isFalse);
    expect(isSameEndpoint('https://a.example:8443', 'https://a.example'), isFalse);
  });

  test('別の接続先へ切り替えて一覧の取得に失敗しても、旧接続先の一覧と選択は残らない', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final api = _Api();
    final app = AppState(api: api, bakedEndpoint: '', bakedToken: '');
    expect(await app.connect('https://a.example', 'ta'), isNull);
    expect(app.libraries.map((l) => l.id), ['photos']);
    expect(app.activeLib, 'photos');

    api.failLibs.add('b');
    expect(await app.saveConnection('https://b.example', 'tb'), isNull);
    // 旧接続先の一覧を新しい接続先のものとして残さず、取得失敗の理由も出す
    expect(app.libraries, isEmpty);
    expect(app.activeLib, isNull);
    expect(app.startupError, isNotNull);
  });

  test('切断して別の接続先へ繋ぎ直しても、送り切れていない転送は新しい送り先へ送らない', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final api = _Api();
    final app = AppState(api: api, bakedEndpoint: '', bakedToken: '');
    expect(await app.connect('https://a.example', 'ta'), isNull);
    // 回線を切って行を「待ち」に留める
    app.transfers.setOnline(false);
    final n = await app.upload('photos', [
      UploadSource(
          name: 'x.jpg', size: 3, mime: 'image/jpeg', bytes: Uint8List(3)),
    ]);
    expect(n, 1);
    expect(app.transfers.tasks.single.status, TransferStatus.queued);
    expect(app.hasUnsentTransfers, isTrue);

    await app.disconnect();
    // 接続が null の間にキューは止まるが、行は残る。別の接続先へ繋ぎ直しても送ってはいけない
    expect(await app.connect('https://b.example', 'tb'), isNull);
    expect(app.transfers.tasks.single.status, TransferStatus.paused);

    app.transfers.setOnline(true);
    // 待ちを解いても一時停止のまま新しい送り先へは出ない
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(app.transfers.tasks.single.status, TransferStatus.paused);
    expect(api.putCalls, isEmpty);
  });

  test('同じホストでもパスが違えば別の送り先なので、未送信が残る切り替えは断る', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final api = _Api();
    final app = AppState(api: api, bakedEndpoint: '', bakedToken: '');
    expect(await app.connect('https://a.example/x', 'ta'), isNull);
    app.transfers.setOnline(false);
    await app.upload('photos', [
      UploadSource(
          name: 'x.jpg', size: 3, mime: 'image/jpeg', bytes: Uint8List(3)),
    ]);
    expect(app.hasUnsentTransfers, isTrue);

    expect(await app.saveConnection('https://a.example/y', 'ta'),
        AppState.unsentTransfersMessage);
    // 同じパスへのトークン差し替えは送り先が変わらないので通す。待ちもそのまま残る
    expect(await app.saveConnection('https://a.example/x/', 'tb'), isNull);
    expect(app.transfers.tasks.single.status, TransferStatus.queued);
  });
}
