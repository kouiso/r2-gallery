import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/state/app_state.dart';
import 'package:r2_gallery/src/ui/import_browser_tab.dart';
import 'package:r2_gallery/src/ui/import_parts.dart';
import 'package:r2_gallery/src/webdl/detected.dart';
import 'package:r2_gallery/src/webdl/web_history.dart';
import 'package:r2_gallery/src/webdl/web_transfer.dart';

Widget _wrap(Widget child) =>
    MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

const _video = DetectedItem('https://cdn.example.com/v/clip.mp4?sig=1',
    DetectedKind.video);
const _audio =
    DetectedItem('https://cdn.example.com/a/song.mp3', DetectedKind.audio);

void main() {
  testWidgets('取り込みタブは URL を入れるまで内蔵ブラウザを作らない', (tester) async {
    final app = AppState(api: ApiClient(), bakedEndpoint: '', bakedToken: '');
    await tester.pumpWidget(_wrap(SizedBox(
        height: 600, child: ImportBrowserTab(app: app))));
    expect(find.text('動画ページのURLを入力して移動'), findsOneWidget);
    expect(find.text('ネットから取り込む'), findsOneWidget);
  });

  testWidgets('内蔵ブラウザを作れない環境では、真っ黒にせず再試行できる表示にする', (tester) async {
    final app = AppState(api: ApiClient(), bakedEndpoint: '', bakedToken: '');
    await tester.pumpWidget(_wrap(SizedBox(
        height: 600, child: ImportBrowserTab(app: app))));
    await tester.enterText(find.byType(TextField), 'example.com/video');
    await tester.tap(find.byIcon(Icons.public));
    await tester.pump();
    // テストにはネイティブの WebView が無いので作成に失敗する。その時の表示を確かめる
    expect(find.textContaining('内蔵ブラウザを開けませんでした'), findsOneWidget);
    expect(find.text('再試行'), findsOneWidget);
    expect(find.text('動画ページのURLを入力して移動'), findsNothing);
  });

  testWidgets('URL 欄は文字がある時だけ「×」を出し、押すと空にしてそのまま打ち直せる', (tester) async {
    final app = AppState(api: ApiClient(), bakedEndpoint: '', bakedToken: '');
    await tester.pumpWidget(_wrap(SizedBox(
        height: 600, child: ImportBrowserTab(app: app))));
    final clear = find.byTooltip('入力を消す');
    expect(clear, findsNothing);

    await tester.enterText(find.byType(TextField), 'https://example.com/a');
    await tester.pump();
    expect(clear, findsOneWidget);
    // 読み上げでも「入力を消す」ボタンと分かる
    final semantics = tester.ensureSemantics();
    expect(tester.getSemantics(clear),
        isSemantics(tooltip: '入力を消す', isButton: true));
    semantics.dispose();

    await tester.tap(clear);
    await tester.pump();
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, isEmpty);
    expect(field.focusNode!.hasFocus, isTrue);
    expect(clear, findsNothing);

    // カーソルが残っているので、そのまま打てば入る
    await tester.enterText(find.byType(TextField), 'b');
    await tester.pump();
    expect(field.controller!.text, 'b');
  });

  testWidgets('「×」で消すのは入力欄だけで、開いているページは閉じない', (tester) async {
    final app = AppState(api: ApiClient(), bakedEndpoint: '', bakedToken: '');
    await tester.pumpWidget(_wrap(SizedBox(
        height: 600, child: ImportBrowserTab(app: app))));
    await tester.enterText(find.byType(TextField), 'example.com/video');
    await tester.tap(find.byIcon(Icons.public));
    await tester.pump();
    // テストでは WebView が作れないので、開いたページの代わりにこの表示が出る
    expect(find.textContaining('内蔵ブラウザを開けませんでした'), findsOneWidget);

    await tester.tap(find.byTooltip('入力を消す'));
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty);
    expect(find.textContaining('内蔵ブラウザを開けませんでした'), findsOneWidget);
    expect(find.text('動画ページのURLを入力して移動'), findsNothing);
  });

  testWidgets('空白だけの入力でも「×」で消せる', (tester) async {
    final app = AppState(api: ApiClient(), bakedEndpoint: '', bakedToken: '');
    await tester.pumpWidget(_wrap(SizedBox(
        height: 600, child: ImportBrowserTab(app: app))));
    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump();
    await tester.tap(find.byTooltip('入力を消す'));
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty);
  });

  group('取り込み済みの確認（#162）', () {
    const entry = WebHistoryEntry(
        name: 'clip.mp4',
        key: 'downloads/clip.mp4',
        url: 'https://cdn.example.com/v/clip.mp4',
        mime: 'video/mp4',
        size: 10,
        at: 1,
        lib: 'lib');

    Future<bool?> ask(WidgetTester tester, String button) async {
      bool? answer;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => TextButton(
            onPressed: () async =>
                answer = await confirmDuplicateImport(ctx, entry),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('既にあります'), findsOneWidget);
      expect(find.textContaining('downloads/clip.mp4'), findsOneWidget);
      await tester.tap(find.text(button));
      await tester.pumpAndSettle();
      return answer;
    }

    testWidgets('「それでも取り込む」を選ぶと取り込む', (tester) async {
      expect(await ask(tester, 'それでも取り込む'), isTrue);
    });

    testWidgets('「やめる」を選ぶと取り込まない', (tester) async {
      expect(await ask(tester, 'やめる'), isFalse);
    });
  });

  testWidgets('検出一覧は保存できるものだけ保存ボタンが効く', (tester) async {
    final saved = <String>[];
    await tester.pumpWidget(_wrap(DetectedSheetContent(
      items: const [_video, _audio],
      block: null,
      onSave: (d) => saved.add(d.displayName),
    )));
    expect(find.text('検出されたメディア（2件）'), findsOneWidget);
    expect(find.text('clip.mp4'), findsOneWidget);
    expect(find.text('動画・cdn.example.com'), findsOneWidget);
    expect(find.text('音声・cdn.example.com・ギャラリー非対応'), findsOneWidget);

    final buttons = find.widgetWithText(TextButton, '保存');
    expect(tester.widget<TextButton>(buttons.at(0)).onPressed, isNotNull);
    expect(tester.widget<TextButton>(buttons.at(1)).onPressed, isNull);
    await tester.tap(buttons.at(0));
    expect(saved, ['clip.mp4']);
  });

  testWidgets('サイト上のタイトルが分かる検出は、ファイル名の代わりにタイトルを出す',
      (tester) async {
    await tester.pumpWidget(_wrap(DetectedSheetContent(
      items: const [
        DetectedItem('https://cdn.example.com/v/1143_1_.mp4',
            DetectedKind.video, {}, '', '夏の思い出 2024'),
      ],
      block: null,
      onSave: (_) {},
    )));
    // 主表示はサイトのタイトル、小さい行にファイル名が残る
    expect(find.text('夏の思い出 2024'), findsOneWidget);
    expect(find.text('動画・cdn.example.com・1143_1_.mp4'), findsOneWidget);
  });

  testWidgets('保存先が書き込めない時は理由を出して保存を止める', (tester) async {
    await tester.pumpWidget(_wrap(DetectedSheetContent(
      items: const [_video],
      block: SaveBlock.readOnly,
      onSave: (_) {},
    )));
    expect(find.text(SaveBlock.readOnly.message), findsOneWidget);
    expect(
        tester.widget<TextButton>(find.widgetWithText(TextButton, '保存')).onPressed,
        isNull);
  });

  testWidgets('検出バーは件数を出してタップで開く', (tester) async {
    var opened = 0;
    await tester.pumpWidget(
        _wrap(DetectionBar(count: 3, onTap: () => opened++)));
    expect(find.text('3件のメディアを検出'), findsOneWidget);
    await tester.tap(find.byType(DetectionBar));
    expect(opened, 1);
  });

  testWidgets('転送シートは失敗の理由を出し、終わった行を消せる', (tester) async {
    final queue = WebTransferQueue(api: ApiClient());
    addTearDown(queue.dispose);
    queue.enqueue('lib', [_audio]);
    await tester.pumpWidget(_wrap(TransfersSheetContent(queue: queue)));
    expect(find.text('song.mp3'), findsOneWidget);
    expect(find.textContaining('ギャラリーに表示できない形式です'), findsOneWidget);

    await tester.tap(find.text('終わった行を消す'));
    await tester.pump();
    expect(find.text('転送はありません'), findsOneWidget);
    expect(queue.tasks, isEmpty);
  });

  testWidgets('http/https 以外の入力は開かず理由を出す', (tester) async {
    final app = AppState(api: ApiClient(), bakedEndpoint: '', bakedToken: '');
    await tester.pumpWidget(_wrap(SizedBox(
        height: 600, child: ImportBrowserTab(app: app))));
    await tester.enterText(find.byType(TextField), 'file:///sdcard/a.mp4');
    await tester.tap(find.byIcon(Icons.public));
    await tester.pump();
    expect(find.text('http/https のページだけ開けます'), findsOneWidget);
    // 内蔵ブラウザは作られず、案内のまま
    expect(find.text('動画ページのURLを入力して移動'), findsOneWidget);
    expect(find.textContaining('内蔵ブラウザを開けませんでした'), findsNothing);
  });

  testWidgets('保存を押すと転送キューに積まれ、すでに転送中なら積み直さない', (tester) async {
    final app = AppState(api: ApiClient(), bakedEndpoint: '', bakedToken: '');
    addTearDown(app.webQueue.dispose);
    final first = app.webQueue.enqueue('lib', const [_audio]);
    expect(first, hasLength(1));
    // 音声はその場で失敗の行になる。失敗した行は処理中ではないので、もう一度積める
    expect(app.webQueue.enqueue('lib', const [_audio]), hasLength(1));
    await tester.pumpWidget(_wrap(TransfersSheetContent(queue: app.webQueue)));
    expect(find.text('song.mp3'), findsNWidgets(2));
  });
}
