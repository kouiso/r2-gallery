import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/albums/album_detail_screen.dart';
import 'package:r2_gallery/src/albums/album_states.dart';
import 'package:r2_gallery/src/ui/folder_browse_screen.dart';
import 'package:r2_gallery/src/grid/day_label.dart';
import 'package:r2_gallery/src/grid/sort_mode.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/state/app_state.dart';
import 'package:r2_gallery/src/ui/albums_tab.dart';
import 'package:r2_gallery/src/ui/media_tile.dart';

MediaItem _img(String key, {String? lib, int? at, int? size}) => MediaItem(
    key: key,
    type: 'image',
    url: 'https://w.example/m/$key',
    lib: lib,
    createdAt: at,
    size: size);

/// worker の代わり。書き込み系は sendJson に来るので、メソッドとパスを記録して中身を変える。
class _FakeApi extends ApiClient {
  final List<String> calls = [];
  final List<Object?> bodies = [];
  List<Album> albumList = [];
  final Map<String, List<MediaItem>> albumItems = {};
  final Map<String, bool> albumRO = {};
  final Map<String, String> albumTitle = {};

  /// prefix → (items, subfolders)
  final Map<String, ({List<MediaItem> items, List<String> folders})> tree = {};
  int albumPageSize = 1000;
  final List<String> restored = [];
  int restoreStatus = 0;

  @override
  Future<List<Album>> albums(String libId) async {
    calls.add('GET albums $libId');
    return [
      for (final a in albumList)
        Album(
            id: a.id,
            title: albumTitle[a.id] ?? a.title,
            count: albumItems[a.id]?.length ?? a.count,
            readOnly: a.readOnly),
    ];
  }

  @override
  Future<AlbumPage> album(String libId, String albumId,
      {String? cursor, int limit = 60}) async {
    calls.add('GET album $albumId cursor=$cursor');
    final all = albumItems[albumId] ?? const <MediaItem>[];
    final size = limit < albumPageSize ? limit : albumPageSize;
    final start = cursor == null ? 0 : int.parse(cursor);
    final end = start + size > all.length ? all.length : start + size;
    return AlbumPage(
      items: all.sublist(start, end),
      cursor: end < all.length ? '$end' : null,
      title: albumTitle[albumId] ?? albumId,
      count: all.length,
      readOnly: albumRO[albumId] ?? false,
    );
  }

  @override
  Future<FolderPage> folder(String libId,
      {String prefix = '', String? cursor, bool recursive = false}) async {
    calls.add('GET folder $prefix');
    final t = tree[prefix];
    return FolderPage(
        items: t?.items ?? const [], folders: t?.folders ?? const []);
  }

  @override
  Future<String> trash(String libId, String key) async {
    calls.add('trash $libId:$key');
    for (final e in albumItems.entries) {
      e.value.removeWhere((i) => i.key == key);
    }
    return '.trash/1/$key';
  }

  @override
  Future<String> restore(String libId, String trashKey) async {
    if (restoreStatus != 0) throw ApiError(restoreStatus, 'conflict');
    restored.add(trashKey);
    return trashKey;
  }

  @override
  Future<dynamic> sendJson(String method, String path,
      {Object? body, Map<String, dynamic>? query}) async {
    calls.add('$method $path');
    bodies.add(body);
    final m = RegExp(r'^/v1/([^/]+)/albums(?:/([^/]+))?(/.*)?$').firstMatch(path);
    if (m != null && body is Map) {
      final id = m.group(2);
      final rest = m.group(3);
      if (method == 'POST' && id == null) {
        final nid = 'new${albumList.length}';
        albumList = [...albumList, Album(id: nid, title: '${body['title']}', readOnly: false)];
        albumItems[nid] = [];
        return {'id': nid, 'title': body['title']};
      }
      if (method == 'PATCH' && id != null) albumTitle[id] = '${body['title']}';
      if (rest == '/items/remove' && id != null) {
        final keys = body['keys'];
        if (keys is List) {
          albumItems[id]!.removeWhere((i) => keys.contains(i.key));
        }
      }
      if (rest == '/order' && id != null) {
        final order = body['items'];
        if (order is List) {
          final byKey = {for (final i in albumItems[id]!) i.key: i};
          albumItems[id] = [
            for (final o in order)
              if (o is Map) byKey[o['key']]!,
          ];
        }
      }
    }
    if (method == 'DELETE' && m != null) {
      albumList = albumList.where((a) => a.id != m.group(2)).toList();
    }
    return {'ok': true};
  }
}

