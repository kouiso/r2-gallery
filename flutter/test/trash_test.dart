import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/state/app_state.dart';
import 'package:r2_gallery/src/state/trash_ops.dart';
import 'package:r2_gallery/src/ui/home_shell.dart';
import 'package:r2_gallery/src/ui/media_tile.dart';
import 'package:r2_gallery/src/ui/trash_parts.dart';
import 'package:r2_gallery/src/viewer/viewer_format.dart';
import 'package:r2_gallery/src/ui/trash_tab.dart';
import 'package:r2_gallery/src/ui/trash_undo.dart';

/// Worker の代わり。ゴミ箱の出し入れを手元の表で再現し、失敗させたい復元はステータスで指定する
class _TrashApi extends ApiClient {
  final List<MediaItem> files;
  final List<TrashItem> trashed = [];
  final List<String> trashCalls = [];
  final List<String> restoreCalls = [];
  final Map<String, int> restoreFails = {};
  int? retentionDays = 14;
  int trashListCalls = 0;
  bool failTrashList = false;
  String? nextCursor;

  _TrashApi({this.files = const []});

  @override
  Future<List<Album>> albums(String libId) async => const [];

  @override
  Future<FolderPage> folder(String libId,
          {String prefix = '', String? cursor, bool recursive = false}) async =>
      FolderPage(items: [
        for (final f in files)
          if (!trashed.any((t) => t.key == f.key)) f
      ]);

  @override
  Future<String> trash(String libId, String key) async {
    trashCalls.add('$libId:$key');
    final tk = '.trash/1000/$key';
    trashed.add(TrashItem(trashKey: tk, key: key, deletedAt: 1000, size: 1));
    return tk;
  }

  @override
  Future<String> restore(String libId, String trashKey) async {
    restoreCalls.add('$libId:$trashKey');
    final fail = restoreFails[trashKey];
    if (fail != null) throw ApiError(fail, 'x');
    trashed.removeWhere((t) => t.trashKey == trashKey);
    return trashKey;
  }

  @override
  Future<TrashPage> trashList(String libId, {String? cursor}) async {
    trashListCalls++;
    if (failTrashList) throw const ApiError(500, 'boom');
    if (cursor == null && nextCursor != null) {
      return TrashPage(trashed.take(1).toList(), nextCursor,
          retentionDays: retentionDays);
    }
    final rest = nextCursor != null ? trashed.skip(1) : trashed;
    return TrashPage(rest.toList(), null, retentionDays: retentionDays);
  }
}

class _FailingAlbumsApi extends _TrashApi {
  @override
  Future<List<Album>> albums(String libId) async =>
      throw const ApiError(500, 'boom');
}

MediaItem _img(String key) =>
    MediaItem(key: key, type: 'image', url: 'https://w.example/m/$key');

// 2026年10月9日 10:00 （端末のタイムゾーンで）
final _oct9 = DateTime(2026, 10, 9, 10).millisecondsSinceEpoch;
DateTime _now() => DateTime(2026, 10, 19, 12);

TrashItem _trashItem(String key, {int? deletedAt, int size = 3250586}) =>
    TrashItem(
        trashKey: '.trash/${deletedAt ?? _oct9}/$key',
        key: key,
        deletedAt: deletedAt ?? _oct9,
        size: size);

// 書き込みのガード（#145）は未接続だと止めるので、接続済みから始める
AppState _app(ApiClient api, {bool readOnly = false}) =>
    AppState(api: api, bakedEndpoint: '', bakedToken: '')
      ..connected = true
      ..libraries = [Library(id: 'lib', title: 'L', readOnly: readOnly)]
      ..activeLib = 'lib';

Widget _trashHost(AppState app) => MaterialApp(
    home: Scaffold(body: TrashTab(app: app, lib: 'lib', clock: _now)));

