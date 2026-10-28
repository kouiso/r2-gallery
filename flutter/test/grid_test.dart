import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/grid/day_label.dart';
import 'package:r2_gallery/src/grid/media_grid.dart';
import 'package:r2_gallery/src/grid/sort_mode.dart';
import 'package:r2_gallery/src/state/app_state.dart';
import 'package:r2_gallery/src/ui/album_picker.dart';
import 'package:r2_gallery/src/ui/folder_browse_screen.dart';
import 'package:r2_gallery/src/ui/gallery_tab.dart';
import 'package:r2_gallery/src/ui/home_shell.dart';
import 'package:r2_gallery/src/ui/media_tile.dart';
import 'package:r2_gallery/src/viewer/device_export.dart';

final _now = DateTime.now();
int _daysAgo(int d, {int hour = 12}) =>
    DateTime(_now.year, _now.month, _now.day - d, hour).millisecondsSinceEpoch;

MediaItem _img(String key, {int? at, int size = 0, String? lib}) => MediaItem(
  key: key,
  type: 'image',
  url: 'https://w.example/m/$key',
  createdAt: at,
  size: size,
  lib: lib,
);

class _Api extends ApiClient {
  _Api(this.pages);

  /// prefix ごとの1ページ目。cursor 付きの続きは [more]。
  final Map<String, FolderPage> pages;
  final Map<String, FolderPage> more = {};
  final List<({String lib, String prefix, String? cursor, bool recursive})>
  folderCalls = [];
  bool failFolder = false;

  final List<(String, String)> trashed = [];
  final Set<String> failTrash = {};
  final List<(String, String)> restored = [];
  bool restoreConflict = false;

  List<Album> albumList = const [];
  final List<(String, String)> created = [];
  final List<(String, String, List<String>)> added = [];

  @override
  Future<FolderPage> folder(
    String libId, {
    String prefix = '',
    String? cursor,
    bool recursive = false,
  }) async {
    folderCalls.add((
      lib: libId,
      prefix: prefix,
      cursor: cursor,
      recursive: recursive,
    ));
    if (failFolder) throw const ApiError(500, 'boom');
    if (cursor != null) return more[cursor] ?? const FolderPage(items: []);
    return pages[prefix] ?? const FolderPage(items: []);
  }

  @override
  Future<String> trash(String libId, String key) async {
    if (failTrash.contains(key)) throw const ApiError(500, 'nope');
    trashed.add((libId, key));
    return 'tk-$key';
  }

  @override
  Future<String> restore(String libId, String trashKey) async {
    if (restoreConflict) throw const ApiError(409, 'exists');
    restored.add((libId, trashKey));
    return trashKey.substring(3);
  }

  @override
  Future<List<Album>> albums(String libId) async => albumList;

  @override
  Future<String> albumCreate(String libId, String title) async {
    created.add((libId, title));
    return 'new-album';
  }

  @override
  Future<void> albumAdd(String libId, String albumId, List<String> keys) async {
    added.add((libId, albumId, keys));
  }
}

/// 端末への書き出しを記録だけする（MediaStore もダウンロードも使わない）。
class _FakeExporter extends DeviceExporter {
  _FakeExporter(ApiClient api, this.exported, {this.supported = true})
      : super(api: api);
  final List<String> exported;
  @override
  final bool supported;
  @override
  Future<void> export(MediaItem item, String lib,
      {Future<void> Function(Future<void> Function() body)? guardSave}) async {
    exported.add(item.key);
  }
}

/// オフライン保存の可否と積んだ中身だけを差し替える（転送キューや暗号化は #149 のテストが見る）。
class _TestApp extends AppState {
  _TestApp(ApiClient api) : super(api: api, bakedEndpoint: '', bakedToken: '');
  bool offlineOn = false;
  final saved = <(String, List<String>)>[];
  @override
  bool get offlineSupported => offlineOn;
  @override
  Future<int> saveOffline(String fallbackLib, List<MediaItem> items) async {
    saved.add((fallbackLib, [for (final i in items) i.key]));
    return items.length;
  }
}

_TestApp _app(_Api api, {bool readOnly = false}) {
  final app = _TestApp(api);
  // #145 以降、未接続のシェルは接続画面を出すので、接続済みの状態から始める
  app.connected = true;
  app.libraries = [
    Library(id: 'a', title: 'A', readOnly: readOnly),
    const Library(id: 'b', title: 'B'),
  ];
  app.activeLib = 'a';
  return app;
}

