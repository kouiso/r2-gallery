import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/albums/album_detail_screen.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/state/app_state.dart';
import 'package:r2_gallery/src/ui/browser_surface.dart';
import 'package:r2_gallery/src/ui/folder_browse_screen.dart';
import 'package:r2_gallery/src/ui/home_shell.dart';
import 'package:r2_gallery/src/ui/import_browser_tab.dart';
import 'package:r2_gallery/src/ui/media_tile.dart';

class _Api extends ApiClient {
  @override
  Future<FolderPage> folder(String libId,
          {String prefix = '', String? cursor, bool recursive = false}) async =>
      const FolderPage(items: []);
  @override
  Future<List<Album>> albums(String libId) async => const [];
}

/// WebView の履歴を決めて答える代役。押された回数を数える
class _FakeBack extends BrowserBack {
  bool history;
  int goBacks = 0;
  _FakeBack({required this.history});
  @override
  Future<bool> canGoBack() async => history;
  @override
  void goBack() => goBacks++;
}

MediaItem _img(String key) =>
    MediaItem(key: key, type: 'image', url: 'https://w.example/m/$key');

/// アルバム 1 つと、フォルダ seed/ → seed/sub/ を返す代役。アルバム一覧を取った回数を数える
class _ChildApi extends ApiClient {
  int albumLoads = 0;
  // 開いた中身（アルバム詳細・フォルダ）を取りに行った回数
  int albumPageLoads = 0;
  int folderPageLoads = 0;
  @override
  Future<List<Album>> albums(String libId) async {
    albumLoads++;
    return const [Album(id: 'trip', title: '旅行', count: 1, readOnly: false)];
  }

  @override
  Future<AlbumPage> album(String libId, String albumId,
          {String? cursor, int limit = 60}) async {
    albumPageLoads++;
    return AlbumPage(
        items: [_img('a.jpg')], title: '旅行', count: 1, readOnly: false);
  }

  @override
  Future<FolderPage> folder(String libId,
          {String prefix = '', String? cursor, bool recursive = false}) async {
    if (prefix == 'seed/') folderPageLoads++;
    return switch (prefix) {
        '' => const FolderPage(items: [], folders: ['seed/']),
        'seed/' => FolderPage(items: [_img('seed/a.jpg')], folders: const ['seed/sub/']),
        _ => const FolderPage(items: []),
      };
  }
}

AppState _app([ApiClient? api]) =>
    AppState(api: api ?? _Api(), bakedEndpoint: '', bakedToken: '')
  ..connected = true
  ..libraries = const [Library(id: 'lib', title: 'L')]
  ..activeLib = 'lib';

Finder _tab(String label) =>
    find.descendant(of: find.byType(NavigationBar), matching: find.text(label));

List<String> _tabLabels(WidgetTester tester) => [
      for (final d in tester
          .widget<NavigationBar>(find.byType(NavigationBar))
          .destinations)
        (d as NavigationDestination).label,
    ];

/// アプリを閉じる要求（SystemNavigator.pop）の回数を数える
List<MethodCall> _recordExit(WidgetTester tester) {
  final calls = <MethodCall>[];
  tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'SystemNavigator.pop') calls.add(call);
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null));
  return calls;
}

int _selected(WidgetTester tester) =>
    tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex;

Future<void> _openBrowser(WidgetTester tester) async {
  await tester.tap(_tab('取り込み'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), 'example.com/video');
  await tester.tap(find.widgetWithIcon(FilledButton, Icons.public));
  await tester.pump();
  // テストにはネイティブの WebView が無いので、開いたページの代わりにこの表示が出る
  expect(find.textContaining('内蔵ブラウザを開けませんでした'), findsOneWidget);
}

