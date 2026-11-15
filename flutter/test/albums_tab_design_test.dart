import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/state/app_state.dart';
import 'package:r2_gallery/src/ui/albums_tab.dart';
import 'package:r2_gallery/src/ui/theme.dart';

// アルバムタブの見た目を、板「現行 · アルバムタブ」（doc/design/project/Albums.dc.html）の値で確かめる。
// 板の数値は 390x844 で getBoundingClientRect を取ったもの。

class _FakeApi extends ApiClient {
  List<Album> albumList = [];
  List<String> folders = [];
  final List<String> calls = [];

  @override
  Future<List<Album>> albums(String libId) async => albumList;

  @override
  Future<FolderPage> folder(String libId,
          {String prefix = '',
          String? cursor,
          bool recursive = false,
          String? sort}) async =>
      FolderPage(items: const [], folders: folders);

  @override
  Future<dynamic> sendJson(String method, String path,
      {Object? body, Map<String, dynamic>? query}) async {
    calls.add('$method $path');
    return {'ok': true};
  }
}

AppState _app(_FakeApi api, {bool readOnly = false}) {
  final app = AppState(api: api, bakedEndpoint: '', bakedToken: '');
  app.connected = true;
  app.libraries = [Library(id: 'a', title: 'A', readOnly: readOnly)];
  app.activeLib = 'a';
  return app;
}

const _shot = ValueKey('shot');

/// 板と同じ 390x844 の画面に、アプリのテーマでタブを置く
Future<void> _pump(WidgetTester t, Widget tab,
    {Size size = const Size(390, 844), double textScale = 1}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildAppTheme(),
    builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!),
    home: RepaintBoundary(key: _shot, child: Scaffold(body: tab)),
  ));
  await t.pumpAndSettle();
}

TextStyle _style(WidgetTester t, String text) =>
    t.renderObject<RenderParagraph>(find.text(text)).text.style!;

/// 画面を画像に取って、その画素の色を読む
Future<Color Function(int x, int y)> _pixels(WidgetTester t) async {
  late ByteData data;
  late int width;
  await t.runAsync(() async {
    final boundary = t.renderObject<RenderRepaintBoundary>(find.byKey(_shot));
    final image = await boundary.toImage();
    width = image.width;
    data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    image.dispose();
  });
  return (x, y) {
    final o = (y * width + x) * 4;
    return Color.fromARGB(data.getUint8(o + 3), data.getUint8(o),
        data.getUint8(o + 1), data.getUint8(o + 2));
  };
}

/// 色がほぼ同じか（縁のぼかしは別の色として数える）
bool _near(Color a, Color b) =>
    ((a.r - b.r).abs() + (a.g - b.g).abs() + (a.b - b.b).abs()) * 255 < 6;

/// 選択中の区切りの地は、画面の地に金を 20% 重ねた色
final _accentOnBg = Color.alphaBlend(AppColors.accentSoft, AppColors.bg);

Finder _cover(String title) => find.descendant(
    of: find.ancestor(
        of: find.text(title), matching: find.byType(GestureDetector)),
    matching: find.byType(ClipRRect));