Future<void> _pumpShell(WidgetTester tester, AppState app) async {
  await tester.pumpWidget(MaterialApp(home: HomeShell(app: app, initialTab: HomeShell.photosTab)));
  await tester.pumpAndSettle();
}

/// ジェスチャーナビの端末を真似て、下端に触れない帯を作る。帯の高さ（論理ピクセル）を返す
double _withBottomInset(WidgetTester tester) {
  const inset = 48.0;
  final dpr = tester.view.devicePixelRatio;
  tester.view.padding = FakeViewPadding(bottom: inset * dpr);
  tester.view.viewPadding = FakeViewPadding(bottom: inset * dpr);
  addTearDown(tester.view.reset);
  return inset;
}

Finder _tile(String key) =>
    find.byWidgetPredicate((w) => w is MediaTile && w.item.key == key);

List<String> _tileOrder(WidgetTester tester) {
  final tiles = tester.widgetList<MediaTile>(find.byType(MediaTile)).toList();
  final pos = {
    for (final t in tiles) t.item.key: tester.getTopLeft(_tile(t.item.key)),
  };
  final keys = pos.keys.toList()
    ..sort((a, b) {
      final dy = pos[a]!.dy.compareTo(pos[b]!.dy);
      return dy != 0 ? dy : pos[a]!.dx.compareTo(pos[b]!.dx);
    });
  return keys;
}

/// 今日2枚・昨日1枚・日付不明1枚
_Api _threeDays() => _Api({
  '': FolderPage(
    items: [
      _img('t1.jpg', at: _daysAgo(0, hour: 10), size: 5),
      _img('t2.jpg', at: _daysAgo(0, hour: 9), size: 50),
      _img('y1.jpg', at: _daysAgo(1), size: 500),
      _img('none.jpg'),
    ],
  ),
});

