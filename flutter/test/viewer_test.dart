import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/api/review_meta.dart';
import 'package:r2_gallery/src/state/app_state.dart';
import 'package:r2_gallery/src/ui/viewer_screen.dart';
import 'package:r2_gallery/src/viewer/device_export.dart';
import 'package:r2_gallery/src/grid/day_label.dart';
import 'package:r2_gallery/src/viewer/viewer_format.dart';

import 'support/fake_video.dart';

class _Api extends ApiClient {
  final trashed = <String>[];
  final restored = <String>[];
  final created = <String>[];
  final added = <({String album, List<String> keys})>[];
  final downloads = <String>[];
  List<Album> albumList = const [];
  ReviewMeta? review;
  bool failTrash = false;
  bool failAdd = false;
  int restoreStatus = 0;

  /// このURLの取得は署名切れ（403）として失敗させる
  String? expiredUrl;
  List<MediaItem> folderItems = const [];

  /// キーごとの講評。無ければ [review] を返す
  Map<String, ReviewMeta> reviewByKey = {};
  Object? metaError;
  Completer<ReviewMeta?>? metaGate;
  int metaCalls = 0;
  final metaResponses = <Future<ReviewMeta?>>[];

  @override
  Future<ReviewMeta?> meta(String libId, String key) async {
    metaCalls++;
    if (metaResponses.isNotEmpty) return metaResponses.removeAt(0);
    final gate = metaGate;
    if (gate != null) return gate.future;
    final err = metaError;
    if (err != null) throw err;
    return reviewByKey[key] ?? review;
  }

  @override
  Future<List<Album>> albums(String libId) async => albumList;

  @override
  Future<String> albumCreate(String libId, String title) async {
    created.add(title);
    return 'new-album';
  }

  @override
  Future<void> albumAdd(String libId, String albumId, List<String> keys) async {
    if (failAdd) throw const ApiError(500, 'boom');
    added.add((album: albumId, keys: keys));
  }

  @override
  Future<String> trash(String libId, String key) async {
    if (failTrash) throw const ApiError(500, 'boom');
    trashed.add(key);
    return 'trash/$key';
  }

  @override
  Future<String> restore(String libId, String trashKey) async {
    if (restoreStatus != 0) throw ApiError(restoreStatus, 'x');
    restored.add(trashKey);
    return '';
  }

  @override
  Future<void> downloadToFile(String url, String path) async {
    downloads.add(url);
    if (url == expiredUrl) throw const ApiError(403, 'expired');
    await File(path).writeAsString('bytes-of-$url');
  }

  @override
  Future<FolderPage> folder(String libId,
          {String prefix = '', String? cursor, bool recursive = false}) async =>
      FolderPage(items: folderItems);
}

/// 原本を取りに行かず、すぐ「取れなかった」にするキャッシュ。
/// 実物はテストでは応答せず読み込み中の表示が回り続け、画面が落ち着かないため。
class _NoCache extends Fake implements BaseCacheManager {
  @override
  Stream<FileResponse> getFileStream(String url,
          {String? key, Map<String, String>? headers, bool withProgress = false}) =>
      Stream.error(Exception('no network in tests'));
}

class _Store implements MediaStoreBridge {
  final saved = <({String name, String mime, String body})>[];
  Future<void> Function()? onSave;
  @override
  bool get supported => true;
  @override
  Future<void> save(String path, String displayName, String mime) async {
    await onSave?.call();
    saved.add((name: displayName, mime: mime, body: await File(path).readAsString()));
  }
}

final _created = DateTime(DateTime.now().year, 10, 8, 18, 42).millisecondsSinceEpoch;

MediaItem _img(String key, {String? note, int? size}) => MediaItem(
      key: key,
      type: 'image',
      url: 'https://w.example/m/$key',
      note: note,
      createdAt: _created,
      size: size,
    );

