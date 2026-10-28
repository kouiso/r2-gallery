import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/state/app_state.dart';
import 'package:r2_gallery/src/ui/app_lock_layer.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/review_meta.dart';
import 'package:r2_gallery/src/ui/viewer_pages.dart';
import 'package:r2_gallery/src/ui/viewer_screen.dart';
import 'package:video_player/video_player.dart';

MediaItem _video(String key) =>
    MediaItem(key: key, type: 'video', url: 'https://w.example/m/$key');

MediaItem _image(String key) => MediaItem(
    key: key, type: 'image', url: 'https://w.example/m/$key?e=100&s=sig');

/// プラットフォームを使わずに、呼ばれた操作だけ記録する動画コントローラ。
class _FakeController extends VideoPlayerController {
  _FakeController(String url) : super.networkUrl(Uri.parse(url));

  final List<String> log = [];
  bool disposed = false;

  int get seeks => log.where((e) => e.startsWith('seek')).length;

  @override
  Future<void> initialize() async {
    value = value.copyWith(
      isInitialized: true,
      duration: const Duration(minutes: 1),
      size: const Size(16, 9),
    );
  }

  @override
  Future<void> play() async {
    log.add('play');
    value = value.copyWith(isPlaying: true);
  }

  @override
  Future<void> pause() async {
    log.add('pause');
    value = value.copyWith(isPlaying: false);
  }

  @override
  Future<void> seekTo(Duration position) async {
    log.add('seek:${position.inSeconds}');
    value = value.copyWith(position: position);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await super.dispose();
  }
}

/// initialize() の完了を外から止めておける動画コントローラ（読み込み中の挙動を作るため）。
class _GatedController extends _FakeController {
  _GatedController(super.url, this.gate);
  final Completer<void> gate;

  @override
  Future<void> initialize() async {
    await gate.future;
    await super.initialize();
  }
}

/// 一覧側が続きのページを読み込んだ状態を真似る。
class _Feed extends ChangeNotifier {
  _Feed(this.items);
  List<MediaItem> items;
  void load(List<MediaItem> next) {
    items = next;
    notifyListeners();
  }
}

class _Controllers {
  final List<_FakeController> made = [];
  _FakeController create(String url) {
    final c = _FakeController(url);
    made.add(c);
    return c;
  }

  Iterable<_FakeController> get alive => made.where((c) => !c.disposed);
}

Future<void> _pump(WidgetTester tester, Widget screen) async {
  await tester.pumpWidget(MaterialApp(home: screen));
  await tester.pump();
  await tester.pump();
}