AppState _app(_FakeApi api, {bool readOnly = false}) {
  final app = AppState(api: api, bakedEndpoint: '', bakedToken: '');
  // 書き込みのガード（#145）は未接続だと止めるので、接続済みから始める
  app.connected = true;
  app.libraries = [Library(id: 'a', title: 'A', readOnly: readOnly)];
  app.activeLib = 'a';
  return app;
}

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: child));

Finder _tile(String key) =>
    find.byWidgetPredicate((w) => w is MediaTile && w.item.key == key);

void main() {
  group('アルバム一覧', () {
    testWidgets('A1: 新規アルバムカードから名前を入れて作成すると一覧に出る', (t) async {
      final api = _FakeApi();
      await t.pumpWidget(_host(AlbumsTab(app: _app(api), lib: 'a')));
      await t.pumpAndSettle();
      expect(find.text('アルバムがありません'), findsNothing);
      await t.tap(find.text('アルバム作成'));
      await t.pumpAndSettle();
      expect(find.text('アルバムを作成'), findsOneWidget);
      await t.enterText(find.byType(TextField), '  旅行 ');
      await t.pump();
      await t.tap(find.text('作成'));
      await t.pumpAndSettle();
      expect(api.calls, contains('POST /v1/a/albums'));
      expect(api.bodies.last, {'title': '旅行'});
      expect(find.text('旅行'), findsOneWidget);
    });

    testWidgets('A1: 読み取り専用ライブラリでは作成の入口を出さない', (t) async {
      final api = _FakeApi();
      await t.pumpWidget(
          _host(AlbumsTab(app: _app(api, readOnly: true), lib: 'a')));
      await t.pumpAndSettle();
      expect(find.text('アルバム作成'), findsNothing);
      expect(find.byTooltip('アルバムを作成'), findsNothing);
    });

    testWidgets('A2: 長押しメニューから名前変更・確認つき削除', (t) async {
      final api = _FakeApi()
        ..albumList = [const Album(id: 'x', title: '家族', readOnly: false)];
      await t.pumpWidget(_host(AlbumsTab(app: _app(api), lib: 'a')));
      await t.pumpAndSettle();

      await t.longPress(find.text('家族'));
      await t.pumpAndSettle();
      await t.tap(find.text('名前を変更'));
      await t.pumpAndSettle();
      expect(find.text('アルバム名を変更'), findsOneWidget);
      await t.enterText(find.byType(TextField), '家族2');
      await t.pump();
      await t.tap(find.text('変更'));
      await t.pumpAndSettle();
      expect(api.calls, contains('PATCH /v1/a/albums/x'));
      expect(find.text('家族2'), findsOneWidget);

      await t.longPress(find.text('家族2'));
      await t.pumpAndSettle();
      await t.tap(find.text('削除'));
      await t.pumpAndSettle();
      expect(find.text('アルバムを削除しますか？'), findsOneWidget);
      expect(find.text('「家族2」を削除します。写真や動画は削除されません。'), findsOneWidget);
      await t.tap(find.widgetWithText(TextButton, '削除'));
      await t.pumpAndSettle();
      expect(api.calls, contains('DELETE /v1/a/albums/x'));
      expect(find.text('家族2'), findsNothing);
    });

    testWidgets('A2: 取り込みで作られたアルバムは長押ししてもメニューを出さない', (t) async {
      final api = _FakeApi()
        ..albumList = [const Album(id: 'p', title: '自動', readOnly: true)];
      await t.pumpWidget(_host(AlbumsTab(app: _app(api), lib: 'a')));
      await t.pumpAndSettle();
      await t.longPress(find.text('自動'));
      await t.pumpAndSettle();
      expect(find.text('名前を変更'), findsNothing);
    });

    testWidgets('A9: フォルダに切り替えると一覧が出て、フォルダを作成できる', (t) async {
      final api = _FakeApi()
        ..tree[''] = (items: <MediaItem>[], folders: ['seed/', 'trip/']);
      await t.pumpWidget(_host(AlbumsTab(app: _app(api), lib: 'a')));
      await t.pumpAndSettle();
      expect(find.text('seed'), findsNothing);
      await t.tap(find.text('フォルダ'));
      await t.pumpAndSettle();
      expect(find.text('seed'), findsOneWidget);
      expect(find.text('trip'), findsOneWidget);
      await t.tap(find.text('フォルダ作成'));
      await t.pumpAndSettle();
      expect(find.text('フォルダを作成'), findsOneWidget);
      await t.enterText(find.byType(TextField), 'made');
      await t.pump();
      await t.tap(find.text('作成'));
      await t.pumpAndSettle();
      expect(api.calls, contains('POST /v1/a/ops/mkdir'));
      expect(api.bodies.last, {'prefix': 'made'});
    });

    testWidgets('B1: フォルダを開くと階層をたどれ、空なら空と出す', (t) async {
      final api = _FakeApi()
        ..tree[''] = (items: <MediaItem>[], folders: ['seed/'])
        ..tree['seed/'] = (items: [_img('seed/a.jpg')], folders: ['seed/sub/'])
        ..tree['seed/sub/'] = (items: <MediaItem>[], folders: <String>[]);
      await t.pumpWidget(_host(AlbumsTab(app: _app(api), lib: 'a')));
      await t.pumpAndSettle();
      await t.tap(find.text('フォルダ'));
      await t.pumpAndSettle();
      await t.tap(find.text('seed'));
      await t.pumpAndSettle();
      expect(find.byType(FolderBrowseScreen), findsOneWidget);
      expect(find.widgetWithText(AppBar, 'seed'), findsOneWidget);
      expect(_tile('seed/a.jpg'), findsOneWidget);
      await t.tap(find.text('sub'));
      await t.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'sub'), findsOneWidget);
      expect(find.text('このフォルダは空です'), findsOneWidget);
      expect(api.calls, contains('GET folder seed/sub/'));
    });
  });

  group('フォルダ閲覧', () {
    // フォルダ閲覧は写真タブと同じ画面（#146）で、見出しの基準は端末の今日
    final today = DateTime.now();
    final day1 = DateTime(today.year, today.month, today.day, 10).millisecondsSinceEpoch;
    final day0 = DateTime(today.year, today.month, today.day - 1, 10).millisecondsSinceEpoch;

    _FakeApi seeded() => _FakeApi()
      ..albumList = [
        const Album(id: 'w', title: '書ける', readOnly: false),
        const Album(id: 'p', title: '自動', readOnly: true),
        const Album(id: '__other__', title: 'その他', readOnly: true),
      ]
      ..albumItems['w'] = []
      ..tree['f/'] = (
        items: [
          _img('f/b.jpg', at: day1, size: 10),
          _img('f/a.jpg', at: day1, size: 30),
          _img('f/c.jpg', at: day0, size: 20),
        ],
        folders: <String>[],
      );

    testWidgets('A3: 複数選択して「アルバムへ」→書けるアルバムだけ出て追加できる', (t) async {
      final api = seeded();
      await t.pumpWidget(_host(FolderBrowseScreen(
          app: _app(api), lib: 'a', prefix: 'f/')));
      await t.pumpAndSettle();
      await t.longPress(_tile('f/b.jpg'));
      await t.pump();
      await t.tap(_tile('f/c.jpg'));
      await t.pump();
      expect(find.text('2件を選択'), findsOneWidget);
      await t.tap(find.text('アルバムへ'));
      await t.pumpAndSettle();
      expect(find.text('書ける（0）'), findsOneWidget);
      expect(find.text('自動（0）'), findsNothing);
      expect(find.textContaining('その他'), findsNothing);
      await t.tap(find.text('書ける（0）'));
      await t.pumpAndSettle();
      expect(api.calls, contains('POST /v1/a/albums/w/items'));
      expect(api.bodies.last, {
        'keys': ['f/b.jpg', 'f/c.jpg']
      });
      expect(find.text('2件をアルバムに追加しました'), findsOneWidget);
      expect(find.text('2件を選択'), findsNothing);
    });

    testWidgets('A3: 新しい名前で作成してから追加する', (t) async {
      final api = seeded();
      await t.pumpWidget(_host(FolderBrowseScreen(
          app: _app(api), lib: 'a', prefix: 'f/')));
      await t.pumpAndSettle();
      await t.longPress(_tile('f/a.jpg'));
      await t.pump();
      await t.tap(find.text('アルバムへ'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), '新規');
      await t.pump();
      await t.tap(find.text('作成して追加'));
      await t.pumpAndSettle();
      expect(api.calls, containsAllInOrder(['POST /v1/a/albums', 'POST /v1/a/albums/new3/items']));
      expect(find.text('1件をアルバムに追加しました'), findsOneWidget);
    });

    testWidgets('B2: 日付見出しと日ごとの丸選択、名前順で見出しが消える', (t) async {
      final api = seeded();
      await t.pumpWidget(_host(FolderBrowseScreen(
          app: _app(api), lib: 'a', prefix: 'f/')));
      await t.pumpAndSettle();
      expect(find.text('今日'), findsOneWidget);
      expect(find.text('昨日'), findsOneWidget);

      await t.longPress(_tile('f/c.jpg'));
      await t.pump();
      expect(find.text('1件を選択'), findsOneWidget);
      // 今日の丸で今日の2件をまとめて選ぶ
      await t.tap(find.byKey(const ValueKey('day:今日')));
      await t.pump();
      expect(find.text('3件を選択'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('day:今日')));
      await t.pump();
      expect(find.text('1件を選択'), findsOneWidget);
      await t.tap(find.byTooltip('選択を解除'));
      await t.pump();

      await t.tap(find.byTooltip('並び替え'));
      await t.pumpAndSettle();
      await t.tap(find.text('名前順'));
      await t.pumpAndSettle();
      expect(find.text('今日'), findsNothing);
      final xs = t
          .widgetList<MediaTile>(find.byType(MediaTile))
          .map((w) => w.item.key)
          .toList();
      expect(xs, ['f/a.jpg', 'f/b.jpg', 'f/c.jpg']);
    });

    test('B2: 並び順の4種', () {
      final items = [
        _img('B.jpg', at: 2, size: 1),
        _img('a.jpg', at: 3, size: 5),
        _img('c.jpg', at: 1, size: 3),
      ];
      List<String> k(SortMode m) => m.sorted(items).map((e) => e.key).toList();
      expect(k(SortMode.dateNew), ['a.jpg', 'B.jpg', 'c.jpg']);
      expect(k(SortMode.dateOld), ['c.jpg', 'B.jpg', 'a.jpg']);
      expect(k(SortMode.name), ['a.jpg', 'B.jpg', 'c.jpg']);
      expect(k(SortMode.size), ['a.jpg', 'c.jpg', 'B.jpg']);
    });

    test('B2: 日付見出しの文言', () {
      final n = DateTime(2026, 10, 19, 12);
      int ms(DateTime d) => d.millisecondsSinceEpoch;
      expect(formatDayHeader(null, n), '日付不明');
      expect(formatDayHeader(ms(DateTime(2026, 10, 19, 1)), n), '今日');
      expect(formatDayHeader(ms(DateTime(2026, 10, 18, 23)), n), '昨日');
      expect(formatDayHeader(ms(DateTime(2026, 10, 8)), n), '10月8日 木曜日');
      expect(formatDayHeader(ms(DateTime(2025, 1, 1)), n), '2025年1月1日 水曜日');
    });

    testWidgets('B1: 読み取り専用では選択にも入らず操作バーを出さない', (t) async {
      final api = seeded();
      await t.pumpWidget(_host(FolderBrowseScreen(
          app: _app(api, readOnly: true), lib: 'a', prefix: 'f/')));
      await t.pumpAndSettle();
      await t.longPress(_tile('f/a.jpg'));
      await t.pump();
      // 写真タブと同じ画面（#146）なので、読み取り専用でも選べるのはオフライン保存だけ
      expect(find.text('アルバムへ'), findsNothing);
      expect(find.text('ゴミ箱へ'), findsNothing);
    });
  });

  group('アルバムの中', () {
    _FakeApi seeded({bool ro = false}) => _FakeApi()
      ..albumList = [Album(id: 'x', title: '旅', readOnly: ro)]
      ..albumTitle['x'] = '旅'
      ..albumRO['x'] = ro
      ..albumItems['x'] = [
        _img('1.jpg', lib: 'a'),
        _img('2.jpg', lib: 'a'),
        _img('3.jpg', lib: 'b'),
      ];

    Widget screen(_FakeApi api, {bool libRO = false}) => MaterialApp(
          home: AlbumDetailScreen(
            app: _app(api, readOnly: libRO),
            lib: 'a',
            album: const Album(id: 'x', title: '旅', readOnly: false),
          ),
        );

    testWidgets('A6/A8: 件数つきの見出し、長押しで選択、すべて選択/解除', (t) async {
      final api = seeded();
      await t.pumpWidget(screen(api));
      await t.pumpAndSettle();
      expect(find.text('旅（3）'), findsOneWidget);
      await t.longPress(_tile('1.jpg'));
      await t.pump();
      expect(find.text('1件を選択'), findsOneWidget);
      expect(find.text('前へ'), findsOneWidget);
      await t.tap(find.text('すべて選択'));
      await t.pump();
      expect(find.text('3件を選択'), findsOneWidget);
      // 2件以上では並び替えは出さない
      expect(find.text('前へ'), findsNothing);
      expect(find.text('外す'), findsOneWidget);
      await t.tap(find.text('すべて解除'));
      await t.pump();
      expect(find.text('旅（3）'), findsOneWidget);
    });

    testWidgets('A5: 選択1件を後ろへ動かすと全件の並びを書き戻す', (t) async {
      final api = seeded();
      await t.pumpWidget(screen(api));
      await t.pumpAndSettle();
      await t.longPress(_tile('1.jpg'));
      await t.pump();
      await t.tap(find.text('後ろへ'));
      await t.pumpAndSettle();
      expect(api.calls, contains('POST /v1/a/albums/x/order'));
      expect(api.bodies.last, {
        'items': [
          {'key': '2.jpg', 'lib': 'a'},
          {'key': '1.jpg', 'lib': 'a'},
          {'key': '3.jpg', 'lib': 'b'},
        ]
      });
      final xs = t
          .widgetList<MediaTile>(find.byType(MediaTile))
          .map((w) => w.item.key)
          .toList();
      expect(xs, ['2.jpg', '1.jpg', '3.jpg']);
    });

    testWidgets('A4: 選択して外すと、項目のライブラリごとに外す', (t) async {
      final api = seeded();
      await t.pumpWidget(screen(api));
      await t.pumpAndSettle();
      await t.longPress(_tile('1.jpg'));
      await t.pump();
      await t.tap(_tile('3.jpg'));
      await t.pump();
      await t.tap(find.text('外す'));
      await t.pumpAndSettle();
      expect(api.calls, contains('POST /v1/a/albums/x/items/remove'));
      expect(api.calls, contains('POST /v1/b/albums/x/items/remove'));
      expect(_tile('1.jpg'), findsNothing);
      expect(_tile('3.jpg'), findsNothing);
      expect(find.text('旅（1）'), findsOneWidget);
    });

    testWidgets('A7: ゴミ箱へ→元に戻すで復元する', (t) async {
      final api = seeded();
      await t.pumpWidget(screen(api));
      await t.pumpAndSettle();
      await t.longPress(_tile('2.jpg'));
      await t.pump();
      await t.tap(find.text('ゴミ箱へ'));
      await t.pumpAndSettle();
      expect(api.calls, contains('trash a:2.jpg'));
      expect(find.text('1件をゴミ箱に移しました'), findsOneWidget);
      await t.tap(find.text('元に戻す'));
      await t.pumpAndSettle();
      expect(api.restored, ['.trash/1/2.jpg']);
    });

    testWidgets('A7: 元に戻すが 409 なら同名があると伝える', (t) async {
      final api = seeded()..restoreStatus = 409;
      await t.pumpWidget(screen(api));
      await t.pumpAndSettle();
      await t.longPress(_tile('2.jpg'));
      await t.pump();
      await t.tap(find.text('ゴミ箱へ'));
      await t.pumpAndSettle();
      await t.tap(find.text('元に戻す'));
      await t.pumpAndSettle();
      expect(find.text('同じ名前の項目が元の場所にあるため戻せませんでした'), findsOneWidget);
    });

    testWidgets('A7: 選択中の長押しで個別メニュー、そこから外す', (t) async {
      final api = seeded();
      await t.pumpWidget(screen(api));
      await t.pumpAndSettle();
      await t.longPress(_tile('1.jpg'));
      await t.pump();
      await t.longPress(_tile('2.jpg'));
      await t.pumpAndSettle();
      expect(find.text('前に移す'), findsOneWidget);
      expect(find.text('アルバムに追加'), findsOneWidget);
      await t.tap(find.text('このアルバムから外す'));
      await t.pumpAndSettle();
      expect(_tile('2.jpg'), findsNothing);
    });

    testWidgets('A8: 読み取り専用アルバムでは並び替え・外すを出さない', (t) async {
      final api = seeded(ro: true);
      await t.pumpWidget(screen(api));
      await t.pumpAndSettle();
      await t.longPress(_tile('1.jpg'));
      await t.pump();
      expect(find.text('前へ'), findsNothing);
      expect(find.text('外す'), findsNothing);
      expect(find.text('ゴミ箱へ'), findsOneWidget);
    });

    testWidgets('A8: 読み取り専用ライブラリでは選択に入らない', (t) async {
      final api = seeded();
      await t.pumpWidget(screen(api, libRO: true));
      await t.pumpAndSettle();
      await t.longPress(_tile('1.jpg'));
      await t.pump();
      expect(find.text('1件を選択'), findsNothing);
    });

    testWidgets('A8: 末尾付近で続きを読み、引っ張って取り直す', (t) async {
      final api = _FakeApi()
        ..albumPageSize = 20
        ..albumTitle['x'] = '多い'
        ..albumItems['x'] = [for (var i = 0; i < 30; i++) _img('$i.jpg', lib: 'a')];
      await t.pumpWidget(screen(api));
      await t.pumpAndSettle();
      await t.drag(find.byType(CustomScrollView), const Offset(0, -3000));
      await t.pumpAndSettle();
      expect(api.calls, contains('GET album x cursor=20'));
      expect(_tile('29.jpg'), findsOneWidget);
      expect(find.text('多い（30）'), findsOneWidget);

      final before = api.calls.length;
      await t.drag(find.byType(CustomScrollView), const Offset(0, 3000));
      await t.pumpAndSettle();
      await t.fling(find.byType(CustomScrollView), const Offset(0, 600), 2000);
      await t.pumpAndSettle();
      expect(api.calls.sublist(before), contains('GET album x cursor=null'));
    });
  });

  test('A8: 続きの取得に失敗したら、取り直すまで自動では読みに行かない', () async {
    final api = _FailMoreApi();
    final s = AlbumDetailState(api, 'a', 'x');
    await s.refresh();
    await s.loadMore();
    await s.loadMore();
    expect(api.pages, ['null', '1']);
    expect(s.error, isNotNull);
    await s.refresh();
    await s.loadMore();
    expect(api.pages, ['null', '1', 'null', '1']);
  });

  // 統合（#145 の書き込みガードをアルバム操作とフォルダ作成にもつないだ）
  group('書き込みガード', () {
    testWidgets('書けないライブラリではアルバム作成もフォルダ作成も送らず理由を出す', (t) async {
      final api = _FakeApi();
      // 一覧に無いライブラリは書けるか分からないので、作成の入口は出ても送らない
      await t.pumpWidget(_host(AlbumsTab(app: _app(api), lib: 'zz')));
      await t.pumpAndSettle();
      await t.tap(find.text('アルバム作成'));
      await t.pumpAndSettle();
      expect(find.text('アルバムを作成'), findsNothing);
      expect(find.text('接続先にライブラリが見つかりません。接続先と権限を確認してください。'),
          findsOneWidget);

      await t.tap(find.text('フォルダ'));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('フォルダを作成'));
      await t.pumpAndSettle();
      expect(find.text('新しいフォルダ名'), findsNothing);
      expect(api.calls.where((c) => c.startsWith('POST')), isEmpty);
    });
  });
}

class _FailMoreApi extends ApiClient {
  final List<String> pages = [];
  @override
  Future<AlbumPage> album(String libId, String albumId,
      {String? cursor, int limit = 60}) async {
    pages.add('$cursor');
    if (cursor != null) throw const ApiError(500, 'boom');
    return AlbumPage(items: [_img('0.jpg')], cursor: '1', title: 't', count: 2, readOnly: false);
  }
}
