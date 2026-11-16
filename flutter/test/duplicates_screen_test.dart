import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/duplicates/duplicates_controller.dart';
import 'package:r2_gallery/src/duplicates/duplicates_screen.dart';
import 'package:r2_gallery/src/state/app_state.dart';
import 'package:r2_gallery/src/ui/settings_tab.dart';

const _mb = 1024 * 1024;

// サムネを持たせないのは、テストでネットのサムネを読みに行かせないため
MediaItem _it(String key, int createdAt) => MediaItem(
    key: key,
    type: 'image',
    url: 'https://w.example/m/$key',
    createdAt: createdAt,
    size: _mb,
    lib: 'lib');

/// Worker の重複まわりを手元の表で真似る。
class _DupApi extends ApiClient {
  _DupApi(this.pages);

  /// cursor ごとのページ。null が先頭。
  final Map<String?, DuplicatePage> pages;
  final List<int> scanPending = [];
  int scans = 0;
  int lists = 0;
  Completer<void>? scanGate;

  /// 何回目の計算から止めるか（途中の残りを画面で見るため）。
  int gateFrom = 1;
  final List<String> trashCalls = [];
  final List<String> restoreCalls = [];
  Completer<void>? trashGate;
  ApiError? trashError;
  ApiError? scanError;

  @override
  Future<DuplicateScan> duplicateScan(String libId) async {
    scans++;
    if (scans >= gateFrom) await scanGate?.future;
    final e = scanError;
    if (e != null) throw e;
    final p = scanPending.isEmpty ? 0 : scanPending.removeAt(0);
    return DuplicateScan(pending: p, hashed: 10, skipped: 2);
  }

  @override
  Future<DuplicatePage> duplicates(String libId,
      {String? cursor, int limit = 50}) async {
    lists++;
    return pages[cursor] ?? const DuplicatePage(groups: []);
  }

  @override
  Future<String> trashDuplicate(String libId, String key,
      {required String keep}) async {
    trashCalls.add('$key<-$keep');
    await trashGate?.future;
    final e = trashError;
    if (e != null) throw e;
    return '.trash/1/$key';
  }

  @override
  Future<String> restore(String libId, String trashKey) async {
    restoreCalls.add(trashKey);
    return trashKey;
  }
}

DuplicatePage _page(List<List<MediaItem>> groups, {String? cursor}) =>
    DuplicatePage(
      groups: [
        for (var i = 0; i < groups.length; i++)
          DuplicateGroup(sha256: 'h${groups[i].first.key}', size: _mb, items: groups[i]),
      ],
      cursor: cursor,
      total: groups.length,
      reclaimable: groups.fold(0, (a, g) => a + (g.length - 1) * _mb),
      skipped: 2,
    );

AppState _app(ApiClient api, {bool readOnly = false}) =>
    AppState(api: api, bakedEndpoint: '', bakedToken: '')
      ..connected = true
      ..libraries = [Library(id: 'lib', title: 'L', readOnly: readOnly)]
      ..activeLib = 'lib';

Future<void> _show(WidgetTester tester, AppState app) async {
  // 組を縦に並べても全部が画面に収まる高さにする（既定の 800x600 だと2組目が外へ出る）
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
      home: DuplicatesScreen(
          app: app, lib: 'lib', clock: () => DateTime(2026, 11, 15))));
  await tester.pump();
  await tester.pump();
}

final _twoGroups = _page([
  [_it('a/x.jpg', 1), _it('b/x.jpg', 2), _it('b/x (2).jpg', 3)],
  [_it('y.jpg', 1), _it('y copy.jpg', 2)],
]);