void main() {
  group('アルバムのカード（板: 正方形のカバーの下に名前と件数）', () {
    testWidgets('名前と件数はカバーに重ねず、カバーの下に並べる', (t) async {
      final api = _FakeApi()
        ..albumList = [
          const Album(id: 'x', title: '家族', count: 128, readOnly: false),
        ];
      await _pump(t, AlbumsTab(app: _app(api), lib: 'a'));

      final cover = t.getRect(_cover('家族'));
      final title = t.getRect(find.text('家族'));
      final count = t.getRect(find.text('128 件'));
      // カバーは正方形で角丸 12
      expect(cover.width, moreOrLessEquals(173));
      expect(cover.height, moreOrLessEquals(173));
      expect(t.widget<ClipRRect>(_cover('家族')).borderRadius,
          BorderRadius.circular(12));
      // 名前はカバーの 6 下、件数は名前の 2 下。左端はカバーと同じ
      expect(title.top, moreOrLessEquals(cover.bottom + 6));
      expect(count.top, moreOrLessEquals(title.bottom + 2));
      expect(title.left, cover.left);
      expect(count.left, cover.left);

      final ts = _style(t, '家族');
      expect(ts.fontSize, 14);
      expect(ts.fontWeight, FontWeight.w600);
      expect(ts.color, AppColors.textPrimary);
      final cs = _style(t, '128 件');
      expect(cs.fontSize, 12);
      expect(cs.color, AppColors.textDim);
      // 行の箱は板を Noto Sans JP で描いた時と同じ 20 と 17。カード全体は 173+6+20+2+17
      expect(title.height, moreOrLessEquals(20));
      expect(count.height, moreOrLessEquals(17));
      expect(count.bottom - cover.top, moreOrLessEquals(218));
      // 代替フォントで行が伸びないよう、行の箱は固定する
      for (final text in ['家族', '128 件']) {
        expect(t.widget<Text>(find.text(text)).strutStyle?.forceStrutHeight,
            isTrue,
            reason: text);
      }
    });

    testWidgets('2 列・左右 16・すき間 12 で、次の段は件数の 12 下から始まる', (t) async {
      final api = _FakeApi()
        ..albumList = [
          for (final n in ['い', 'ろ', 'は'])
            Album(id: n, title: n, count: 1, readOnly: false),
        ];
      await _pump(t, AlbumsTab(app: _app(api), lib: 'a'));

      final create = t.getRect(find.ancestor(
          of: find.text('アルバム作成'), matching: find.byType(InkWell)));
      final a = t.getRect(_cover('い'));
      final b = t.getRect(_cover('ろ'));
      final c = t.getRect(_cover('は'));
      // 1 段目: 作成タイル（左）とアルバム（右）。作成タイルはカバーと同じ大きさ
      expect(create.left, 16);
      expect(create.size, const Size(173, 173));
      expect(a.left, moreOrLessEquals(create.right + 12));
      expect(a.right, moreOrLessEquals(390 - 16));
      expect(a.top, create.top);
      // 2 段目は 1 段目の件数の 12 下
      final firstRowBottom = t.getRect(find.text('1 件').first).bottom;
      expect(b.left, 16);
      expect(b.top, moreOrLessEquals(firstRowBottom + 12));
      expect(c.top, b.top);
    });

    testWidgets('幅の広い画面では列が増え、端数の段でもカバーの大きさは変わらない', (t) async {
      final api = _FakeApi()
        ..albumList = [
          for (var i = 0; i < 7; i++)
            Album(id: 'a$i', title: 'アルバム$i', count: i, readOnly: false),
        ];
      // 幅 1000 は 160 で割って 6 列。作成タイル + 7 件 = 8 個で、2 段目は 2 個だけ
      await _pump(t, AlbumsTab(app: _app(api), lib: 'a'),
          size: const Size(1000, 844));

      final first = t.getRect(_cover('アルバム0'));
      final fifth = t.getRect(_cover('アルバム4'));
      final sixth = t.getRect(_cover('アルバム5'));
      final last = t.getRect(_cover('アルバム6'));
      final side = (1000 - 32 - 12 * 5) / 6;
      expect(first.width, moreOrLessEquals(side));
      expect(first.height, moreOrLessEquals(side));
      expect(fifth.top, first.top);
      expect(fifth.right, moreOrLessEquals(1000 - 16));
      // 2 段目は左から詰め、1 段目と同じ大きさ
      expect(sixth.left, 16);
      expect(sixth.top, greaterThan(first.bottom));
      expect(sixth.size.width, moreOrLessEquals(side));
      expect(last.left, moreOrLessEquals(sixth.right + 12));
      expect(last.size.width, moreOrLessEquals(side));
    });

    testWidgets('文字を大きくする設定でも、はみ出さずに名前と件数が出る', (t) async {
      final api = _FakeApi()
        ..albumList = [
          const Album(
              id: 'x', title: 'とても長い名前のアルバムです', count: 12345, readOnly: false),
        ];
      await _pump(
          t, AlbumsTab(app: _app(api), lib: 'a', onOpenTrash: () {}),
          textScale: 2);

      // はみ出しがあればここで例外になる
      expect(t.takeException(), isNull);
      final cover = t.getRect(_cover('とても長い名前のアルバムです'));
      final title = t.getRect(find.text('とても長い名前のアルバムです'));
      final count = t.getRect(find.text('12345 件'));
      expect(title.top, moreOrLessEquals(cover.bottom + 6));
      expect(title.right, lessThanOrEqualTo(cover.right));
      expect(count.top, moreOrLessEquals(title.bottom + 2));
      await t.scrollUntilVisible(find.text('ゴミ箱'), 200);
      expect(find.text('ゴミ箱'), findsOneWidget);
    });

    testWidgets('名前の所を押しても開け、カバーの長押しでメニューが出る', (t) async {
      final api = _FakeApi()
        ..albumList = [
          const Album(id: 'x', title: '家族', count: 3, readOnly: false),
        ];
      final opened = <String>[];
      await _pump(
          t,
          AlbumsTab(
              app: _app(api),
              lib: 'a',
              onOpenAlbum: (a) async => opened.add(a.id)));

      await t.tap(find.text('家族'));
      await t.pumpAndSettle();
      await t.tap(find.text('3 件'));
      await t.pumpAndSettle();
      await t.tap(_cover('家族'));
      await t.pumpAndSettle();
      expect(opened, ['x', 'x', 'x']);

      await t.longPress(_cover('家族'));
      await t.pumpAndSettle();
      expect(find.text('名前を変更'), findsOneWidget);
      expect(find.text('削除'), findsOneWidget);
    });
  });

  group('アルバム／フォルダの切替（板: 選択中は金 20% の地に金の文字）', () {
    testWidgets('選択中は金 20% の地・金の太字・チェック 16、他は地なしの本文色', (t) async {
      await _pump(t, AlbumsTab(app: _app(_FakeApi()), lib: 'a'));

      final box = t.getRect(find.byType(SegmentedButton<AlbumsSegment>));
      final px = await _pixels(t);
      final midY = box.center.dy.round();
      // 左半分（選択中）の地は金 20%、右半分は画面の地のまま
      expect(_near(px(box.left.round() + 24, midY), _accentOnBg), isTrue,
          reason: '選択中の地: ${px(box.left.round() + 24, midY)}');
      expect(_near(px(box.right.round() - 24, midY), AppColors.bg), isTrue,
          reason: '選択していない側の地: ${px(box.right.round() - 24, midY)}');

      final on = _style(t, 'アルバム');
      expect(on.color, AppColors.accent);
      expect(on.fontSize, 14);
      expect(on.fontWeight, FontWeight.w600);
      final off = _style(t, 'フォルダ');
      expect(off.color, AppColors.textPrimary);
      expect(off.fontSize, 14);
      expect(off.fontWeight, FontWeight.w400);

      // チェックは選択中の側だけ。大きさ 16、文字との間 6
      final check = find.byIcon(Icons.check);
      expect(check, findsOneWidget);
      expect(t.getSize(check), const Size(16, 16));
      expect(t.getRect(find.text('アルバム')).left,
          moreOrLessEquals(t.getRect(check).right + 6));
      expect(
          t
              .renderObject<RenderParagraph>(find.descendant(
                  of: check, matching: find.byType(RichText)))
              .text
              .style!
              .color,
          AppColors.accent);
    });

    testWidgets('箱は高さ 42（枠 1px 込み）・角丸 20 で、押せる高さは 48', (t) async {
      await _pump(t, AlbumsTab(app: _app(_FakeApi()), lib: 'a'));

      final box = t.getRect(find.byType(SegmentedButton<AlbumsSegment>));
      // 左 16 から「＋」の 8 手前まで。「＋」は 48x48 で右端から 8
      final plus = t.getRect(find.widgetWithIcon(IconButton, Icons.add));
      expect(box.left, 16);
      expect(plus.size, const Size(48, 48));
      expect(plus.right, 390 - 8);
      expect(box.right, moreOrLessEquals(plus.left - 8));
      // 押せる高さは 48、描く箱はその中央の 42
      expect(box.height, 48);
      final px = await _pixels(t);
      final top = box.top.round() + 3;
      final bottom = box.bottom.round() - 4;
      // 選択していない側（右）と選択中の側（左）の両方で、枠が同じ高さにある
      for (final x in [box.left.round() + 60, box.right.round() - 40]) {
        expect(_near(px(x, top), AppColors.border), isTrue,
            reason: '上の枠線 x=$x: ${px(x, top)}');
        expect(_near(px(x, bottom), AppColors.border), isTrue,
            reason: '下の枠線 x=$x: ${px(x, bottom)}');
        expect(_near(px(x, top - 1), AppColors.bg), isTrue,
            reason: '枠の上 x=$x: ${px(x, top - 1)}');
        expect(_near(px(x, bottom + 1), AppColors.bg), isTrue,
            reason: '枠の下 x=$x: ${px(x, bottom + 1)}');
      }
      // 選択中の地は枠のすぐ内側まで塗る
      expect(_near(px(box.left.round() + 60, top + 1), _accentOnBg), isTrue);
      expect(_near(px(box.left.round() + 60, bottom - 1), _accentOnBg), isTrue);
      // 区切りの縦線は中央に 1 本（幅 1 が画素の境目に乗るので、2 画素に半分ずつ出る）
      final cx = box.center.dx.round();
      final cy = box.center.dy.round();
      final divider = [px(cx - 1, cy), px(cx, cy)];
      expect(
          divider.any((c) => !_near(c, _accentOnBg) && !_near(c, AppColors.bg)),
          isTrue,
          reason: '区切りの線: $divider');
      // 左上の角は丸いので、箱の角の画素は画面の地のまま
      expect(_near(px(box.left.round() + 1, top + 1), AppColors.bg), isTrue);
      final style = t
          .widget<SegmentedButton<AlbumsSegment>>(
              find.byType(SegmentedButton<AlbumsSegment>))
          .style!;
      expect(style.shape!.resolve({}),
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)));
    });

    testWidgets('フォルダへ切り替えると、選択の見た目も入れ替わる', (t) async {
      await _pump(t, AlbumsTab(app: _app(_FakeApi()), lib: 'a'));
      await t.tap(find.text('フォルダ'));
      await t.pumpAndSettle();

      expect(_style(t, 'フォルダ').color, AppColors.accent);
      expect(_style(t, 'フォルダ').fontWeight, FontWeight.w600);
      expect(_style(t, 'アルバム').color, AppColors.textPrimary);
      expect(_style(t, 'アルバム').fontWeight, FontWeight.w400);
      final box = t.getRect(find.byType(SegmentedButton<AlbumsSegment>));
      final px = await _pixels(t);
      final midY = box.center.dy.round();
      expect(_near(px(box.right.round() - 24, midY), _accentOnBg), isTrue);
      expect(_near(px(box.left.round() + 24, midY), AppColors.bg), isTrue);
    });
  });

  group('アルバムの作成タイル（板: 破線の枠・角丸 12・#14141D）', () {
    testWidgets('地は #14141D、枠は 1px の破線、アイコン 28・文字 14 は補足の色', (t) async {
      await _pump(t, AlbumsTab(app: _app(_FakeApi()), lib: 'a'));

      final tile = t.getRect(find.ancestor(
          of: find.text('アルバム作成'), matching: find.byType(InkWell)));
      final px = await _pixels(t);
      final left = tile.left.round();
      final top = tile.top.round();
      // 地の色
      expect(_near(px(left + 20, top + 20), AppColors.surface), isTrue,
          reason: '地: ${px(left + 20, top + 20)}');
      // 上の辺を角丸の内側だけなぞる。枠の色と地の色が交互に出れば破線
      var line = 0, gap = 0, switches = 0;
      bool? prev;
      for (var x = left + 16; x < tile.right.round() - 16; x++) {
        final c = px(x, top);
        final isLine = _near(c, AppColors.border);
        if (isLine) {
          line++;
        } else if (_near(c, AppColors.surface)) {
          gap++;
        }
        if (prev != null && prev != isLine) switches++;
        prev = isLine;
      }
      expect(line, greaterThan(40), reason: '枠の色の画素が上の辺に無い');
      expect(gap, greaterThan(20), reason: '破線の切れ目が無い（実線か枠なし）');
      // 141px の辺に、3 描いて 2 空ける刻み（約 28 回）
      expect(switches, greaterThan(40));
      // 枠の 1px 内側は地の色（枠の太さは 1px）
      expect(_near(px(left + 60, top + 1), AppColors.surface), isTrue);

      final plus = find.descendant(
          of: find.ancestor(
              of: find.text('アルバム作成'), matching: find.byType(InkWell)),
          matching: find.byIcon(Icons.add));
      expect(t.widget<Icon>(plus).size, 28);
      expect(t.widget<Icon>(plus).color, AppColors.textDim);
      final label = _style(t, 'アルバム作成');
      expect(label.fontSize, 14);
      expect(label.color, AppColors.textDim);
      // アイコンと文字の間は 8
      expect(t.getRect(find.text('アルバム作成')).top,
          moreOrLessEquals(t.getRect(plus).bottom + 8));
    });
  });

  group('「その他」とゴミ箱の行（板: 面に載せない行）', () {
    testWidgets('見出しは 13/600、行は端から端まで・最小 56 で、面（カード）に載せない', (t) async {
      final api = _FakeApi()
        ..albumList = [
          const Album(id: 'x', title: '家族', count: 2, readOnly: false),
        ];
      var opened = 0;
      await _pump(t,
          AlbumsTab(app: _app(api), lib: 'a', onOpenTrash: () => opened++));

      final head = _style(t, 'その他');
      expect(head.fontSize, 13);
      expect(head.fontWeight, FontWeight.w600);
      expect(head.color, AppColors.textDim);
      final headRect = t.getRect(find.text('その他'));
      // 上のグリッド（件数の文字）の 20 下、左 16
      expect(headRect.left, 16);
      expect(headRect.top,
          moreOrLessEquals(t.getRect(find.text('2 件')).bottom + 20));

      final row = t.getRect(find.widgetWithText(ListTile, 'ゴミ箱'));
      expect(row.left, 0);
      expect(row.right, 390);
      expect(row.top, moreOrLessEquals(headRect.bottom + 4));
      // 板を Noto Sans JP で描いた時の箱: 見出しの行 19、行は 10+24+17+10
      expect(headRect.height, moreOrLessEquals(19));
      expect(row.height, moreOrLessEquals(61));
      for (final text in ['その他', 'ゴミ箱', '移した項目の確認と復元']) {
        expect(t.widget<Text>(find.text(text)).strutStyle?.forceStrutHeight,
            isTrue,
            reason: text);
      }
      expect(
          t.widget<ListTile>(find.widgetWithText(ListTile, 'ゴミ箱')).minTileHeight,
          56);
      // 行の後ろは画面の地のまま（main は #1E1E2B の角丸の面だった）
      final px = await _pixels(t);
      expect(
          _near(px(8, row.center.dy.round()), AppColors.bg), isTrue,
          reason: '行の左端: ${px(8, row.center.dy.round())}');
      expect(
          _near(px(200, row.top.round() + 3), AppColors.bg), isTrue,
          reason: '行の地: ${px(200, row.top.round() + 3)}');

      // アイコン 24 は左 16、文字はその 16 右。山形は補足の色で右 16
      final bin = find.byIcon(Icons.delete_outline);
      final chevron = find.byIcon(Icons.chevron_right);
      expect(t.getRect(bin).left, 16);
      expect(t.getSize(bin), const Size(24, 24));
      expect(t.getRect(find.text('ゴミ箱')).left,
          moreOrLessEquals(t.getRect(bin).right + 16));
      expect(t.getRect(chevron).right, 390 - 16);
      expect(t.getSize(chevron), const Size(24, 24));
      expect(t.widget<Icon>(chevron).color, AppColors.textDim);
      expect(t.widget<Icon>(bin).color, AppColors.textPrimary);
      // 上下の余白は 10
      expect(t.getRect(find.text('ゴミ箱')).top, moreOrLessEquals(row.top + 10));
      expect(t.getRect(find.text('移した項目の確認と復元')).bottom,
          moreOrLessEquals(row.bottom - 10));

      expect(_style(t, 'ゴミ箱').fontSize, 16);
      expect(_style(t, 'ゴミ箱').color, AppColors.textPrimary);
      final sub = _style(t, '移した項目の確認と復元');
      expect(sub.fontSize, 12);
      expect(sub.color, AppColors.textDim);

      await t.tap(find.text('ゴミ箱'));
      await t.pumpAndSettle();
      expect(opened, 1);
    });
  });

  group('見た目を合わせた後も、できる事は減っていない', () {
    testWidgets('作成（タイルと＋）・開く・長押しメニュー・フォルダ・ゴミ箱の入口が全部押せる', (t) async {
      final api = _FakeApi()
        ..albumList = [
          const Album(id: 'x', title: '家族', count: 2, readOnly: false),
        ]
        ..folders = ['seed/'];
      final opened = <String>[];
      var trash = 0;
      await _pump(
          t,
          AlbumsTab(
            app: _app(api),
            lib: 'a',
            onOpenTrash: () => trash++,
            onOpenAlbum: (a) async => opened.add('album ${a.id}'),
            onOpenFolder: (p) async => opened.add('folder $p'),
          ));

      // アルバム側: 作成タイル・＋・開く・長押し
      await t.tap(find.text('アルバム作成'));
      await t.pumpAndSettle();
      expect(find.text('アルバムを作成'), findsOneWidget);
      await t.tap(find.text('キャンセル'));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('アルバムを作成'));
      await t.pumpAndSettle();
      expect(find.text('アルバムを作成'), findsOneWidget);
      await t.tap(find.text('キャンセル'));
      await t.pumpAndSettle();
      await t.tap(find.text('家族'));
      await t.pumpAndSettle();
      await t.longPress(find.text('家族'));
      await t.pumpAndSettle();
      expect(find.text('名前を変更'), findsOneWidget);
      expect(find.text('削除'), findsOneWidget);
      await t.tapAt(const Offset(195, 100));
      await t.pumpAndSettle();
      await t.tap(find.text('ゴミ箱'));
      await t.pumpAndSettle();

      // フォルダ側: 作成カード・＋・開く・ゴミ箱
      await t.tap(find.text('フォルダ'));
      await t.pumpAndSettle();
      await t.tap(find.text('フォルダ作成'));
      await t.pumpAndSettle();
      expect(find.text('フォルダを作成'), findsOneWidget);
      await t.tap(find.text('キャンセル'));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('フォルダを作成'));
      await t.pumpAndSettle();
      expect(find.text('フォルダを作成'), findsOneWidget);
      await t.tap(find.text('キャンセル'));
      await t.pumpAndSettle();
      await t.tap(find.text('seed'));
      await t.pumpAndSettle();
      await t.tap(find.text('ゴミ箱'));
      await t.pumpAndSettle();

      expect(opened, ['album x', 'folder seed/']);
      expect(trash, 2);
    });

    testWidgets('フォルダ側のカードは板が無いので今の形（正方形の面）のまま', (t) async {
      final api = _FakeApi()..folders = ['seed/'];
      await _pump(t, AlbumsTab(app: _app(api), lib: 'a'));
      await t.tap(find.text('フォルダ'));
      await t.pumpAndSettle();

      final create = t.getRect(find.ancestor(
          of: find.text('フォルダ作成'), matching: find.byType(InkWell)));
      final folder = t.getRect(
          find.ancestor(of: find.text('seed'), matching: find.byType(InkWell)));
      expect(create.size, const Size(173, 173));
      expect(folder.size, const Size(173, 173));
      expect(create.left, 16);
      expect(folder.left, moreOrLessEquals(create.right + 12));
      final px = await _pixels(t);
      expect(
          _near(px(create.left.round() + 20, create.top.round() + 20),
              AppColors.surfaceHigh),
          isTrue);
    });

    testWidgets('読み取り専用では作成の入口を出さず、切替は幅いっぱいになる', (t) async {
      final api = _FakeApi()
        ..albumList = [
          const Album(id: 'x', title: '家族', count: 2, readOnly: false),
        ];
      await _pump(
          t, AlbumsTab(app: _app(api, readOnly: true), lib: 'a'));
      expect(find.text('アルバム作成'), findsNothing);
      expect(find.byIcon(Icons.add), findsNothing);
      final box = t.getRect(find.byType(SegmentedButton<AlbumsSegment>));
      expect(box.left, 16);
      expect(box.right, 390 - 8);
      // 作成タイルが無い時は、アルバムが左上から並ぶ
      expect(t.getRect(_cover('家族')).left, 16);
    });
  });
}