Future<void> _swipeToNext(WidgetTester tester) async {
  await tester.fling(find.byType(PageView), const Offset(-500, 0), 2000);
  // 画像ページの読み込みスピナーは止まらないので pumpAndSettle は使えない
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _swipeToPrev(WidgetTester tester) async {
  await tester.fling(find.byType(PageView), const Offset(500, 0), 2000);
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// 画面中央で 2 本指を開く。拡大率は指を動かした量で決まる（スケールの認識が始まってからの比）。
Future<void> _pinchOut(WidgetTester tester) async {
  final c = tester.getCenter(find.byType(PageView));
  final g1 = await tester.startGesture(c - const Offset(20, 0), pointer: 1);
  final g2 = await tester.startGesture(c + const Offset(20, 0), pointer: 2);
  for (var i = 0; i < 10; i++) {
    await g1.moveBy(const Offset(-9, 0));
    await g2.moveBy(const Offset(9, 0));
    await tester.pump();
  }
  await g1.up();
  await g2.up();
  await tester.pump();
}

TransformationController _viewerController(WidgetTester tester) => tester
    .widget<InteractiveViewer>(find.byType(InteractiveViewer))
    .transformationController!;

Matrix4 _viewerMatrix(WidgetTester tester) => _viewerController(tester).value;

// #141（4d4d12d）で PlayerScreen に入れた動きを、一本化したビューワー（#147 の ViewerScreen）で確かめる

/// 講評を取りに行かない API（ビューワーはページに入るたびに meta を引く）。
class _NoMetaApi extends ApiClient {
  @override
  Future<ReviewMeta?> meta(String libId, String key) async => null;
}

ViewerScreen _viewer({
  required List<MediaItem> items,
  required int initialIndex,
  Listenable? source,
  List<MediaItem> Function()? readItems,
  VoidCallback? onNearEnd,
  VideoPlayerController Function(String url)? controllerFactory,
  AppState? app,
}) =>
    ViewerScreen(
      app: app ??
          AppState(
              api: _NoMetaApi(), bakedEndpoint: '', bakedToken: '', isWeb: false),
      lib: 'a',
      items: items,
      initialIndex: initialIndex,
      source: source,
      readItems: readItems,
      onNearEnd: onNearEnd,
      videoFactory: controllerFactory,
    );

/// ロック状態だけを外から切り替えられる AppState。
class _LockApp extends AppState {
  _LockApp()
      : super(
            api: _NoMetaApi(), bakedEndpoint: '', bakedToken: '', isWeb: false);
  void setLocked(bool v) {
    locked = v;
    notifyListeners();
  }
}

Future<void> _pumpLocked(WidgetTester tester, AppState app, Widget screen) async {
  await tester.pumpWidget(
      MaterialApp(home: AppLockScope(app: app, child: screen)));
  await tester.pump();
  await tester.pump();
}

void main() {
  group('スワイプで前後のメディアへ移る', () {
    testWidgets('開いたメディアから始まり、スワイプで次へ移る', (tester) async {
      final ctl = _Controllers();
      await _pump(
        tester,
        _viewer(
          items: [_video('a.mp4'), _video('b.mp4'), _video('c.mp4')],
          initialIndex: 1,
          controllerFactory: ctl.create,
        ),
      );
      expect(find.text('b.mp4'), findsOneWidget);

      await _swipeToNext(tester);
      expect(find.text('c.mp4'), findsOneWidget);
    });

    testWidgets('動画のコントローラは表示中のページの 1 本だけ（隣は先読みしない）', (tester) async {
      final ctl = _Controllers();
      await _pump(
        tester,
        _viewer(
          items: [_video('a.mp4'), _video('b.mp4'), _video('c.mp4')],
          initialIndex: 0,
          controllerFactory: ctl.create,
        ),
      );
      expect(ctl.made.length, 1);
      expect(ctl.alive.length, 1);

      await _swipeToNext(tester);
      // 次のページに移ったら前のコントローラは破棄され、生きているのは常に 1 本
      expect(ctl.made.length, 2);
      expect(ctl.alive.length, 1);
      expect(ctl.made.first.disposed, isTrue);

      await _swipeToNext(tester);
      expect(ctl.made.length, 3);
      expect(ctl.alive.length, 1);
    });

    testWidgets('スワイプの途中（半分未満）でも隣の動画は読み込まない', (tester) async {
      final ctl = _Controllers();
      await _pump(
        tester,
        _viewer(
          items: [_video('a.mp4'), _video('b.mp4')],
          initialIndex: 0,
          controllerFactory: ctl.create,
        ),
      );

      final gesture = await tester.startGesture(tester.getCenter(find.byType(PageView)));
      await gesture.moveBy(const Offset(-100, 0));
      await tester.pump();
      await tester.pump();
      // 隣のページは見え始めているが、まだ移っていないのでコントローラは作らない
      expect(ctl.made.length, 1);
      expect(ctl.alive.length, 1);

      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('画像のページへ移っても動画のコントローラは残らない', (tester) async {
      final ctl = _Controllers();
      await _pump(
        tester,
        _viewer(
          items: [_video('a.mp4'), _image('b.jpg')],
          initialIndex: 0,
          controllerFactory: ctl.create,
        ),
      );
      await _swipeToNext(tester);
      expect(ctl.alive, isEmpty);
    });
  });

  group('拡大した画像からのスワイプ', () {
    final images = [_image('a.jpg'), _image('b.jpg'), _image('c.jpg')];

    testWidgets('端に着く前は外へ流してもページは動かない', (tester) async {
      await _pump(tester, _viewer(items: images, initialIndex: 1));
      await _pinchOut(tester);

      // 中央から拡大した直後は、右端まで 400px より十分遠い（fling が画像のパンで消える距離）
      final m = _viewerMatrix(tester);
      final toRight = m.getTranslation().x - (800 - 800 * m.getMaxScaleOnAxis());
      expect(toRight, greaterThan(500));
      await tester.fling(find.byType(PageView), const Offset(-400, 0), 1500);
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('b.jpg'), findsOneWidget);
    });

    testWidgets('左端まで寄せたあと外へ引けば、1.01 倍超でも前の画像へ移る', (tester) async {
      await _pump(tester, _viewer(items: images, initialIndex: 1));
      await _pinchOut(tester);

      // 左端に着くまで引き、超えた分は半分に満たないので元のページへ戻る
      final toLeft = -_viewerMatrix(tester).getTranslation().x;
      await tester.drag(find.byType(PageView), Offset(toLeft + 100, 0));
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('b.jpg'), findsOneWidget);

      await _swipeToPrev(tester);
      expect(find.text('a.jpg'), findsOneWidget);
    });

    testWidgets('2 倍を超えて拡大したら原寸を重ね、等倍へ戻したら外す', (tester) async {
      await _pump(tester, _viewer(items: [images[0]], initialIndex: 0));
      expect(find.byType(CachedNetworkImage), findsOneWidget);

      await _pinchOut(tester);
      expect(_viewerMatrix(tester).getMaxScaleOnAxis(), greaterThan(2));
      final shown =
          tester.widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage));
      expect(shown.length, 2);
      expect(shown.first.memCacheWidth, isNotNull);
      expect(shown.last.memCacheWidth, isNull);

      // 等倍へ戻したらメモリを空けるため原寸は外れる
      _viewerController(tester).value = Matrix4.identity();
      await tester.pump();
      expect(find.byType(CachedNetworkImage), findsOneWidget);
    });
  });

  group('一覧の続きと対象外のメディア', () {
    testWidgets('開いた後に一覧が読み込んだ続きのページも、末尾に足されてスワイプできる', (tester) async {
      final ctl = _Controllers();
      final feed = _Feed([_video('a.mp4'), _video('b.mp4')]);
      var asked = 0;
      await _pump(
        tester,
        _viewer(
          items: feed.items,
          initialIndex: 0,
          source: feed,
          readItems: () => feed.items,
          onNearEnd: () => asked++,
          controllerFactory: ctl.create,
        ),
      );
      // 末尾の近くで開いたら続きを頼む
      expect(asked, greaterThan(0));

      feed.load([_video('a.mp4'), _video('b.mp4'), _video('c.mp4')]);
      await tester.pump();
      await _swipeToNext(tester);
      await _swipeToNext(tester);
      expect(find.text('c.mp4'), findsOneWidget);
    });

    testWidgets('一覧が先頭から取り直されても並びは崩れない', (tester) async {
      final ctl = _Controllers();
      final feed = _Feed([_video('a.mp4'), _video('b.mp4')]);
      await _pump(
        tester,
        _viewer(
          items: feed.items,
          initialIndex: 1,
          source: feed,
          readItems: () => feed.items,
          controllerFactory: ctl.create,
        ),
      );
      // 取り直しで先頭に新着が入っても、今の並びの後ろに混ざらない
      feed.load([_video('new.mp4'), _video('a.mp4'), _video('b.mp4')]);
      await tester.pump();
      await _swipeToNext(tester);
      expect(find.text('b.mp4'), findsOneWidget);
      await _swipeToPrev(tester);
      expect(find.text('a.mp4'), findsOneWidget);
    });

    testWidgets('画像と動画以外はスワイプの対象にしない', (tester) async {
      final ctl = _Controllers();
      await _pump(
        tester,
        _viewer(
          items: [
            _video('a.mp4'),
            const MediaItem(key: 'x.txt', type: 'file', url: 'https://w.example/m/x.txt'),
            _video('c.mp4'),
          ],
          initialIndex: 2,
          controllerFactory: ctl.create,
        ),
      );
      expect(find.text('c.mp4'), findsOneWidget);
      await _swipeToPrev(tester);
      expect(find.text('a.mp4'), findsOneWidget);
    });
  });

  group('動画のシーク', () {
    testWidgets('スライダーはドラッグ中に seek せず、離した時に 1 回だけ seek する', (tester) async {
      final ctl = _Controllers();
      await _pump(
        tester,
        _viewer(
          items: [_video('a.mp4')],
          initialIndex: 0,
          controllerFactory: ctl.create,
        ),
      );
      final c = ctl.made.single;

      final gesture = await tester.startGesture(tester.getCenter(find.byType(Slider)));
      for (var i = 0; i < 5; i++) {
        await gesture.moveBy(const Offset(30, 0));
        await tester.pump();
      }
      expect(c.seeks, 0);

      await gesture.up();
      await tester.pump();
      expect(c.seeks, 1);
    });
  });

  group('背面に回った時の再生', () {
    testWidgets('再生中なら止め、戻ったら再開する（inactive→paused と続いても再開できる）', (tester) async {
      final ctl = _Controllers();
      await _pump(
        tester,
        _viewer(
          items: [_video('a.mp4')],
          initialIndex: 0,
          controllerFactory: ctl.create,
        ),
      );
      final c = ctl.made.single;
      expect(c.value.isPlaying, isTrue);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      expect(c.value.isPlaying, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(c.value.isPlaying, isFalse);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(c.value.isPlaying, isTrue);
    });

    testWidgets('読み込み中に背面へ回ったら、読み終えても鳴らさず戻った時に再生する', (tester) async {
      final gate = Completer<void>();
      final made = <_GatedController>[];
      await _pump(
        tester,
        _viewer(
          items: [_video('a.mp4')],
          initialIndex: 0,
          controllerFactory: (url) {
            final c = _GatedController(url, gate);
            made.add(c);
            return c;
          },
        ),
      );
      final c = made.single;

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      gate.complete();
      await tester.pump();
      await tester.pump();
      expect(c.log, isNot(contains('play')));
      expect(c.value.isPlaying, isFalse);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(c.value.isPlaying, isTrue);
    });

    testWidgets('自分で止めていた動画は、戻っても勝手に再生しない', (tester) async {
      final ctl = _Controllers();
      await _pump(
        tester,
        _viewer(
          items: [_video('a.mp4')],
          initialIndex: 0,
          controllerFactory: ctl.create,
        ),
      );
      final c = ctl.made.single;
      await c.pause();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(c.value.isPlaying, isFalse);
    });
  });

  group('画像の表示', () {
    testWidgets('原本は専用キャッシュにパスだけのキーで入れ、decode 幅を画面に合わせる', (tester) async {
      tester.view.physicalSize = const Size(1000, 2000);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await _pump(
        tester,
        _viewer(items: [_image('a.jpg')], initialIndex: 0),
      );
      final img = tester.widget<CachedNetworkImage>(find.byType(CachedNetworkImage));
      expect(img.cacheManager, same(viewerCache));
      expect(img.cacheKey, 'https://w.example/m/a.jpg');
      // 画面は 500 論理px・倍率 2 なので、物理幅 1000px の 2 倍まで
      expect(img.memCacheWidth, 2000);
    });

    test('画面幅が取れない時は decode 幅を指定しない', () {
      expect(viewerDecodeWidth(400, 3), 2400);
      expect(viewerDecodeWidth(0, 3), isNull);
      expect(viewerDecodeWidth(400, 0), isNull);
      expect(viewerDecodeWidth(double.nan, 3), isNull);
      expect(viewerDecodeWidth(double.infinity, 3), isNull);
    });
  });

  // #141 のロック層と、スワイプ化で動画がページごとに分かれた後の組み合わせ
  group('ロック中の再生', () {
    testWidgets('ロックした瞬間に再生中の動画を止め、戻っても勝手に再開しない', (tester) async {
      final app = _LockApp();
      final ctl = _Controllers();
      await _pumpLocked(
        tester,
        app,
        _viewer(
            items: [_video('a.mp4')],
            initialIndex: 0,
            controllerFactory: ctl.create),
      );
      final c = ctl.made.single;
      expect(c.value.isPlaying, isTrue);

      app.setLocked(true);
      await tester.pump();
      expect(c.value.isPlaying, isFalse);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(c.value.isPlaying, isFalse);
    });

    testWidgets('ロック中に読み込みが終わった動画は鳴らさない', (tester) async {
      final app = _LockApp()..setLocked(true);
      final ctl = _Controllers();
      await _pumpLocked(
        tester,
        app,
        _viewer(
            items: [_video('a.mp4')],
            initialIndex: 0,
            controllerFactory: ctl.create),
      );
      final c = ctl.made.single;
      expect(c.value.isInitialized, isTrue);
      expect(c.log, isNot(contains('play')));
    });
  });
}