void main() {
  testWidgets('計算が終わるまで残りを見せ、終わったら組と空く容量を出す', (tester) async {
    final api = _DupApi({null: _twoGroups})
      ..scanPending.addAll([5, 2, 0])
      ..scanGate = Completer<void>();
    await _show(tester, _app(api));
    expect(find.text('確認中…'), findsOneWidget);
    api.scanGate!.complete();
    api.scanGate = null;
    await tester.pumpAndSettle();
    expect(api.scans, 3);
    expect(find.text('2組 · 3.0 MB 空けられます'), findsOneWidget);
    expect(find.text('大きすぎて確認できなかった物: 2 件'), findsOneWidget);
    // 最も古い物が「残す」で、そのほかに「ゴミ箱へ」が付く
    expect(find.text('残す'), findsNWidgets(2));
    expect(find.text('ゴミ箱へ'), findsNWidgets(3));
    // 同じ組でフォルダが違う時だけフォルダを出す
    expect(find.text('a'), findsOneWidget);
    expect(find.text('（一番上）'), findsNothing);
  });

  testWidgets('計算の途中の残りを出す', (tester) async {
    final gate = Completer<void>();
    final api = _DupApi({null: _twoGroups})
      ..scanPending.addAll([5, 0])
      ..scanGate = gate
      ..gateFrom = 2;
    await _show(tester, _app(api));
    expect(api.scans, 2);
    expect(find.text('確認中… あと 5 件'), findsOneWidget);
    gate.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('画面を離れたら計算の呼び出しを止める', (tester) async {
    final api = _DupApi({null: _twoGroups})
      ..scanPending.addAll([5, 4, 3, 2, 1, 0])
      ..scanGate = Completer<void>();
    await _show(tester, _app(api));
    expect(api.scans, 1);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    api.scanGate!.complete();
    await tester.pumpAndSettle();
    expect(api.scans, 1);
    expect(api.lists, 0);
  });

  testWidgets('古い Worker の 404 は未対応と出す', (tester) async {
    final api = _DupApi({})..scanError = const ApiError(404, 'x', code: 'not_found');
    await _show(tester, _app(api));
    await tester.pumpAndSettle();
    expect(find.text('この接続先はまだ重複の確認に対応していません'), findsOneWidget);
  });

  testWidgets('失敗したら再試行で読み直せる', (tester) async {
    final api = _DupApi({null: _twoGroups})..scanError = const ApiError(500, 'x');
    await _show(tester, _app(api));
    await tester.pumpAndSettle();
    expect(find.text('重複の確認を進められませんでした'), findsOneWidget);
    api.scanError = null;
    await tester.tap(find.text('再試行'));
    await tester.pumpAndSettle();
    expect(find.text('2組 · 3.0 MB 空けられます'), findsOneWidget);
  });

  testWidgets('重複が無ければそう出す', (tester) async {
    await _show(tester, _app(_DupApi({null: const DuplicatePage(groups: [])})));
    await tester.pumpAndSettle();
    expect(find.text('重複は見つかりませんでした'), findsOneWidget);
  });

  testWidgets('残す物を選び直すと、それまでの残す物が消せるようになる', (tester) async {
    final api = _DupApi({
      null: _page([
        [_it('y.jpg', 1), _it('y copy.jpg', 2)],
      ])
    });
    await _show(tester, _app(api));
    await tester.pumpAndSettle();
    await tester.tap(find.text('こちらを残す'));
    await tester.pump();
    await tester.tap(find.text('ゴミ箱へ'));
    await tester.pump();
    expect(api.trashCalls, ['y.jpg<-y copy.jpg']);
    await tester.pumpAndSettle(const Duration(seconds: 7));
  });

  testWidgets('すぐ一覧から外し、組が1件になれば組ごと消えて合計も減る', (tester) async {
    final api = _DupApi({null: _twoGroups})..trashGate = Completer<void>();
    final app = _app(api);
    final changed = <String>[];
    final sub = app.contentChanged.listen(changed.add);
    addTearDown(sub.cancel);
    await _show(tester, app);
    await tester.pumpAndSettle();
    await tester.tap(find.text('ゴミ箱へ').last);
    await tester.pump();
    expect(find.text('y copy.jpg'), findsNothing);
    expect(find.text('y.jpg'), findsNothing);
    expect(find.text('1組 · 2.0 MB 空けられます'), findsOneWidget);
    api.trashGate!.complete();
    await tester.pump();
    await tester.pump();
    expect(changed, ['lib']);
    expect(api.trashCalls, ['y copy.jpg<-y.jpg']);
    await tester.pumpAndSettle(const Duration(seconds: 7));
  });

  testWidgets('失敗したら元の場所へ戻して知らせる', (tester) async {
    final api = _DupApi({null: _twoGroups})
      ..trashGate = Completer<void>()
      ..trashError = const ApiError(500, 'boom');
    await _show(tester, _app(api));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ゴミ箱へ').first);
    await tester.pump();
    expect(find.text('b/x.jpg'), findsNothing);
    expect(find.text('x.jpg'), findsOneWidget);
    api.trashGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('x.jpg'), findsNWidgets(2));
    expect(find.text('2組 · 3.0 MB 空けられます'), findsOneWidget);
    expect(find.text('ゴミ箱へ移せませんでした'), findsOneWidget);
  });

  testWidgets('残す方が消えていたら知らせて一覧を読み直す', (tester) async {
    final api = _DupApi({null: _twoGroups})
      ..trashError = const ApiError(409, 'x', code: 'keeper_missing');
    await _show(tester, _app(api));
    await tester.pumpAndSettle();
    expect(api.lists, 1);
    await tester.tap(find.text('ゴミ箱へ').first);
    await tester.pumpAndSettle();
    expect(api.lists, 2);
    expect(find.text('残す方が見つかりませんでした。一覧を読み直します'), findsOneWidget);
  });

  testWidgets('読み取り専用のライブラリでは組だけ見せて消させない', (tester) async {
    await _show(tester, _app(_DupApi({null: _twoGroups}), readOnly: true));
    await tester.pumpAndSettle();
    expect(find.text('残す'), findsNWidgets(2));
    expect(find.text('ゴミ箱へ'), findsNothing);
    expect(find.text('こちらを残す'), findsNothing);
    expect(find.text('このライブラリは読み取り専用です'), findsOneWidget);
  });

  testWidgets('元に戻すと同じ組の同じ位置に戻る', (tester) async {
    final api = _DupApi({null: _twoGroups});
    await _show(tester, _app(api));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ゴミ箱へ').last);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('y copy.jpg'), findsNothing);
    await tester.tap(find.text('元に戻す'));
    await tester.pumpAndSettle();
    expect(api.restoreCalls, ['.trash/1/y copy.jpg']);
    expect(find.text('y copy.jpg'), findsOneWidget);
    expect(find.text('2組 · 3.0 MB 空けられます'), findsOneWidget);
  });

  testWidgets('末尾まで来たら続きのページを読む', (tester) async {
    final api = _DupApi({
      null: _page([
        [_it('y.jpg', 1), _it('y copy.jpg', 2)],
      ], cursor: 'c1'),
      'c1': _page([
        [_it('z.jpg', 1), _it('z copy.jpg', 2)],
      ]),
    });
    await _show(tester, _app(api));
    await tester.pumpAndSettle();
    expect(api.lists, 2);
    expect(find.text('z copy.jpg'), findsOneWidget);
  });

  testWidgets('設定タブから今のライブラリの重複の画面を開ける', (tester) async {
    final api = _DupApi({null: _twoGroups});
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: SettingsTab(app: _app(api)))));
    await tester.pump();
    await tester.tap(find.text('重複した写真・動画を探す'));
    await tester.pumpAndSettle();
    expect(find.byType(DuplicatesScreen), findsOneWidget);
    expect(find.text('2組 · 3.0 MB 空けられます'), findsOneWidget);
  });

  group('組の決まり', () {
    test('残す物と、組の最後の1件は消せない', () {
      final c = DuplicatesController(api: _DupApi({}), lib: 'lib');
      addTearDown(c.dispose);
      final g = DuplicateGroupView('h', 1, [_it('a.jpg', 1), _it('b.jpg', 2)]);
      expect(c.canTrash(g, g.items[0]), isFalse);
      expect(c.canTrash(g, g.items[1]), isTrue);
      final single = DuplicateGroupView('h', 1, [_it('a.jpg', 1)])
        ..keeper = 'other';
      expect(c.canTrash(single, single.items[0]), isFalse);
    });

    test('同じ組から2件消した後で1件目を戻しても、2件目は生き返らない', () async {
      final api = _DupApi({
        null: _page([
          [_it('a.jpg', 1), _it('b.jpg', 2), _it('c.jpg', 3)],
        ]),
      });
      final c = DuplicatesController(api: api, lib: 'lib');
      addTearDown(c.dispose);
      await c.reload();
      final g = c.groups.single;
      final rb = await c.trash(g, g.items[1]);
      final rc = await c.trash(g, g.items[1]);
      expect(c.groups, isEmpty);
      expect(rc.error, isNull);
      c.restore(rb.removed);
      expect(c.groups.single.items.map((i) => i.key), ['a.jpg', 'b.jpg']);
      expect(c.total, 1);
      expect(c.reclaimable, _mb);
    });
  });
}
