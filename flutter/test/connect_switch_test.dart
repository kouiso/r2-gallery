import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/state/app_state.dart';
import 'package:r2_gallery/src/ui/gallery_tab.dart';
import 'package:r2_gallery/src/ui/home_shell.dart';
import 'package:r2_gallery/src/ui/media_tile.dart';
import 'package:r2_gallery/src/ui/theme.dart';

// 同じライブラリ id を持つ別の接続先へ切り替えた時の HomeShell の振る舞い
class _Api extends ApiClient {
  final folderCalls = <String>[];
  final trashed = <String>[];
  String get _host => Uri.parse(conn!.endpoint).host.split('.').first;

  @override
  Future<bool> probe(String endpoint, String token) async => true;
  @override
  Future<ProbeOutcome> probeOutcome(String endpoint, String token) async =>
      const ProbeOutcome.ok(libraryCount: 1);
  @override
  Future<List<Library>> libraries() async =>
      const [Library(id: 'photos', title: 'Photos')];
  @override
  Future<FolderPage> folder(String libId,
      {String prefix = '', String? cursor, bool recursive = false}) async {
    folderCalls.add('$_host/$libId');
    return FolderPage(items: [
      MediaItem(
          key: '$_host-only.mp4',
          type: 'video',
          url: 'https://$_host.example/m/x.mp4'),
    ]);
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
}