void main() {
  group('下のタブは Kotlin 版と同じ（#167）', () {
    testWidgets('数と順番は 写真 / アルバム / 取り込み / 設定', (tester) async {
      await tester.pumpWidget(MaterialApp(home: HomeShell(app: _app())));
      await tester.pumpAndSettle();
      expect(_tabLabels(tester), ['写真', 'アルバム', '取り込み', '設定']);
    });

    testWidgets('起動は Kotlin 版と同じく取り込みから始まる', (tester) async {
      await tester.pumpWidget(MaterialApp(home: HomeShell(app: _app())));
      await tester.pumpAndSettle();
      expect(
          tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
          2);
      expect(find.text('ネットから取り込む'), findsOneWidget);
    });

    testWidgets('押した時の行き先がそれぞれの画面になる', (tester) async {
      await tester.pumpWidget(MaterialApp(home: HomeShell(app: _app())));
      await tester.pumpAndSettle();

      await tester.tap(_tab('アルバム'));
      await tester.pumpAndSettle();
      expect(find.text('その他'), findsOneWidget);

      await tester.tap(_tab('写真'));
      await tester.pumpAndSettle();
      expect(
          tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
          0);

      await tester.tap(_tab('取り込み'));
      await tester.pumpAndSettle();
      expect(find.text('ネットから取り込む'), findsOneWidget);

      await tester.tap(_tab('設定'));
      await tester.pumpAndSettle();
      expect(
          tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
          3);
    });
  });

  group('端末の戻るの行き先は Kotlin 版と同じ（#167）', () {
    // Kotlin 版はタブ移動のたびに起動画面（取り込み）まで積み直すので、戻ると取り込みに着く
    for (final (label, index) in const [('写真', 0), ('アルバム', 1), ('設定', 3)]) {
      testWidgets('$labelタブで戻ると取り込みに着き、アプリは閉じない', (tester) async {
        final exits = _recordExit(tester);
        await tester.pumpWidget(MaterialApp(home: HomeShell(app: _app())));
        await tester.pumpAndSettle();
        await tester.tap(_tab(label));
        await tester.pumpAndSettle();
        expect(_selected(tester), index);

        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(exits, isEmpty);
        expect(_selected(tester), HomeShell.importTab);
        expect(find.text('ネットから取り込む'), findsOneWidget);
      });
    }

    testWidgets('取り込みタブで戻った時だけアプリを閉じる', (tester) async {
      final exits = _recordExit(tester);
      await tester.pumpWidget(MaterialApp(home: HomeShell(app: _app())));
      await tester.pumpAndSettle();

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(exits, hasLength(1));
    });

    testWidgets('ゴミ箱→アルバム→取り込み→閉じる の順に戻る', (tester) async {
      final exits = _recordExit(tester);
      await tester.pumpWidget(MaterialApp(home: HomeShell(app: _app())));
      await tester.pumpAndSettle();
      await tester.tap(_tab('アルバム'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'ゴミ箱'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'ゴミ箱'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('その他'), findsOneWidget);
      expect(_selected(tester), HomeShell.albumsTab);
      expect(exits, isEmpty);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(_selected(tester), HomeShell.importTab);
      expect(exits, isEmpty);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(exits, hasLength(1));
    });
  });

  group('アルバム詳細・フォルダもアルバムタブの子画面（#167）', () {
    // Kotlin 版は album/ browse/ trash/ を開いている間も下タブを描き、アルバムタブを点ける（selectedTabRoute）
    Future<_ChildApi> openAlbum(WidgetTester tester) async {
      final api = _ChildApi();
      await tester.pumpWidget(MaterialApp(home: HomeShell(app: _app(api))));
      await tester.pumpAndSettle();
      await tester.tap(_tab('アルバム'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('旅行'));
      await tester.pumpAndSettle();
      expect(find.byType(AlbumDetailScreen), findsOneWidget);
      return api;
    }

    Future<void> openSeed(WidgetTester tester) async {
      await tester.pumpWidget(
          MaterialApp(home: HomeShell(app: _app(_ChildApi()))));
      await tester.pumpAndSettle();
      await tester.tap(_tab('アルバム'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('フォルダ'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('seed'));
      await tester.pumpAndSettle();
      expect(find.byType(FolderBrowseScreen), findsOneWidget);
    }

    testWidgets('アルバムを開いても下タブが残ってアルバムが点き、写真へは1回で移れる', (tester) async {
      await openAlbum(tester);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(_selected(tester), HomeShell.albumsTab);
      // 見出しはアルバム詳細のもの（戻る付き）だけ
      expect(find.widgetWithText(AppBar, '旅行（1）'), findsOneWidget);
      expect(find.widgetWithText(AppBar, 'R2 Gallery'), findsNothing);
      expect(find.byType(BackButton), findsOneWidget);

      await tester.tap(_tab('写真'));
      await tester.pumpAndSettle();
      expect(_selected(tester), HomeShell.photosTab);
      expect(find.byType(AlbumDetailScreen), findsNothing);

      // アルバムタブに戻ると、開いていたアルバムの続きが出る（Kotlin 版の restoreState と同じ）
      await tester.tap(_tab('アルバム'));
      await tester.pumpAndSettle();
      expect(find.byType(AlbumDetailScreen), findsOneWidget);
    });

    testWidgets('見出しの戻る・端末の戻るでアルバム一覧へ帰って読み直し、次の戻るで取り込みへ', (tester) async {
      final exits = _recordExit(tester);
      final api = await openAlbum(tester);
      final loads = api.albumLoads;

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(AlbumDetailScreen), findsNothing);
      expect(find.text('その他'), findsOneWidget);
      expect(_selected(tester), HomeShell.albumsTab);
      expect(api.albumLoads, greaterThan(loads));

      await tester.tap(find.text('旅行'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(AlbumDetailScreen), findsNothing);
      expect(find.text('その他'), findsOneWidget);
      expect(exits, isEmpty);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(_selected(tester), HomeShell.importTab);
      expect(exits, isEmpty);
    });

    testWidgets('フォルダとサブフォルダも下タブを残して辿り、戻るで一つずつ帰る', (tester) async {
      await openSeed(tester);
      expect(find.widgetWithText(AppBar, 'seed'), findsOneWidget);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(_selected(tester), HomeShell.albumsTab);

      await tester.tap(find.text('sub'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'sub'), findsOneWidget);
      expect(find.text('このフォルダは空です'), findsOneWidget);
      expect(_selected(tester), HomeShell.albumsTab);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'seed'), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(FolderBrowseScreen), findsNothing);
      expect(find.text('seed'), findsOneWidget);
      expect(_selected(tester), HomeShell.albumsTab);
    });

    testWidgets('アルバムの中で選択中は下タブを隠し、戻るは選択を解くだけ', (tester) async {
      await openAlbum(tester);
      await tester.longPress(find.byType(MediaTile));
      await tester.pumpAndSettle();
      expect(find.text('1件を選択'), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('1件を選択'), findsNothing);
      expect(find.byType(AlbumDetailScreen), findsOneWidget);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(_selected(tester), HomeShell.albumsTab);
    });

    testWidgets('フォルダの中で選択中も下タブを隠し、戻るは選択を解くだけ', (tester) async {
      await openSeed(tester);
      await tester.longPress(find.byType(MediaTile));
      await tester.pumpAndSettle();
      expect(find.text('1件を選択'), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('1件を選択'), findsNothing);
      expect(find.widgetWithText(AppBar, 'seed'), findsOneWidget);
      expect(find.byType(NavigationBar), findsOneWidget);
    });

    testWidgets('開いたアルバムは、別のタブから戻った時に読み直して他のタブでの増減を映す', (tester) async {
      final api = await openAlbum(tester);
      final loads = api.albumPageLoads;

      await tester.tap(_tab('写真'));
      await tester.pumpAndSettle();
      // 裏にいる間は取りに行かない
      expect(api.albumPageLoads, loads);

      await tester.tap(_tab('アルバム'));
      await tester.pumpAndSettle();
      expect(find.byType(AlbumDetailScreen), findsOneWidget);
      expect(api.albumPageLoads, loads + 1);
    });

    testWidgets('開いたフォルダも、別のタブから戻った時に読み直す', (tester) async {
      final api = _ChildApi();
      await tester.pumpWidget(MaterialApp(home: HomeShell(app: _app(api))));
      await tester.pumpAndSettle();
      await tester.tap(_tab('アルバム'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('フォルダ'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('seed'));
      await tester.pumpAndSettle();
      final loads = api.folderPageLoads;

      await tester.tap(_tab('写真'));
      await tester.pumpAndSettle();
      expect(api.folderPageLoads, loads);

      await tester.tap(_tab('アルバム'));
      await tester.pumpAndSettle();
      expect(find.byType(FolderBrowseScreen), findsOneWidget);
      expect(api.folderPageLoads, loads + 1);
    });

    testWidgets('サブフォルダから戻ると、下に残っていた親フォルダも読み直す', (tester) async {
      final api = _ChildApi();
      await tester.pumpWidget(MaterialApp(home: HomeShell(app: _app(api))));
      await tester.pumpAndSettle();
      await tester.tap(_tab('アルバム'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('フォルダ'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('seed'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('sub'));
      await tester.pumpAndSettle();
      final loads = api.folderPageLoads;

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'seed'), findsOneWidget);
      expect(api.folderPageLoads, loads + 1);
    });

    testWidgets('写真タブでライブラリを替えたら、前のライブラリで開いていたアルバムは捨てる', (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final api = _ChildApi();
      final app = _app(api)
        ..libraries = const [
          Library(id: 'lib', title: 'L'),
          Library(id: 'lib2', title: 'L2'),
        ];
      await tester.pumpWidget(MaterialApp(home: HomeShell(app: app)));
      await tester.pumpAndSettle();
      await tester.tap(_tab('アルバム'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('旅行'));
      await tester.pumpAndSettle();
      expect(find.byType(AlbumDetailScreen), findsOneWidget);

      await tester.tap(_tab('写真'));
      await tester.pumpAndSettle();
      app.setLib('lib2');
      await tester.pumpAndSettle();

      await tester.tap(_tab('アルバム'));
      await tester.pumpAndSettle();
      expect(find.byType(AlbumDetailScreen), findsNothing);
      // 替えた先のライブラリのアルバム一覧が出る
      expect(find.text('その他'), findsOneWidget);
      expect(_selected(tester), HomeShell.albumsTab);
    });

    testWidgets('ライブラリを替えたらフォルダも捨て、ゴミ箱は残して今のライブラリを追う', (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final app = _app(_ChildApi())
        ..libraries = const [
          Library(id: 'lib', title: 'L'),
          Library(id: 'lib2', title: 'L2'),
        ];
      await tester.pumpWidget(MaterialApp(home: HomeShell(app: app)));
      await tester.pumpAndSettle();
      await tester.tap(_tab('アルバム'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('フォルダ'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('seed'));
      await tester.pumpAndSettle();
      expect(find.byType(FolderBrowseScreen), findsOneWidget);

      await tester.tap(_tab('写真'));
      await tester.pumpAndSettle();
      app.setLib('lib2');
      await tester.pumpAndSettle();
      await tester.tap(_tab('アルバム'));
      await tester.pumpAndSettle();
      expect(find.byType(FolderBrowseScreen), findsNothing);
      expect(find.text('その他'), findsOneWidget);

      await tester.tap(find.widgetWithText(ListTile, 'ゴミ箱'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'ゴミ箱'), findsOneWidget);
      app.setLib('lib');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'ゴミ箱'), findsOneWidget);
    });

    testWidgets('ゴミ箱を開いたまま別のタブへ移って戻ると、ゴミ箱の続きが出る', (tester) async {
      await tester.pumpWidget(MaterialApp(home: HomeShell(app: _app())));
      await tester.pumpAndSettle();
      await tester.tap(_tab('アルバム'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'ゴミ箱'));
      await tester.pumpAndSettle();
      await tester.tap(_tab('写真'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'ゴミ箱'), findsNothing);

      await tester.tap(_tab('アルバム'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'ゴミ箱'), findsOneWidget);
      expect(_selected(tester), HomeShell.albumsTab);
    });
  });

  group('ブラウザ表示中は下のタブを隠す（#165）', () {
    testWidgets('開くとタブが消え、閉じると取り込みタブのまま戻る', (tester) async {
      await tester.pumpWidget(MaterialApp(home: HomeShell(app: _app())));
      await tester.pumpAndSettle();
      await _openBrowser(tester);
      expect(find.byType(NavigationBar), findsNothing);

      await tester.tap(find.byTooltip('ブラウザを閉じる'));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(
          tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
          2);
      expect(find.text('動画ページのURLを入力して移動'), findsOneWidget);
    });

    testWidgets('端末の戻るでもブラウザを閉じ、アプリは閉じない', (tester) async {
      await tester.pumpWidget(MaterialApp(home: HomeShell(app: _app())));
      await tester.pumpAndSettle();
      await _openBrowser(tester);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(HomeShell), findsOneWidget);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.text('動画ページのURLを入力して移動'), findsOneWidget);
    });

    testWidgets('タブを隠しても、下端のジェスチャー帯の分は空けたまま', (tester) async {
      const inset = 48.0;
      final dpr = tester.view.devicePixelRatio;
      tester.view.padding = FakeViewPadding(bottom: inset * dpr);
      tester.view.viewPadding = FakeViewPadding(bottom: inset * dpr);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: HomeShell(app: _app())));
      await tester.pumpAndSettle();
      await _openBrowser(tester);
      expect(find.byType(NavigationBar), findsNothing);
      final screen = tester.view.physicalSize.height / dpr;
      // 取り込み画面（検出バーを含む）の下端が帯に重ならない
      expect(tester.getBottomLeft(find.byType(ImportBrowserTab)).dy,
          lessThanOrEqualTo(screen - inset));
    });

    testWidgets('別の URL へ移動し直しても、閉じるまでタブは隠れたまま', (tester) async {
      await tester.pumpWidget(MaterialApp(home: HomeShell(app: _app())));
      await tester.pumpAndSettle();
      await _openBrowser(tester);
      await tester.enterText(find.byType(TextField), 'example.org/other');
      await tester.tap(find.widgetWithIcon(FilledButton, Icons.public));
      await tester.pump();
      expect(find.byType(NavigationBar), findsNothing);
    });
  });

  group('ブラウザ表示中の端末の戻る（#165）', () {
    Future<List<bool>> openWith(WidgetTester tester, _FakeBack back) async {
      final opened = <bool>[];
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: ImportBrowserTab(
                  app: _app(), back: back, onBrowserOpenChanged: opened.add))));
      await tester.enterText(find.byType(TextField), 'example.com/video');
      await tester.tap(find.widgetWithIcon(FilledButton, Icons.public));
      await tester.pump();
      expect(opened, [true]);
      return opened;
    }

    testWidgets('ページを戻れる間は、ブラウザを閉じずにページを戻す', (tester) async {
      final back = _FakeBack(history: true);
      final opened = await openWith(tester, back);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(back.goBacks, 1);
      expect(opened, [true], reason: '閉じた通知を出すと下のタブが戻ってしまう');
      expect(find.byTooltip('ブラウザを閉じる'), findsOneWidget);
      expect(find.text('動画ページのURLを入力して移動'), findsNothing);
    });

    testWidgets('押した時点で履歴が尽きていれば、ページは戻さずブラウザを閉じる', (tester) async {
      final back = _FakeBack(history: true);
      final opened = await openWith(tester, back);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      // 開いた後に履歴が尽きた場合も、覚えた値ではなく押した時点の答えで決める
      back.history = false;
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(back.goBacks, 1);
      expect(opened, [true, false]);
      expect(find.text('動画ページのURLを入力して移動'), findsOneWidget);
    });
  });

  group('戻るの窓口は押した時点の WebView に聞く（#165）', () {
    test('つないだ先の答えを毎回聞き直し、外した後は戻れない扱い', () async {
      final back = BrowserBack();
      var history = true;
      var goBacks = 0;
      expect(await back.canGoBack(), isFalse);
      back.bind(canGoBack: () async => history, goBack: () => goBacks++);
      expect(await back.canGoBack(), isTrue);
      history = false;
      expect(await back.canGoBack(), isFalse);
      back.goBack();
      expect(goBacks, 1);
      back.unbind();
      history = true;
      expect(await back.canGoBack(), isFalse);
      back.goBack();
      expect(goBacks, 1);
    });
  });
}