void main() {
  group('T1 ゴミ箱へ → 元に戻す', () {
    Future<_TrashApi> trashTwo(WidgetTester tester) async {
      final api = _TrashApi(files: [_img('a.jpg'), _img('b.jpg')]);
      final app = _app(api);
      // 選択バーは写真タブではなくシェルが描く（#146）ので、シェルごと出す
      await tester.pumpWidget(MaterialApp(home: HomeShell(app: app, initialTab: HomeShell.photosTab)));
      await tester.pumpAndSettle();
      await tester.longPress(find.byType(MediaTile).first);
      await tester.pump();
      await tester.tap(find.byType(MediaTile).last);
      await tester.pump();
      await tester.tap(find.text('ゴミ箱へ'));
      await tester.pump();
      await tester.pump();
      // スナックバーが下から出きるまで進める（6秒の計時は出きってから始まる）
      await tester.pump(const Duration(milliseconds: 500));
      return api;
    }

    testWidgets('一括でゴミ箱へ送ると「元に戻す」が出て、押すと全部戻る', (tester) async {
      final api = await trashTwo(tester);
      expect(api.trashCalls, hasLength(2));
      expect(find.text('2件をゴミ箱に移しました'), findsOneWidget);
      expect(find.byType(MediaTile), findsNothing);

      await tester.tap(find.text('元に戻す'));
      await tester.pumpAndSettle();

      expect(api.restoreCalls, ['lib:.trash/1000/a.jpg', 'lib:.trash/1000/b.jpg']);
      // 戻した後は一覧を読み直して、写真が元どおり並ぶ
      expect(find.byType(MediaTile), findsNWidgets(2));
    });

    testWidgets('6秒たつと「元に戻す」は消え、何も戻さない', (tester) async {
      final api = await trashTwo(tester);
      expect(find.text('元に戻す'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('元に戻す'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text('元に戻す'), findsNothing);
      expect(api.restoreCalls, isEmpty);
    });

    testWidgets('元の場所に同名があって戻せない時は理由を出す', (tester) async {
      final api = _TrashApi()..restoreFails['.trash/1/x.jpg'] = 409;
      late ScaffoldMessengerState messenger;
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(
        builder: (context) {
          messenger = ScaffoldMessenger.of(context);
          return const SizedBox();
        },
      ))));
      var restored = 0;
      final done = offerTrashUndo(messenger, api,
          const [TrashReceipt('lib', '.trash/1/x.jpg')],
          onRestored: () => restored++);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('元に戻す'));
      await tester.pumpAndSettle();
      await done;
      expect(restored, 1);
      expect(find.text('同じ名前の項目が元の場所にあるため戻せませんでした'), findsOneWidget);
    });

    test('一部だけ戻せなかった時は件数で伝える', () {
      expect(
          restoreSummaryMessage(const RestoreOutcome(
              total: 3, restored: 2, other: 1)),
          '3件中1件を戻せませんでした');
      expect(
          restoreSummaryMessage(const RestoreOutcome(total: 2, restored: 2)),
          isNull);
    });
  });

  group('T2 行ごとの復元と失敗理由', () {
    for (final (status, message) in [
      (409, '同じ名前の項目が元の場所にあるため戻せませんでした'),
      (403, 'このライブラリは読み取り専用のため、戻せません'),
      (404, 'すでに元の場所に戻されています'),
      (500, '戻せませんでした。もう一度お試しください'),
    ]) {
      testWidgets('復元が $status で失敗したら「$message」と出す', (tester) async {
        final it = _trashItem('dup.jpg');
        final api = _TrashApi()
          ..trashed.add(it)
          ..restoreFails[it.trashKey] = status;
        await tester.pumpWidget(_trashHost(_app(api)));
        await tester.pumpAndSettle();
        final listsBefore = api.trashListCalls;

        await tester.tap(find.widgetWithText(OutlinedButton, '復元'));
        await tester.pumpAndSettle();

        expect(api.restoreCalls, ['lib:${it.trashKey}']);
        expect(find.text(message), findsOneWidget);
        // 404 は一覧が古いだけなので読み直す。他は読み直さず行を残す
        expect(api.trashListCalls > listsBefore, status == 404);
      });
    }

    testWidgets('行の「復元」を押すとその1件だけ戻り、一覧から消える', (tester) async {
      final api = _TrashApi()
        ..trashed.addAll([_trashItem('a.jpg'), _trashItem('b.mp4')]);
      await tester.pumpWidget(_trashHost(_app(api)));
      await tester.pumpAndSettle();
      expect(find.byType(TrashRow), findsNWidgets(2));

      await tester.tap(find.bySemanticsLabel('a.jpgを復元'));
      await tester.pumpAndSettle();

      expect(api.restoreCalls, ['lib:${_trashItem('a.jpg').trashKey}']);
      expect(find.text('a.jpg'), findsNothing);
      expect(find.text('b.mp4'), findsOneWidget);
    });
  });

  // ゴミ箱は下タブではなく、アルバムタブの「その他」から開く（#167）
  Future<void> openTrashFromAlbums(WidgetTester tester) async {
    await tester.tap(find.descendant(
        of: find.byType(NavigationBar), matching: find.text('アルバム')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'ゴミ箱'));
    await tester.pumpAndSettle();
  }

  group('ゴミ箱はアルバムタブの子画面（#167）', () {
    testWidgets('「その他」のゴミ箱で開き、アルバムタブが点いたまま、戻るでアルバムへ帰る', (tester) async {
      final api = _TrashApi()..trashed.add(_trashItem('a.jpg'));
      await tester.pumpWidget(MaterialApp(home: HomeShell(app: _app(api), initialTab: HomeShell.photosTab)));
      await tester.pumpAndSettle();
      await openTrashFromAlbums(tester);

      expect(find.byType(TrashRow), findsOneWidget);
      expect(find.widgetWithText(AppBar, 'ゴミ箱'), findsOneWidget);
      expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 1);

      // 見出しの戻る
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('その他'), findsOneWidget);
      expect(find.byType(TrashRow), findsNothing);

      // 端末の戻るも同じくアルバムへ（アプリは閉じない）
      await openTrashFromAlbums(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('その他'), findsOneWidget);
      expect(find.byType(HomeShell), findsOneWidget);
    });

    testWidgets('アルバムの読み込みに失敗してもゴミ箱は開ける', (tester) async {
      final api = _FailingAlbumsApi()..trashed.add(_trashItem('a.jpg'));
      await tester.pumpWidget(MaterialApp(home: HomeShell(app: _app(api), initialTab: HomeShell.photosTab)));
      await tester.pumpAndSettle();
      await openTrashFromAlbums(tester);
      expect(find.byType(TrashRow), findsOneWidget);
    });
  });

  group('復元した写真を写真タブに戻す', () {
    Finder tab(String label) => find.descendant(
        of: find.byType(NavigationBar), matching: find.text(label));

    // 写真タブは IndexedStack で生き続けるので、知らせんと戻した写真がアプリを開き直すまで出ない
    testWidgets('ゴミ箱タブで1件戻すと、写真タブに戻った時にその写真が出る', (tester) async {
      final api = _TrashApi(files: [_img('a.jpg'), _img('b.jpg')])
        ..trashed.add(_trashItem('a.jpg'));
      await tester.pumpWidget(MaterialApp(home: HomeShell(app: _app(api), initialTab: HomeShell.photosTab)));
      await tester.pumpAndSettle();
      expect(find.byType(MediaTile), findsOneWidget);

      await openTrashFromAlbums(tester);
      await tester.tap(find.bySemanticsLabel('a.jpgを復元'));
      await tester.pumpAndSettle();
      await tester.tap(tab('写真'));
      await tester.pumpAndSettle();

      expect(find.byType(MediaTile), findsNWidgets(2));
    });

    testWidgets('まとめて戻した時も写真タブに出る', (tester) async {
      final api = _TrashApi(files: [_img('a.jpg'), _img('b.jpg')])
        ..trashed.addAll([_trashItem('a.jpg'), _trashItem('b.jpg')]);
      await tester.pumpWidget(MaterialApp(home: HomeShell(app: _app(api), initialTab: HomeShell.photosTab)));
      await tester.pumpAndSettle();
      expect(find.byType(MediaTile), findsNothing);

      await openTrashFromAlbums(tester);
      await tester.tap(find.text('a.jpg'));
      await tester.tap(find.text('b.jpg'));
      await tester.pump();
      await tester.tap(find.text('まとめて復元'));
      await tester.pumpAndSettle();
      await tester.tap(tab('写真'));
      await tester.pumpAndSettle();

      expect(find.byType(MediaTile), findsNWidgets(2));
    });
  });

  group('T3/S5 保持期間の案内', () {
    testWidgets('Worker が返した保持日数で自動削除までの日数を出す', (tester) async {
      final api = _TrashApi()
        ..retentionDays = 14
        ..trashed.add(_trashItem('a.jpg'));
      await tester.pumpWidget(_trashHost(_app(api)));
      await tester.pumpAndSettle();
      expect(
          find.text('ゴミ箱の項目は、移してから14日たつと自動で完全に削除されます。'
              'それまではいつでも元の場所に戻せます。'),
          findsOneWidget);
    });

    testWidgets('保持日数を返さない古い Worker では既定の30日を出す', (tester) async {
      final api = _TrashApi()..retentionDays = null;
      await tester.pumpWidget(_trashHost(_app(api)));
      await tester.pumpAndSettle();
      expect(find.textContaining('移してから30日たつと'), findsOneWidget);
    });
  });

  group('T4 ゴミ箱の行と状態表示', () {
    testWidgets('種類アイコンと「10月9日にゴミ箱へ · 3.1 MB」を出し、全ページ新しい順に並べる',
        (tester) async {
      final older = _trashItem('old.jpg',
          deletedAt: DateTime(2025, 3, 1).millisecondsSinceEpoch, size: 2048);
      final api = _TrashApi()
        ..trashed.addAll([older, _trashItem('clip.mp4')])
        ..nextCursor = 'p2';
      await tester.pumpWidget(_trashHost(_app(api)));
      await tester.pumpAndSettle();

      expect(find.text('10月9日にゴミ箱へ · 3.1 MB'), findsOneWidget);
      // 今年でない日付は年を付ける
      expect(find.text('2025年3月1日にゴミ箱へ · 2 KB'), findsOneWidget);
      expect(find.byIcon(Icons.videocam_outlined), findsOneWidget);
      expect(find.byIcon(Icons.image_outlined), findsOneWidget);
      final names = tester
          .widgetList<TrashRow>(find.byType(TrashRow))
          .map((r) => r.item.key)
          .toList();
      expect(names, ['clip.mp4', 'old.jpg']);
    });

    testWidgets('空なら説明を出し、引っ張ると読み直す', (tester) async {
      final api = _TrashApi();
      await tester.pumpWidget(_trashHost(_app(api)));
      await tester.pumpAndSettle();
      expect(find.text('ゴミ箱は空です'), findsOneWidget);
      expect(find.text('ゴミ箱に移した写真や動画がここに表示されます。'), findsOneWidget);

      api.trashed.add(_trashItem('new.jpg'));
      await tester.fling(find.text('ゴミ箱は空です'), const Offset(0, 400), 1000);
      await tester.pumpAndSettle();
      expect(find.text('new.jpg'), findsOneWidget);
    });

    testWidgets('一覧がある時に読み直しだけ失敗したら帯を出し、再試行で消える', (tester) async {
      final api = _TrashApi()..trashed.add(_trashItem('a.jpg'));
      await tester.pumpWidget(_trashHost(_app(api)));
      await tester.pumpAndSettle();

      api.failTrashList = true;
      await tester.fling(find.text('a.jpg'), const Offset(0, 400), 1000);
      await tester.pumpAndSettle();
      expect(find.text('最新の状態を読み込めませんでした'), findsOneWidget);
      // 古い一覧は消さずに残す
      expect(find.text('a.jpg'), findsOneWidget);

      api.failTrashList = false;
      await tester.tap(find.text('再試行'));
      await tester.pumpAndSettle();
      expect(find.text('最新の状態を読み込めませんでした'), findsNothing);
    });

    testWidgets('裏から戻ってきたら読み直し、写真タブで捨てた分を映す', (tester) async {
      final api = _TrashApi();
      final app = _app(api);
      Widget host(bool active) => MaterialApp(
          home: Scaffold(
              body: TrashTab(app: app, lib: 'lib', active: active, clock: _now)));
      await tester.pumpWidget(host(true));
      await tester.pumpAndSettle();
      await tester.pumpWidget(host(false));
      api.trashed.add(_trashItem('later.jpg'));
      await tester.pumpWidget(host(true));
      await tester.pumpAndSettle();
      expect(find.text('later.jpg'), findsOneWidget);
    });

    testWidgets('最初の読み込みに失敗したら理由と再試行を出す', (tester) async {
      final api = _TrashApi()..failTrashList = true;
      await tester.pumpWidget(_trashHost(_app(api)));
      await tester.pumpAndSettle();
      expect(find.text('読み込めませんでした'), findsOneWidget);
      api.failTrashList = false;
      await tester.tap(find.text('再試行'));
      await tester.pumpAndSettle();
      expect(find.text('ゴミ箱は空です'), findsOneWidget);
    });

    testWidgets('読み取り専用ライブラリでは聞きに行かず、復元ボタンも出さない', (tester) async {
      final api = _TrashApi()..trashed.add(_trashItem('a.jpg'));
      await tester.pumpWidget(_trashHost(_app(api, readOnly: true)));
      await tester.pumpAndSettle();
      expect(api.trashListCalls, 0);
      expect(find.text('読み取り専用のライブラリです'), findsOneWidget);
      expect(find.text('復元'), findsNothing);
    });

    testWidgets('行の部品は canRestore=false なら復元ボタンを出さない', (tester) async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: TrashRow(
                  item: _trashItem('a.jpg'),
                  now: _now(),
                  selected: false,
                  busy: false,
                  canRestore: false,
                  onRestore: () {}))));
      expect(find.text('a.jpg'), findsOneWidget);
      expect(find.text('復元'), findsNothing);
    });

    testWidgets('選択してまとめて復元できる', (tester) async {
      final api = _TrashApi()
        ..trashed.addAll([_trashItem('a.jpg'), _trashItem('b.jpg')]);
      await tester.pumpWidget(_trashHost(_app(api)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('a.jpg'));
      await tester.tap(find.text('b.jpg'));
      await tester.pump();
      expect(find.text('2件'), findsOneWidget);
      await tester.tap(find.text('まとめて復元'));
      await tester.pumpAndSettle();
      expect(api.restoreCalls, hasLength(2));
      expect(find.text('2件を復元しました'), findsOneWidget);
      expect(find.text('ゴミ箱は空です'), findsOneWidget);
    });
  });

  group('下端にジェスチャー帯がある端末', () {
    const inset = 48.0;

    // ジェスチャーナビの端末を真似て、下端に触れない帯を作る
    void withBottomInset(WidgetTester tester) {
      final dpr = tester.view.devicePixelRatio;
      tester.view.padding = FakeViewPadding(bottom: inset * dpr);
      tester.view.viewPadding = FakeViewPadding(bottom: inset * dpr);
      addTearDown(tester.view.reset);
    }

    Future<void> expectBarAboveInsetAndRestore(
        WidgetTester tester, _TrashApi api) async {
      await tester.tap(find.text('a.jpg'));
      await tester.tap(find.text('b.jpg'));
      await tester.pump();
      final screenBottom =
          tester.view.physicalSize.height / tester.view.devicePixelRatio;
      // 浮いているバー本体（角丸の Material）。中のボタンが持つ Material とは影の高さで見分ける
      final bar = find.ancestor(
          of: find.text('まとめて復元'),
          matching: find.byWidgetPredicate(
              (w) => w is Material && w.elevation == 8));
      expect(tester.getRect(bar).bottom,
          lessThanOrEqualTo(screenBottom - inset),
          reason: 'まとめて復元のバーが下端の帯に食い込んでいる');
      await tester.tap(find.text('まとめて復元'));
      await tester.pumpAndSettle();
      expect(api.restoreCalls, hasLength(2));
    }

    testWidgets('下タブの無い画面でも、まとめて復元のバーは帯の上に収まって押せる', (tester) async {
      withBottomInset(tester);
      final api = _TrashApi()
        ..trashed.addAll([_trashItem('a.jpg'), _trashItem('b.jpg')]);
      await tester.pumpWidget(_trashHost(_app(api)));
      await tester.pumpAndSettle();
      await expectBarAboveInsetAndRestore(tester, api);
    });

    testWidgets('アプリの画面（下タブあり）でも、まとめて復元のバーは帯の上に収まって押せる', (tester) async {
      withBottomInset(tester);
      final api = _TrashApi()
        ..trashed.addAll([_trashItem('a.jpg'), _trashItem('b.jpg')]);
      await tester.pumpWidget(MaterialApp(home: HomeShell(app: _app(api), initialTab: HomeShell.photosTab)));
      await tester.pumpAndSettle();
      await openTrashFromAlbums(tester);
      await expectBarAboveInsetAndRestore(tester, api);
    });
  });

  test('バイト数の表示は KMP 版と同じ丸め', () {
    expect(formatBytes(512), '512 B');
    expect(formatBytes(2048), '2 KB');
    expect(formatBytes(3250586), '3.1 MB');
    expect(formatBytes(1 << 30), '1.0 GB');
  });
}