/// オフライン保存の可否と積んだ中身だけを差し替える（転送キューや暗号化は #149 のテストが見る）。
class _TestApp extends AppState {
  _TestApp(ApiClient api) : super(api: api, bakedEndpoint: '', bakedToken: '');
  bool offlineOn = false;
  final saved = <String>[];
  @override
  bool get offlineSupported => offlineOn;
  @override
  bool isOffline(String lib, String key) => saved.contains('$lib:$key');
  @override
  Future<int> saveOffline(String fallbackLib, List<MediaItem> items) async {
    for (final i in items) {
      saved.add('${i.lib ?? fallbackLib}:${i.key}');
    }
    return items.length;
  }
}

_TestApp _app(_Api api, {bool readOnly = false, _Store? store}) {
  api.setConnection(const Connection('https://fixture.invalid', 'fixture-only'));
  final app = _TestApp(api);
  // 書き込みのガード（#145）は未接続だと止めるので、接続済みから始める
  app.connected = true;
  app.libraries = [Library(id: 'review', title: 'レビュー', readOnly: readOnly)];
  app.activeLib = 'review';
  app.deviceExporter = DeviceExporter(api: api, store: store ?? _Store());
  return app;
}

Future<void> _open(WidgetTester tester, AppState app, List<MediaItem> items,
    {VoidCallback? onChanged}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (c) => TextButton(
          onPressed: () => openViewer(c,
              app: app,
              lib: 'review',
              items: items,
              index: 0,
              onChanged: onChanged,
              imageCacheManager: _NoCache()),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('動画の初回再生では講評を先行取得せず、情報を開いた時に一度だけ取得する', (tester) async {
    final gate = Completer<ReviewMeta?>();
    final api = _Api()..metaGate = gate;
    final app = _app(api);
    final video = FakeVideo();
    await tester.pumpWidget(MaterialApp(home: ViewerScreen(app: app,
      lib: 'review', items: const [MediaItem(key: 'clip.mp4', type: 'video',
        url: 'https://fixture.invalid/clip.mp4')], videoFactory: (_) => video)));
    await tester.pump();
    expect(video.value.isPlaying, isTrue);
    expect(api.metaCalls, 0);
    await tester.tap(find.text('情報'));
    await tester.pumpAndSettle();
    expect(api.metaCalls, 1);
    expect(find.text('講評を確認中…'), findsOneWidget);
    gate.complete(const ReviewMeta(verdict: 'pass', round: 1, label: '動画'));
    await tester.pumpAndSettle();
    expect(find.text('動画 · pass · 1回目'), findsOneWidget);
    expect(video.value.isPlaying, isTrue);
    Navigator.of(tester.element(find.byType(ViewerInfoSheet))).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.text('情報'));
    await tester.pumpAndSettle();
    expect(api.metaCalls, 1);
    expect(video.plays, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
  });

  testWidgets('動画の講評取得エラーと再試行は再生器の初期化・再生をやり直さない', (tester) async {
    final api = _Api()..metaError = const ApiError(500, 'synthetic failure');
    final app = _app(api);
    final video = FakeVideo();
    var created = 0;
    await tester.pumpWidget(MaterialApp(home: ViewerScreen(app: app,
      lib: 'review', items: const [MediaItem(key: 'clip.mp4', type: 'video',
        url: 'https://fixture.invalid/clip.mp4')], videoFactory: (_) { created++; return video; })));
    await tester.pump();
    expect(api.metaCalls, 0);
    await tester.tap(find.text('情報'));
    await tester.pumpAndSettle();
    expect(find.text('講評を取得できませんでした'), findsOneWidget);
    api..metaError = null..review = const ReviewMeta(verdict: 'pass', round: 1, label: '回復');
    await tester.tap(find.text('再読み込み'));
    await tester.pumpAndSettle();
    expect(find.text('回復 · pass · 1回目'), findsOneWidget);
    expect(video.value.isPlaying, isTrue);
    expect(video.plays, 1);
    expect(created, 1);
    expect(api.metaCalls, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
  });

  testWidgets('動画のページ変更は古い講評を失効させ、次の動画も情報を開くまで取得しない', (tester) async {
    final old = Completer<ReviewMeta?>();
    final current = Completer<ReviewMeta?>();
    final api = _Api()..metaResponses.addAll([old.future, current.future]);
    final app = _app(api);
    final videos = <FakeVideo>[];
    await tester.pumpWidget(MaterialApp(home: ViewerScreen(app: app,
      lib: 'review', items: const [
        MediaItem(key: 'a.mp4', type: 'video', url: 'https://fixture.invalid/a.mp4'),
        MediaItem(key: 'b.mp4', type: 'video', url: 'https://fixture.invalid/b.mp4'),
      ], videoFactory: (_) { final video = FakeVideo(); videos.add(video); return video; })));
    await tester.pump();
    await tester.tap(find.text('情報'));
    await tester.pumpAndSettle();
    expect(api.metaCalls, 1);
    Navigator.of(tester.element(find.byType(ViewerInfoSheet))).pop();
    await tester.pumpAndSettle();
    await tester.drag(find.byType(PageView), const Offset(-700, 0));
    await tester.pumpAndSettle();
    expect(videos.first.disposed, isTrue);
    expect(videos.last.value.isPlaying, isTrue);
    expect(api.metaCalls, 1);
    await tester.tap(find.text('情報'));
    await tester.pumpAndSettle();
    expect(api.metaCalls, 2);
    old.complete(const ReviewMeta(verdict: 'pass', round: 1, label: '古い動画'));
    await tester.pump();
    expect(find.text('古い動画 · pass · 1回目'), findsNothing);
    expect(find.text('講評を確認中…'), findsOneWidget);
    current.complete(const ReviewMeta(verdict: 'pass', round: 1, label: '次の動画'));
    await tester.pumpAndSettle();
    expect(find.text('次の動画 · pass · 1回目'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
  });

  testWidgets('V3: 上バーに日時と「N件目」、写真のメモを出し、スワイプで次の件に変わる', (tester) async {
    final api = _Api();
    await _open(tester, _app(api), [
      _img('2026/a.jpg', note: '馬場で撮った'),
      _img('2026/b.jpg'),
    ]);
    expect(find.text(formatDateTime(_created, DateTime.now())), findsOneWidget);
    expect(find.textContaining('10月8日 '), findsOneWidget);
    expect(find.text('1件目 · a.jpg'), findsOneWidget);
    expect(find.text('馬場で撮った'), findsOneWidget);

    await tester.drag(find.byType(PageView), const Offset(-700, 0));
    await tester.pumpAndSettle();
    expect(find.text('2件目 · b.jpg'), findsOneWidget);
    expect(find.text('馬場で撮った'), findsNothing);

    // 画面をタップすると上下のバーが隠れる
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    expect(find.text('2件目 · b.jpg'), findsNothing);
  });

  testWidgets('P3/V1: 動画のページでは操作バーが隠れると上下バーも隠れ、隣の動画へ送ると前の動画を止める',
      (tester) async {
    final videos = <String, FakeVideo>{};
    final app = _app(_Api());
    MediaItem vid(String k) =>
        MediaItem(key: k, type: 'video', url: 'https://w.example/m/$k', createdAt: _created);
    await tester.pumpWidget(MaterialApp(
      home: ViewerScreen(
        imageCacheManager: _NoCache(),
        app: app,
        lib: 'review',
        items: [vid('a.mp4'), vid('b.mp4')],
        videoFactory: (url) => videos[url] = FakeVideo(),
      ),
    ));
    await tester.pump();
    final a = videos['https://w.example/m/a.mp4']!;
    expect(a.value.isPlaying, isTrue);
    expect(find.text('1件目 · a.mp4'), findsOneWidget);

    await tester.pump(const Duration(seconds: 4));
    expect(find.text('1件目 · a.mp4'), findsNothing);
    expect(find.text('ゴミ箱へ'), findsNothing);

    await tester.drag(find.byType(PageView), const Offset(-700, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final b = videos['https://w.example/m/b.mp4']!;
    // 離れたページの動画はコントローラごと捨てる（#141: 表示中のページだけが持つ）
    expect(a.disposed, isTrue);
    expect(b.value.isPlaying, isTrue);
    // 送った先の動画は操作を出しているので、上下バーも戻る
    expect(find.text('2件目 · b.mp4'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('V1: 外部書き出しを出さず、情報/アルバムへ/ゴミ箱へを保つ',
      (tester) async {
    await _open(tester, _app(_Api()), [_img('a.jpg')]);
    for (final l in ['情報', 'アルバムへ', 'ゴミ箱へ']) {
      expect(find.text(l), findsOneWidget, reason: l);
    }
    expect(find.text('オフライン保存'), findsNothing);
    expect(find.text('端末に保存'), findsNothing);
  });

  testWidgets('V1: オフライン保存の口を渡すとボタンが出て、保存後は「保存済み」になる', (tester) async {
    final app = _app(_Api());
    final saved = <String>{};
    await tester.pumpWidget(MaterialApp(
      home: ViewerScreen(
        imageCacheManager: _NoCache(),
        app: app,
        lib: 'review',
        items: [_img('a.jpg')],
        offline: OfflineHooks(
          isSaved: (l, it) => saved.contains(it.key),
          save: (l, it) async => saved.add(it.key),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('オフライン保存'));
    await tester.pumpAndSettle();
    expect(saved, {'a.jpg'});
    expect(find.text('保存済み'), findsOneWidget);
    expect(find.text('このアプリ内に保存しました'), findsOneWidget);
  });

  testWidgets('V1: 読み取り専用ライブラリではアルバムへ・ゴミ箱へを出さない', (tester) async {
    await _open(tester, _app(_Api(), readOnly: true), [_img('a.jpg')]);
    expect(find.text('情報'), findsOneWidget);
    expect(find.text('アルバムへ'), findsNothing);
    expect(find.text('ゴミ箱へ'), findsNothing);
  });

  testWidgets('V1: ゴミ箱へは確認なしで移し、閉じた先で「元に戻す」で戻せる', (tester) async {
    final api = _Api();
    var changed = 0;
    await _open(tester, _app(api), [_img('a.jpg')], onChanged: () => changed++);
    await tester.tap(find.text('ゴミ箱へ'));
    await tester.pumpAndSettle();

    expect(api.trashed, ['a.jpg']);
    expect(find.byType(ViewerScreen), findsNothing);
    expect(find.text('1件をゴミ箱に移しました'), findsOneWidget);
    expect(changed, 1);

    await tester.tap(find.text('元に戻す'));
    await tester.pumpAndSettle();
    expect(api.restored, ['trash/a.jpg']);
    expect(changed, 2);
  });

  testWidgets('V1: 元に戻す時に同名が元の場所にあれば、その旨を出す', (tester) async {
    final api = _Api()..restoreStatus = 409;
    await _open(tester, _app(api), [_img('a.jpg')]);
    await tester.tap(find.text('ゴミ箱へ'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('元に戻す'));
    await tester.pumpAndSettle();
    expect(find.text('同じ名前の項目が元の場所にあるため戻せませんでした'), findsOneWidget);
  });

  testWidgets('V1: ゴミ箱への移動に失敗したらビューワーに留まって知らせる', (tester) async {
    final api = _Api()..failTrash = true;
    await _open(tester, _app(api), [_img('a.jpg')]);
    await tester.tap(find.text('ゴミ箱へ'));
    await tester.pumpAndSettle();
    expect(find.byType(ViewerScreen), findsOneWidget);
    expect(find.text('ゴミ箱への移動に失敗しました'), findsOneWidget);
  });

  testWidgets('V2: 情報シートに種別・サイズ・追加日時・保存場所・メモ・講評を出す', (tester) async {
    final api = _Api()
      ..review = const ReviewMeta(
        verdict: 'pass',
        round: 2,
        label: '構図',
        directorScore: 8,
        directorComment: '光がよい',
        criteria: [ReviewCriterion(key: 'light', directorScore: 9, veto: true)],
      );
    await _open(tester, _app(api), [
      _img('2026/oct/a.jpg', note: '馬場で撮った', size: 1572864),
    ]);
    await tester.tap(find.text('情報'));
    await tester.pumpAndSettle();

    final sheet = find.byType(ViewerInfoSheet);
    Finder inSheet(String t) => find.descendant(of: sheet, matching: find.text(t));
    expect(inSheet('a.jpg'), findsOneWidget);
    expect(inSheet('1.5 MB'), findsOneWidget);
    expect(inSheet(formatDateTime(_created, DateTime.now())), findsOneWidget);
    expect(inSheet('追加日時'), findsOneWidget);
    expect(inSheet('レビュー / 2026/oct'), findsOneWidget);
    expect(inSheet('保存場所'), findsOneWidget);
    expect(inSheet('馬場で撮った'), findsOneWidget);
    expect(inSheet('構図 · pass · 2回目'), findsOneWidget);
    expect(inSheet('総合スコア: 8\n講評: 光がよい\n・light: 9（veto）'), findsOneWidget);
  });

  // #113: 講評が取れなかった時に黙って消さず、理由と取り直しの導線を出す
  testWidgets('V2: 講評を取れなかった時は理由と再読み込みを出し、押すと取り直して出す', (tester) async {
    final api = _Api()..metaError = const ApiError(500, 'd1 down');
    await _open(tester, _app(api), [_img('a.jpg')]);
    await tester.tap(find.text('情報'));
    await tester.pumpAndSettle();
    final sheet = find.byType(ViewerInfoSheet);
    Finder inSheet(String t) => find.descendant(of: sheet, matching: find.text(t));
    expect(inSheet('講評を取得できませんでした'), findsOneWidget);
    expect(inSheet('講評を確認中…'), findsNothing);
    final calls = api.metaCalls;

    api
      ..metaError = null
      ..review = const ReviewMeta(
          verdict: 'pass', round: 1, label: '構図', directorComment: '光がよい');
    await tester.tap(inSheet('再読み込み'));
    await tester.pumpAndSettle();
    expect(api.metaCalls, calls + 1);
    expect(inSheet('構図 · pass · 1回目'), findsOneWidget);
    expect(inSheet('講評: 光がよい'), findsOneWidget);
    expect(inSheet('講評を取得できませんでした'), findsNothing);
  });

  testWidgets('V2: 講評が届く前に情報を開いても、届いたらそのシートに出す', (tester) async {
    final gate = Completer<ReviewMeta?>();
    final api = _Api()..metaGate = gate;
    await _open(tester, _app(api), [_img('a.jpg')]);
    await tester.tap(find.text('情報'));
    await tester.pumpAndSettle();
    final sheet = find.byType(ViewerInfoSheet);
    Finder inSheet(String t) => find.descendant(of: sheet, matching: find.text(t));
    expect(inSheet('講評を確認中…'), findsOneWidget);

    gate.complete(const ReviewMeta(verdict: 'pass', round: 3, label: '構図'));
    await tester.pumpAndSettle();
    expect(inSheet('構図 · pass · 3回目'), findsOneWidget);
    expect(inSheet('講評を確認中…'), findsNothing);
  });

  testWidgets('V2: API の評価基準コメントと両方のスコアを情報シートに出す', (tester) async {
    final api = _Api()
      ..review = ReviewMeta.fromJson({
        'verdict': 'adopted',
        'round': 2,
        'label': 'fixture',
        'criteria': [
          {
            'key': 'light',
            'panelScore': 7,
            'directorScore': 9,
            'comment': '照明の境界を確認',
          },
          {'key': 'framing', 'comment': '余白を確認'},
          {'key': 'color', 'panelScore': 8, 'comment': null},
        ],
      });
    await _open(tester, _app(api), [_img('fixture.jpg')]);
    await tester.tap(find.text('情報'));
    await tester.pumpAndSettle();
    expect(find.textContaining('照明の境界を確認'), findsOneWidget);
    expect(find.textContaining('パネル: 7'), findsOneWidget);
    expect(find.textContaining('余白を確認'), findsOneWidget);
    expect(find.textContaining('・color: 8'), findsOneWidget);
    expect(find.textContaining('null'), findsNothing);
  });

  for (final staleFailure in [false, true]) {
    testWidgets('V2: A→B→A の後に古い${staleFailure ? '失敗' : '成功'}が届いても最新の講評を保つ', (
      tester,
    ) async {
      final oldA = Completer<ReviewMeta?>();
      final b = Completer<ReviewMeta?>();
      final newA = Completer<ReviewMeta?>();
      final api = _Api()
        ..metaResponses.addAll([oldA.future, b.future, newA.future]);
      await _open(tester, _app(api), [_img('a.jpg'), _img('b.jpg')]);
      await tester.drag(find.byType(PageView), const Offset(-700, 0));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(PageView), const Offset(700, 0));
      await tester.pumpAndSettle();
      expect(api.metaCalls, 3);
      await tester.tap(find.text('情報'));
      await tester.pumpAndSettle();
      newA.complete(const ReviewMeta(verdict: 'pass', round: 2, label: '最新A'));
      await tester.pumpAndSettle();
      expect(find.text('最新A · pass · 2回目'), findsOneWidget);
      b.complete(const ReviewMeta(verdict: 'pass', round: 1, label: '別作品B'));
      if (staleFailure) {
        oldA.completeError(const ApiError(503, 'stale response'));
      } else {
        oldA.complete(
          const ReviewMeta(verdict: 'pending', round: 1, label: '古いA'),
        );
      }
      await tester.pumpAndSettle();
      expect(find.text('最新A · pass · 2回目'), findsOneWidget);
      expect(find.textContaining('別作品B'), findsNothing);
      expect(find.textContaining('古いA'), findsNothing);
      expect(find.text('講評を取得できませんでした'), findsNothing);
    });
  }

  testWidgets('V2: 講評の無い件では空状態を出し、前の件の講評も混ざらない', (tester) async {
    final api = _Api()
      ..reviewByKey = {
        'a.jpg': const ReviewMeta(verdict: 'pass', round: 1, label: 'Aの講評'),
      };
    await _open(tester, _app(api), [_img('a.jpg'), _img('b.jpg')]);
    await tester.tap(find.text('情報'));
    await tester.pumpAndSettle();
    expect(find.text('Aの講評 · pass · 1回目'), findsOneWidget);
    Navigator.of(tester.element(find.byType(ViewerInfoSheet))).pop();
    await tester.pumpAndSettle();

    await tester.drag(find.byType(PageView), const Offset(-700, 0));
    await tester.pumpAndSettle();
    expect(find.text('2件目 · b.jpg'), findsOneWidget);
    await tester.tap(find.text('情報'));
    await tester.pumpAndSettle();
    final sheet = find.byType(ViewerInfoSheet);
    expect(find.descendant(of: sheet, matching: find.text('b.jpg')), findsOneWidget);
    expect(find.textContaining('Aの講評'), findsNothing);
    expect(find.text('講評を確認中…'), findsNothing);
    expect(find.text('講評を取得できませんでした'), findsNothing);
    expect(find.text('講評はありません'), findsOneWidget);
  });

  testWidgets('V4: 書き込めるアルバムだけを出し、選ぶと追加して知らせる', (tester) async {
    final api = _Api()
      ..albumList = const [
        Album(id: 'a1', title: '馬', count: 3, readOnly: false),
        Album(id: 'ro', title: '共有', count: 1, readOnly: true),
        Album(id: '__other__', title: 'その他', count: 9, readOnly: false),
      ];
    await _open(tester, _app(api), [_img('a.jpg')]);
    await tester.tap(find.text('アルバムへ'));
    await tester.pumpAndSettle();
    expect(find.text('アルバムに追加'), findsOneWidget);
    expect(find.text('馬（3）'), findsOneWidget);
    expect(find.text('共有（1）'), findsNothing);
    expect(find.text('その他（9）'), findsNothing);

    await tester.tap(find.text('馬（3）'));
    await tester.pumpAndSettle();
    expect(api.added.single.album, 'a1');
    expect(api.added.single.keys, ['a.jpg']);
    expect(find.text('アルバムに追加しました'), findsOneWidget);
  });

  testWidgets('V4: 新しいアルバム名を入れると作ってから追加する。失敗は知らせる', (tester) async {
    final api = _Api();
    await _open(tester, _app(api), [_img('a.jpg')]);
    await tester.tap(find.text('アルバムへ'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), ' 秋の馬場 ');
    await tester.pump();
    await tester.tap(find.text('作成して追加'));
    await tester.pumpAndSettle();
    expect(api.created, ['秋の馬場']);
    expect(api.added.single.album, 'new-album');

    api.failAdd = true;
    await tester.tap(find.text('アルバムへ'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'x');
    await tester.pump();
    await tester.tap(find.text('作成して追加'));
    await tester.pumpAndSettle();
    expect(find.text('アルバムへの追加に失敗しました'), findsOneWidget);
  });

  testWidgets('X1: 保存はアプリ内だけで、外部への書き出しを出さない', (tester) async {
    final api = _Api();
    final store = _Store();
    final app = _app(api, store: store)..offlineOn = true;
    await _open(tester, app, [_img('2026/a.jpg')]);
    expect(find.text('端末に保存'), findsNothing);
    expect(find.text('オフライン保存'), findsOneWidget);
    expect(store.saved, isEmpty);
    expect(api.downloads, isEmpty);
  });

  test('X1: 古い外部保存APIも画像/動画/その他をダウンロードせず拒否する', () async {
    final api = _Api();
    final store = _Store();
    final app = _app(api, store: store);
    for (final type in ['image', 'video', 'file']) {
      await expectLater(
        app.exportToDevice(MediaItem(key: '$type.bin', type: type,
            url: 'https://fixture.invalid/$type')),
        throwsA(isA<DeviceExportError>().having((e) => e.message, 'message',
            '外部への書き出しは利用できません。オフライン保存を使ってください')),
      );
    }
    expect(app.deviceExportSupported, isFalse);
    expect(api.downloads, isEmpty);
    expect(store.saved, isEmpty);
    expect(PlatformMediaStore().supported, isFalse);
    await expectLater(PlatformMediaStore().save('/never-read', 'x.jpg', 'image/jpeg'),
        throwsA(isA<DeviceExportError>()));
  });

  testWidgets('保存待ちは保存済みと区別し、暗号化保存の通知後だけ確定する', (tester) async {
    final changes = ChangeNotifier();
    addTearDown(changes.dispose);
    var saved = false;
    var pending = false;
    await tester.pumpWidget(MaterialApp(home: ViewerScreen(
      app: _app(_Api()), lib: 'review', items: [_img('a.jpg')],
      imageCacheManager: _NoCache(),
      offline: OfflineHooks(
        changes: changes,
        isSaved: (_, _) => saved,
        isPending: (_, _) => pending,
        save: (_, _) async { pending = true; changes.notifyListeners(); },
      ),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('オフライン保存'));
    await tester.pumpAndSettle();
    expect(find.text('保存待ち'), findsOneWidget);
    expect(find.text('保存済み'), findsNothing);
    saved = true;
    pending = false;
    changes.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('保存済み'), findsOneWidget);
    expect(find.text('保存待ち'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('保存済みからの個別削除は確認し、取り消しでは何も消さない', (tester) async {
    final changes = ChangeNotifier();
    addTearDown(changes.dispose);
    var saved = true;
    var removed = 0;
    await tester.pumpWidget(MaterialApp(home: ViewerScreen(
      app: _app(_Api()), lib: 'review', items: [_img('a.jpg')],
      imageCacheManager: _NoCache(),
      offline: OfflineHooks(
        changes: changes, isSaved: (_, _) => saved, save: (_, _) async {},
        remove: (_, _) async { removed++; saved = false; changes.notifyListeners(); },
      ),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存済み'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();
    expect(removed, 0);
    expect(saved, isTrue);
    await tester.tap(find.text('保存済み'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('削除'));
    await tester.pumpAndSettle();
    expect(removed, 1);
    expect(find.text('オフライン保存'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('開いたViewerの保存操作はアカウント切替後の同名作品に引き継がない', () async {
    final app = _app(_Api())..offlineOn = true;
    addTearDown(app.dispose);
    final item = _img('a.jpg');
    app.saved.add('review:a.jpg');
    final hooks = offlineHooksFor(app)!;
    expect(hooks.isSaved('review', item), isTrue);
    app.api.setConnection(const Connection('https://fixture.invalid', 'other-fixture'));
    expect(hooks.canUse!(), isFalse);
    expect(hooks.isSaved('review', item), isFalse);
    await expectLater(hooks.save('review', item), throwsA(isA<StateError>()));
    await expectLater(hooks.remove!('review', item), throwsA(isA<StateError>()));
    expect(app.saved, ['review:a.jpg']);
  });

  test('整形: サイズと MIME は KMP 版と同じ', () {
    expect(formatBytes(512), '512 B');
    expect(formatBytes(2048), '2 KB');
    expect(formatBytes(1572864), '1.5 MB');
    expect(formatBytes(3 * 1024 * 1024 * 1024 + 512 * 1024 * 1024), '3.5 GB');
    expect(mimeFor('a.MOV'), 'video/quicktime');
    expect(mimeFor('a.jpg?sig=1'), 'image/jpeg');
    expect(mimeFor('README'), 'application/octet-stream');
    expect(formatDateTime(DateTime(2001, 1, 2, 3, 4).millisecondsSinceEpoch, DateTime(2026)),
        '2001年1月2日 火曜日 03:04');
  });

  // 統合（#145 の書き込みガードをビューワーのゴミ箱にもつないだ）
  testWidgets('ガード: 書けないライブラリの項目はゴミ箱へ送らず、ビューワーに留まって理由を出す',
      (tester) async {
    final api = _Api();
    await _open(tester, _app(api), [
      MediaItem(
          key: 'x.jpg', type: 'image', url: 'https://w.example/m/x.jpg', lib: 'zz'),
    ]);
    await tester.tap(find.text('ゴミ箱へ'));
    await tester.pumpAndSettle();
    expect(api.trashed, isEmpty);
    expect(find.text('接続先にライブラリが見つかりません。接続先と権限を確認してください。'),
        findsOneWidget);
    expect(find.byType(ViewerScreen), findsOneWidget);
  });

  // 統合（#147 のビューワーの「オフライン」を #149 のオフライン保存につないだ）
  testWidgets('V1: 一覧から開いたビューワーの「オフライン」は #149 のオフライン保存に積む',
      (tester) async {
    final app = _app(_Api())..offlineOn = true;
    await _open(tester, app, [_img('a.jpg')]);
    await tester.tap(find.text('オフライン保存'));
    await tester.pumpAndSettle();
    expect(app.saved, ['review:a.jpg']);
    expect(find.text('保存済み'), findsOneWidget);
  });
}