void main() {
  group('H1 並び替え', () {
    test('4種の並びと、同点は元の順を保つ', () {
      final items = [
        _img('b.jpg', at: 2, size: 10),
        _img('A.jpg', at: 1, size: 30),
        _img('c.jpg', at: 2, size: 10),
      ];
      List<String> keys(SortMode m) => [for (final i in m.sorted(items)) i.key];
      expect(keys(SortMode.dateNew), ['b.jpg', 'c.jpg', 'A.jpg']);
      expect(keys(SortMode.dateOld), ['A.jpg', 'b.jpg', 'c.jpg']);
      expect(keys(SortMode.name), ['A.jpg', 'b.jpg', 'c.jpg']);
      expect(keys(SortMode.size), ['A.jpg', 'b.jpg', 'c.jpg']);
    });

    testWidgets('メニューで「サイズ順」を選ぶと並びが変わり、日付見出しが消える', (tester) async {
      await _pumpShell(tester, _app(_threeDays()));
      expect(find.text('今日'), findsOneWidget);
      expect(_tileOrder(tester).first, 't1.jpg');

      await tester.tap(find.byTooltip('並び替え'));
      await tester.pumpAndSettle();
      expect(find.text('新しい順'), findsOneWidget);
      expect(find.text('古い順'), findsOneWidget);
      expect(find.text('名前順'), findsOneWidget);
      await tester.tap(find.text('サイズ順'));
      await tester.pumpAndSettle();

      expect(_tileOrder(tester), ['y1.jpg', 't2.jpg', 't1.jpg', 'none.jpg']);
      expect(find.text('今日'), findsNothing);
    });
  });

  group('H2 日付見出し', () {
    test('今日・昨日・今年は曜日つき・去年は年つき・無ければ日付不明', () {
      final now = DateTime(2026, 10, 19, 15);
      int at(int y, int m, int d) =>
          DateTime(y, m, d, 8).millisecondsSinceEpoch;
      expect(formatDayHeader(at(2026, 10, 19), now), '今日');
      expect(formatDayHeader(at(2026, 10, 18), now), '昨日');
      expect(formatDayHeader(at(2026, 10, 8), now), '10月8日 木曜日');
      expect(formatDayHeader(at(2025, 12, 31), now), '2025年12月31日 水曜日');
      expect(formatDayHeader(null, now), '日付不明');
      expect(formatShortDate(at(2026, 10, 9), now), '10月9日');
      expect(
        formatDateTime(
          DateTime(2026, 10, 8, 18, 42).millisecondsSinceEpoch,
          now,
        ),
        '10月8日 木曜日 18:42',
      );
    });

    testWidgets('写真タブに日ごとの見出しが出る', (tester) async {
      await _pumpShell(tester, _app(_threeDays()));
      expect(find.text('今日'), findsOneWidget);
      expect(find.text('昨日'), findsOneWidget);
      expect(find.text('日付不明'), findsOneWidget);
    });
  });

  group('H3/H14 選択', () {
    testWidgets('見出しの丸でその日をまとめて選択・解除できる', (tester) async {
      await _pumpShell(tester, _app(_threeDays()));
      await tester.longPress(_tile('y1.jpg'));
      await tester.pumpAndSettle();
      expect(find.text('1件を選択'), findsOneWidget);

      // 見出しは 今日・昨日・日付不明 の順。今日の丸を押す
      await tester.tap(find.byKey(const ValueKey('day:今日')));
      await tester.pumpAndSettle();
      expect(find.text('3件を選択'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('day:今日')));
      await tester.pumpAndSettle();
      expect(find.text('1件を選択'), findsOneWidget);
    });

    testWidgets('選択中は見出しが「N件を選択」になり、すべて選択/すべて解除を切り替えられる', (tester) async {
      await _pumpShell(tester, _app(_threeDays()));
      expect(find.text('B'), findsOneWidget);
      await tester.longPress(_tile('t1.jpg'));
      await tester.pumpAndSettle();

      expect(find.text('1件を選択'), findsOneWidget);
      // 選択中はライブラリ切替と下のタブを出さない
      expect(find.text('B'), findsNothing);
      expect(find.byType(NavigationBar), findsNothing);

      await tester.tap(find.text('すべて選択'));
      await tester.pumpAndSettle();
      expect(find.text('4件を選択'), findsOneWidget);

      await tester.tap(find.text('すべて解除'));
      await tester.pumpAndSettle();
      expect(find.text('R2 Gallery'), findsOneWidget);
      expect(find.byType(NavigationBar), findsOneWidget);
    });

    testWidgets('選択中の端末の戻るは選択を解くだけで、写真タブに残る', (tester) async {
      await _pumpShell(tester, _app(_threeDays()));
      await tester.longPress(_tile('t1.jpg'));
      await tester.pumpAndSettle();
      expect(find.text('1件を選択'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('R2 Gallery'), findsOneWidget);
      expect(
          tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
          HomeShell.photosTab);
    });

    testWidgets('閉じるボタンで選択を抜ける', (tester) async {
      await _pumpShell(tester, _app(_threeDays()));
      await tester.longPress(_tile('t1.jpg'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('選択を解除'));
      await tester.pumpAndSettle();
      expect(find.text('R2 Gallery'), findsOneWidget);
    });
  });

  group('H4/H9 選択バーとゴミ箱の元に戻す', () {
    testWidgets('文字付きの操作が並び、オフライン保存できない環境ではオフラインを出さない', (tester) async {
      final app = _app(_threeDays());
      await _pumpShell(tester, app);
      await tester.longPress(_tile('t1.jpg'));
      await tester.pumpAndSettle();
      expect(find.text('アルバムへ'), findsOneWidget);
      expect(find.text('ゴミ箱へ'), findsOneWidget);
      expect(find.text('オフライン'), findsNothing);
    });

    testWidgets('下端にジェスチャー帯がある端末でも、操作バーは帯の上に収まって押せる', (tester) async {
      final inset = _withBottomInset(tester);
      final api = _threeDays();
      await _pumpShell(tester, _app(api));
      await tester.longPress(_tile('t1.jpg'));
      await tester.pumpAndSettle();

      final screenBottom =
          tester.view.physicalSize.height / tester.view.devicePixelRatio;
      for (final label in ['アルバムへ', 'ゴミ箱へ']) {
        final button = find.ancestor(
            of: find.text(label), matching: find.byType(InkWell));
        expect(tester.getRect(button).bottom,
            lessThanOrEqualTo(screenBottom - inset),
            reason: '「$label」の押せる範囲が下端の帯に食い込んでいる');
      }
      await tester.tap(find.text('ゴミ箱へ'));
      await tester.pumpAndSettle();
      expect(api.trashed, hasLength(1));
    });

    testWidgets('オフライン保存できる環境なら、選んだ分をライブラリごとに #149 のオフライン保存へ積む', (tester) async {
      final app = _app(_threeDays())..offlineOn = true;
      final saved = app.saved;
      await _pumpShell(tester, app);
      await tester.longPress(_tile('t1.jpg'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('オフライン'));
      await tester.pumpAndSettle();
      expect(saved.single.$1, 'a');
      expect(saved.single.$2, ['t1.jpg']);
      expect(find.text('1件をオフライン保存に追加しました'), findsOneWidget);
    });

    testWidgets('ゴミ箱へ送ると「元に戻す」が出て、押すと trashKey で戻す', (tester) async {
      final api = _threeDays();
      await _pumpShell(tester, _app(api));
      await tester.longPress(_tile('t1.jpg'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('すべて選択'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ゴミ箱へ'));
      await tester.pumpAndSettle();

      expect(api.trashed.length, 4);
      expect(find.text('4件をゴミ箱に移しました'), findsOneWidget);
      await tester.tap(find.text('元に戻す'));
      await tester.pumpAndSettle();
      expect(api.restored, contains(('a', 'tk-t1.jpg')));
      expect(api.restored.length, 4);
    });

    testWidgets('元の場所に同じ名前があると戻せなかった旨を出す', (tester) async {
      final api = _threeDays()..restoreConflict = true;
      await _pumpShell(tester, _app(api));
      await tester.longPress(_tile('t1.jpg'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ゴミ箱へ'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('元に戻す'));
      await tester.pumpAndSettle();
      expect(find.text('同じ名前の項目が元の場所にあるため戻せませんでした'), findsOneWidget);
    });

    testWidgets('「元に戻す」は6秒で消える', (tester) async {
      final api = _threeDays();
      await _pumpShell(tester, _app(api));
      await tester.longPress(_tile('t1.jpg'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ゴミ箱へ'));
      await tester.pumpAndSettle();
      expect(find.text('元に戻す'), findsOneWidget);
      await tester.pump(const Duration(seconds: 7));
      await tester.pumpAndSettle();
      expect(find.text('元に戻す'), findsNothing);
      expect(api.restored, isEmpty);
    });

    testWidgets('送れなかった件数を知らせる', (tester) async {
      final api = _threeDays()..failTrash.add('t2.jpg');
      await _pumpShell(tester, _app(api));
      await tester.longPress(_tile('t1.jpg'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('すべて選択'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ゴミ箱へ'));
      await tester.pumpAndSettle();
      expect(find.text('1件をゴミ箱に移せませんでした'), findsOneWidget);
    });
  });

  group('H5 アルバムへ', () {
    test('200件ずつに分けて送り、別ライブラリが混ざったら送らない', () async {
      final calls = <List<String>>[];
      await bulkAddToAlbum(
        create: (l, t) async => 'x',
        add: (l, id, keys) async => calls.add(keys),
        fallbackLib: 'a',
        targets: [for (var i = 0; i < 450; i++) ('a', 'k$i')],
        albumId: 'al',
      );
      expect([for (final c in calls) c.length], [200, 200, 50]);

      calls.clear();
      await expectLater(
        bulkAddToAlbum(
          create: (l, t) async => 'x',
          add: (l, id, keys) async => calls.add(keys),
          fallbackLib: 'a',
          targets: [('a', 'k1'), ('b', 'k2')],
          albumId: 'al',
        ),
        throwsA(isA<MixedLibraryError>()),
      );
      expect(calls, isEmpty);
    });

    testWidgets('書き込めるアルバムだけ選べて、選ぶと選択分を追加する', (tester) async {
      final api = _threeDays()
        ..albumList = const [
          Album(id: 'al1', title: '旅行', count: 3, readOnly: false),
          Album(id: '__other__', title: 'その他', readOnly: false),
          Album(id: 'auto', title: '自動', readOnly: true),
        ];
      await _pumpShell(tester, _app(api));
      await tester.longPress(_tile('t1.jpg'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('day:今日')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('アルバムへ'));
      await tester.pumpAndSettle();

      expect(find.text('旅行（3）'), findsOneWidget);
      expect(find.textContaining('その他'), findsNothing);
      expect(find.textContaining('自動'), findsNothing);
      await tester.tap(find.text('旅行（3）'));
      await tester.pumpAndSettle();

      expect(api.added.single.$2, 'al1');
      expect(api.added.single.$3.toSet(), {'t1.jpg', 't2.jpg'});
      expect(find.text('2件をアルバムに追加しました'), findsOneWidget);
      expect(find.text('R2 Gallery'), findsOneWidget);
    });

    testWidgets('新しい名前を入れると作成してから追加する', (tester) async {
      final api = _threeDays();
      await _pumpShell(tester, _app(api));
      await tester.longPress(_tile('y1.jpg'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('アルバムへ'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '  夏  ');
      await tester.pump();
      await tester.tap(find.text('作成して追加'));
      await tester.pumpAndSettle();
      expect(api.created.single, ('a', '夏'));
      expect(api.added.single.$2, 'new-album');
      expect(api.added.single.$3, ['y1.jpg']);
    });
  });

  group('H7 長押しの個別メニュー', () {
    testWidgets('選択中の長押しで個別メニュー。ゴミ箱へはすぐ送って元に戻すを出す', (tester) async {
      final api = _threeDays();
      // 端末へ書き出せない環境（web 等）では「端末に保存」を出さない
      final app = _app(api)
        ..deviceExporter = _FakeExporter(api, [], supported: false);
      await _pumpShell(tester, app);
      await tester.longPress(_tile('t1.jpg'));
      await tester.pumpAndSettle();
      await tester.longPress(_tile('y1.jpg'));
      await tester.pumpAndSettle();

      expect(find.text('アルバムに追加'), findsOneWidget);
      expect(find.text('端末に保存'), findsNothing);
      await tester.tap(find.text('ゴミ箱へ').last);
      await tester.pumpAndSettle();
      expect(api.trashed, [('a', 'y1.jpg')]);
      expect(find.text('1件をゴミ箱に移しました'), findsOneWidget);
    });

    testWidgets('読み取り専用では書き換える項目を出さず、端末に保存だけ出す', (tester) async {
      final api = _threeDays();
      final exported = <String>[];
      final app = _app(api, readOnly: true)..offlineOn = true;
      // 長押しの「端末に保存」は、ビューワーと同じ AppState.exportToDevice（#147）を通る
      app.deviceExporter = _FakeExporter(api, exported);
      await _pumpShell(tester, app);
      await tester.longPress(_tile('t1.jpg'));
      await tester.pumpAndSettle();
      // 読み取り専用の選択バーはオフラインだけ
      expect(find.text('アルバムへ'), findsNothing);
      expect(find.text('ゴミ箱へ'), findsNothing);
      expect(find.text('オフライン'), findsOneWidget);

      await tester.longPress(_tile('t2.jpg'));
      await tester.pumpAndSettle();
      expect(find.text('このライブラリは読み取り専用です'), findsOneWidget);
      expect(find.text('アルバムに追加'), findsNothing);
      await tester.tap(find.text('端末に保存'));
      await tester.pumpAndSettle();
      expect(exported, ['t2.jpg']);
      expect(find.text('端末に保存しました'), findsOneWidget);
    });
  });

  group('H10 読み取り専用', () {
    testWidgets('鍵を付け、追加ボタンを出さず、長押しでも選択に入らない', (tester) async {
      final app = _app(_threeDays(), readOnly: true);
      await _pumpShell(tester, app);
      expect(find.byIcon(Icons.lock), findsOneWidget);
      expect(find.text('追加'), findsNothing);
      await tester.longPress(_tile('t1.jpg'));
      await tester.pumpAndSettle();
      expect(find.textContaining('件を選択'), findsNothing);
    });

    testWidgets('空の読み取り専用ライブラリでは「写真・動画を追加」を出さない', (tester) async {
      await _pumpShell(tester, _app(_Api({}), readOnly: true));
      expect(find.text('まだ写真がありません'), findsOneWidget);
      expect(find.text('写真・動画を追加'), findsNothing);
    });
  });

  group('H12 グリッド', () {
    test('スマホの幅で4列', () {
      expect(gridColumnsFor(360), 4);
      expect(gridColumnsFor(411), 4);
      expect(gridColumnsFor(80), 1);
    });

    testWidgets('見出しの無い並びでも、末尾9件手前まで見えたら続きを取る', (tester) async {
      final api = _Api({
        '': FolderPage(
          items: [
            for (var i = 0; i < 12; i++) _img('p$i.jpg', at: _daysAgo(i)),
          ],
          cursor: 'c1',
        ),
      });
      api.more['c1'] = FolderPage(items: [_img('next.jpg', at: _daysAgo(40))]);
      final app = _app(api)..photosChrome.sort = SortMode.name;
      await _pumpShell(tester, app);
      expect(api.folderCalls.map((c) => c.cursor), contains('c1'));
      expect(_tile('next.jpg'), findsOneWidget);
    });

    testWidgets('選択中は丸のチェックが出て、選んだタイルだけ選択中になる', (tester) async {
      await _pumpShell(tester, _app(_threeDays()));
      await tester.longPress(_tile('t1.jpg'));
      await tester.pumpAndSettle();
      expect(tester.widget<MediaTile>(_tile('t1.jpg')).selected, isTrue);
      expect(tester.widget<MediaTile>(_tile('t2.jpg')).selected, isFalse);
      expect(find.byIcon(Icons.check), findsOneWidget);
    });
  });

  group('H13 空・エラー', () {
    testWidgets('読み込めない時は理由と「再試行」「接続先を確認する」を出す', (tester) async {
      final api = _Api({})..failFolder = true;
      var openedSettings = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GalleryTab(
              app: _app(api),
              lib: 'a',
              onOpenSettings: () => openedSettings++,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('読み込めませんでした'), findsOneWidget);
      expect(find.textContaining('通信状態を確認して'), findsOneWidget);
      await tester.tap(find.text('接続先を確認する'));
      expect(openedSettings, 1);

      api.failFolder = false;
      api.pages[''] = FolderPage(items: [_img('ok.jpg', at: _daysAgo(0))]);
      await tester.tap(find.text('再試行'));
      await tester.pumpAndSettle();
      expect(_tile('ok.jpg'), findsOneWidget);
    });

    testWidgets('一覧が出ている時の更新失敗は、一覧を残したまま帯で知らせる', (tester) async {
      final api = _threeDays();
      await _pumpShell(tester, _app(api));
      api.failFolder = true;
      await tester.fling(
        find.byType(CustomScrollView),
        const Offset(0, 400),
        1000,
      );
      await tester.pumpAndSettle();
      expect(find.text('HTTP 500: boom'), findsOneWidget);
      expect(_tile('t1.jpg'), findsOneWidget);
    });

    testWidgets('空なら案内と「写真・動画を追加」を出す', (tester) async {
      await _pumpShell(tester, _app(_Api({})));
      expect(find.text('まだ写真がありません'), findsOneWidget);
      expect(find.text('写真・動画を追加'), findsOneWidget);
    });
  });

  group('H15 フォルダ', () {
    testWidgets('末尾のフォルダカードから下の階層へ辿れる', (tester) async {
      final api = _Api({
        'trip/': FolderPage(
          items: [_img('trip/a.jpg', at: _daysAgo(0))],
          folders: ['trip/day1/'],
        ),
        'trip/day1/': FolderPage(
          items: [_img('trip/day1/b.jpg', at: _daysAgo(0))],
        ),
      });
      final app = _app(api);
      await tester.pumpWidget(
        MaterialApp(
          home: FolderBrowseScreen(app: app, lib: 'a', prefix: 'trip/'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('trip'), findsOneWidget);
      expect(_tile('trip/a.jpg'), findsOneWidget);
      expect(api.folderCalls.last.recursive, isFalse);

      await tester.tap(find.text('day1'));
      await tester.pumpAndSettle();
      expect(api.folderCalls.last.prefix, 'trip/day1/');
      expect(_tile('trip/day1/b.jpg'), findsOneWidget);
    });

    testWidgets('空のフォルダは空と出す', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: FolderBrowseScreen(app: _app(_Api({})), lib: 'a', prefix: 'x/'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('このフォルダは空です'), findsOneWidget);
    });
  });

  // 統合（#145 の書き込みガードを単発のゴミ箱にもつないだ）
  group('書き込みガード', () {
    testWidgets('長押しの「ゴミ箱へ」も、書けないライブラリなら送らず理由を出す', (tester) async {
      final api = _Api({
        '': FolderPage(items: [
          _img('t1.jpg', at: _daysAgo(0)),
          // 一覧に無いライブラリの項目（書けるか分からないので送らない）
          _img('x.jpg', at: _daysAgo(0), lib: 'zz'),
        ]),
      });
      await _pumpShell(tester, _app(api));
      await tester.longPress(_tile('t1.jpg'));
      await tester.pumpAndSettle();
      await tester.longPress(_tile('x.jpg'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ゴミ箱へ').last);
      await tester.pumpAndSettle();
      expect(api.trashed, isEmpty);
      expect(find.text('接続先にライブラリが見つかりません。接続先と権限を確認してください。'),
          findsOneWidget);
    });
  });
}
