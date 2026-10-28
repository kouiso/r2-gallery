import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/state/app_state.dart';
import 'package:r2_gallery/src/ui/app_lock_layer.dart';
import 'package:r2_gallery/src/ui/video_levels.dart';
import 'package:r2_gallery/src/ui/video_view.dart';
import 'package:r2_gallery/src/viewer/player_system.dart';
import 'package:video_player/video_player.dart';

import 'support/fake_video.dart';

class _System implements PlayerSystem {
  double? vol = 0.5;
  double? bright;
  // 端末が明るさを自動調整中か（bright が null の理由）
  bool auto = false;
  final volumeSets = <double>[];
  final brightSets = <double>[];
  int resets = 0;

  @override
  Future<double?> volume() async => vol;
  @override
  Future<double?> setVolume(double v) async {
    volumeSets.add(v);
    return vol = v;
  }

  @override
  Future<double?> brightness() async => bright;
  @override
  Future<bool> brightnessAuto() async => auto;
  @override
  Future<double?> setBrightness(double v) async {
    brightSets.add(v);
    return bright = v;
  }

  @override
  Future<void> resetBrightness() async => resets++;
}

class _Rig {
  final videos = <FakeVideo>[];
  final system = _System();
  final controls = <bool>[];
  bool failFirst = false;

  VideoPlayerController make(String url) {
    final v = FakeVideo(failInit: failFirst && videos.isEmpty);
    videos.add(v);
    return v;
  }

  FakeVideo get video => videos.last;
}

Future<_Rig> _pump(WidgetTester tester,
    {bool failFirst = false, AppState? app}) async {
  final rig = _Rig()..failFirst = failFirst;
  Widget view = VideoView(
    url: 'https://w.example/m/a.mp4',
    controllerFactory: rig.make,
    system: rig.system,
    onControlsVisibleChange: rig.controls.add,
  );
  if (app != null) view = AppLockScope(app: app, child: view);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: view)));
  await tester.pump();
  return rig;
}

Future<void> _dispose(WidgetTester tester) =>
    tester.pumpWidget(const SizedBox.shrink());

void main() {
  testWidgets('P3: 再生中は操作バーを3.5秒で隠し、タップでまた出す', (tester) async {
    final rig = await _pump(tester);
    expect(rig.video.plays, 1);
    expect(find.byTooltip('一時停止'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 3400));
    expect(find.byTooltip('一時停止'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byTooltip('一時停止'), findsNothing);
    // ビューワー側の上下バーも追従させる
    expect(rig.controls.last, isFalse);

    await tester.tap(find.byKey(const ValueKey('video-gestures')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byTooltip('一時停止'), findsOneWidget);
    expect(rig.controls.last, isTrue);
    await _dispose(tester);
  });

  testWidgets('P3: 一時停止中は操作バーを隠さない', (tester) async {
    final rig = await _pump(tester);
    await tester.tap(find.byTooltip('一時停止'));
    await tester.pump();
    expect(rig.video.pauses, 1);
    await tester.pump(const Duration(seconds: 10));
    expect(find.byTooltip('再生'), findsWidgets);
    await _dispose(tester);
  });

  testWidgets('P2: ±10秒ボタンでその分だけ動く', (tester) async {
    final rig = await _pump(tester);
    await tester.tap(find.byTooltip('+10秒'));
    await tester.pump();
    expect(rig.video.seeks.last, const Duration(seconds: 30));
    await tester.tap(find.byTooltip('-10秒'));
    await tester.pump();
    expect(rig.video.seeks.last, const Duration(seconds: 20));
    await _dispose(tester);
  });

  testWidgets('P2: 操作ロック中はタップしても操作が出ず、解除で戻る', (tester) async {
    await _pump(tester);
    await tester.tap(find.byTooltip('ロック'));
    await tester.pump();
    expect(find.byTooltip('一時停止'), findsNothing);
    expect(find.byTooltip('解除'), findsOneWidget);

    await tester.tapAt(const Offset(400, 300));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byTooltip('一時停止'), findsNothing);

    await tester.tap(find.byTooltip('解除'));
    await tester.pump();
    expect(find.byTooltip('一時停止'), findsOneWidget);
    expect(find.byTooltip('解除'), findsNothing);
    await _dispose(tester);
  });

  testWidgets('P2: 一時停止中は中央に再生アイコン、読み込み中はスピナーを出す', (tester) async {
    final rig = await _pump(tester);
    expect(find.byKey(const ValueKey('video-center-play')), findsNothing);
    await rig.video.pause();
    await tester.pump();
    expect(find.byKey(const ValueKey('video-center-play')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('video-center-play')));
    await tester.pump();
    expect(rig.video.value.isPlaying, isTrue);

    rig.video.value = rig.video.value.copyWith(isBuffering: true);
    await tester.pump();
    expect(find.byKey(const ValueKey('video-buffering')), findsOneWidget);
    await _dispose(tester);
  });

  testWidgets('P2: 最後まで再生したらリプレイを出し、押すと頭から再生する', (tester) async {
    final rig = await _pump(tester);
    rig.video.value = rig.video.value.copyWith(
        isPlaying: false,
        isCompleted: true,
        position: const Duration(seconds: 60));
    await tester.pump();
    expect(find.text('再生が終了しました'), findsOneWidget);

    await tester.tap(find.text('再生が終了しました'));
    await tester.pump();
    expect(rig.video.seeks.last, Duration.zero);
    expect(rig.video.value.isPlaying, isTrue);
    expect(find.text('再生が終了しました'), findsNothing);
    await _dispose(tester);
  });

  testWidgets('P2: 開けなかったら「再生できませんでした」を出し、押すと読み直す', (tester) async {
    final rig = await _pump(tester, failFirst: true);
    expect(find.text('再生できませんでした'), findsOneWidget);
    expect(rig.videos, hasLength(1));

    await tester.tap(find.text('再生できませんでした'));
    await tester.pump();
    expect(rig.videos, hasLength(2));
    expect(find.text('再生できませんでした'), findsNothing);
    expect(rig.video.plays, 1);
    await _dispose(tester);
  });

  testWidgets('P1: 右半分の縦ドラッグで音量、左半分で明るさを変えて表示する', (tester) async {
    final rig = await _pump(tester);
    rig.system.bright = 0.6;
    // 右半分を上へ。起点は端末の音量 0.5
    final right = await tester.startGesture(const Offset(600, 400));
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await right.moveBy(const Offset(0, -30));
      await tester.pump();
    }
    expect(find.byKey(const ValueKey('volume-indicator')), findsOneWidget);
    expect(rig.system.volumeSets.last, greaterThan(0.5));
    expect(rig.system.brightSets, isEmpty);
    await right.up();
    await tester.pump();
    expect(find.byKey(const ValueKey('volume-indicator')), findsNothing);

    // 左半分を下へ。起点は端末の明るさ 0.6
    final left = await tester.startGesture(const Offset(200, 200));
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await left.moveBy(const Offset(0, 30));
      await tester.pump();
    }
    expect(find.byKey(const ValueKey('brightness-indicator')), findsOneWidget);
    expect(rig.system.brightSets.last, lessThan(0.6));
    await left.up();
    // ダブルタップ判定の待ち時間を流し切る
    await tester.pump(const Duration(seconds: 1));

    // 閉じたら端末の明るさに戻す
    await _dispose(tester);
    expect(rig.system.resets, 1);
  });
  testWidgets('#141: アプリがロックされたら再生を止める（PauseOnLock）', (tester) async {
    final app = AppState(bakedEndpoint: '', bakedToken: '')..hasPin = true;
    final rig = await _pump(tester, app: app);
    expect(rig.video.value.isPlaying, isTrue);
    expect(app.lockNow(), isTrue);
    await tester.pump();
    expect(rig.video.value.isPlaying, isFalse);
    await _dispose(tester);
  });

  group('#198: 明るさ・音量の操作', () {
    Future<void> drag(WidgetTester tester, Offset from, double dy,
        {int steps = 8}) async {
      final g = await tester.startGesture(from);
      await tester.pump();
      for (var i = 0; i < steps; i++) {
        await g.moveBy(Offset(0, dy / steps));
        await tester.pump();
      }
      await g.up();
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('端末任せの明るさでも、実際の値から動き出して固定値へ飛ばない', (tester) async {
      final rig = await _pump(tester);
      rig.system.bright = 0.2;
      await drag(tester, const Offset(200, 300), -120);
      expect(rig.system.brightSets, isNotEmpty);
      // 旧実装は 0.5 へ飛んでいた。0.2 から 1 回 0.05 以内ずつ上がる
      expect(rig.system.brightSets.first, lessThanOrEqualTo(0.25 + 1e-9));
      var prev = 0.2;
      for (final v in rig.system.brightSets) {
        expect((v - prev).abs(), lessThanOrEqualTo(0.05 + 1e-9));
        prev = v;
      }
      await _dispose(tester);
    });

    testWidgets('指が大きく飛んでも 1 回の更新で動く量には上限がある', (tester) async {
      final rig = await _pump(tester);
      rig.system.bright = 0.1;
      final g = await tester.startGesture(const Offset(200, 440));
      await tester.pump();
      for (var i = 0; i < 3; i++) {
        await g.moveBy(const Offset(0, -30));
        await tester.pump();
      }
      final before = rig.system.brightSets.length;
      final prev = rig.system.brightSets.isEmpty
          ? 0.1
          : rig.system.brightSets.last;
      await g.moveBy(const Offset(0, -320));
      await tester.pump();
      expect(rig.system.brightSets.length, greaterThan(before));
      expect(rig.system.brightSets.last - prev, lessThanOrEqualTo(0.05 + 1e-9));
      await g.up();
      await tester.pump(const Duration(seconds: 1));
      await _dispose(tester);
    });

    testWidgets('余裕の範囲の小さな動きでは値を変えない', (tester) async {
      final rig = await _pump(tester);
      rig.system.bright = 0.4;
      final g = await tester.startGesture(const Offset(200, 300));
      await tester.pump();
      // タップのずれ程度。縦ドラッグとして認識されても余裕の中なら書き込まない
      await g.moveBy(const Offset(0, -20));
      await tester.pump();
      await g.moveBy(const Offset(0, -8));
      await tester.pump();
      expect(rig.system.brightSets, isEmpty);
      await g.up();
      await tester.pump(const Duration(seconds: 1));
      await _dispose(tester);
    });

    testWidgets('明るさが読めない環境では動かさず、理由と代わりの手段を出す', (tester) async {
      final rig = await _pump(tester);
      rig.system.bright = null;
      await drag(tester, const Offset(200, 300), -150);
      expect(rig.system.brightSets, isEmpty);
      expect(find.byKey(const ValueKey('level-notice')), findsOneWidget);
      expect(find.textContaining('明るさを変えられません'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      expect(find.byKey(const ValueKey('level-notice')), findsNothing);
      await _dispose(tester);
    });

    testWidgets('指が大きく飛んだ後に戻すと、戻した次の更新から値が下がる', (tester) async {
      final rig = await _pump(tester);
      rig.system.bright = 0.1;
      final g = await tester.startGesture(const Offset(200, 440));
      await tester.pump();
      for (var i = 0; i < 3; i++) {
        await g.moveBy(const Offset(0, -30));
        await tester.pump();
      }
      // 上限で止められる大きな上向きの動き
      await g.moveBy(const Offset(0, -200));
      await tester.pump();
      final peak = rig.system.brightSets.last;
      // 指を下へ戻す。以前は止められた分が残り、しばらく上がり続けていた
      await g.moveBy(const Offset(0, 20));
      await tester.pump();
      expect(rig.system.brightSets.last, lessThan(peak));
      await g.up();
      await tester.pump(const Duration(seconds: 1));
      await _dispose(tester);
    });

    testWidgets('自動調整中で明るさを読めない時は、動かさず自動調整だと伝える', (tester) async {
      final rig = await _pump(tester);
      rig.system.bright = null;
      rig.system.auto = true;
      await drag(tester, const Offset(200, 300), -150);
      expect(rig.system.brightSets, isEmpty);
      expect(find.byKey(const ValueKey('level-notice')), findsOneWidget);
      expect(find.textContaining('自動調整'), findsOneWidget);
      expect(find.byKey(const ValueKey('brightness-indicator')), findsNothing);
      await tester.pump(const Duration(seconds: 4));
      await _dispose(tester);
    });

    testWidgets('自動調整中で読めない明るさのパネルは、値を出さず自動調整だと伝える', (tester) async {
      final rig = await _pump(tester);
      rig.system.bright = null;
      rig.system.auto = true;
      await tester.tap(find.byKey(const ValueKey('level-toggle')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('level-明るさ')), findsNothing);
      final msg = tester.widget<Text>(
          find.byKey(const ValueKey('level-明るさ-unavailable')));
      expect(msg.data, contains('自動調整'));
      await _dispose(tester);
    });

    testWidgets('端末の音量が読めない環境では、その動画の音量を動かす', (tester) async {
      final rig = await _pump(tester);
      rig.system.vol = null;
      // 動画の音量は初期値 1.0。下げる向きで動かす
      await drag(tester, const Offset(600, 300), 200);
      expect(rig.system.volumeSets, isEmpty);
      expect(rig.video.volumeSets, isNotEmpty);
      expect(rig.video.volumeSets.last, lessThan(1.0));
      await _dispose(tester);
    });

    testWidgets('触った時点で現在値と変更対象を出す', (tester) async {
      final rig = await _pump(tester);
      rig.system.bright = 0.37;
      final g = await tester.startGesture(const Offset(200, 300));
      await tester.pump();
      await g.moveBy(const Offset(0, -25));
      await tester.pump();
      await tester.pump();
      final badge = find.byKey(const ValueKey('brightness-indicator'));
      expect(badge, findsOneWidget);
      expect(find.descendant(of: badge, matching: find.text('明るさ')),
          findsOneWidget);
      expect(find.descendant(of: badge, matching: find.text('37%')),
          findsOneWidget);
      await g.up();
      await tester.pump(const Duration(seconds: 1));
      await _dispose(tester);
    });

    testWidgets('動かした後に起点へ戻した時は、戻した値を端末へ書く', (tester) async {
      final rig = await _pump(tester);
      rig.system.bright = 0.5;
      final g = await tester.startGesture(const Offset(200, 300));
      await tester.pump();
      // 1 回の上限に当たらないゆっくりした動き。上限で止められた分は捨てるので、速い動きでは指の位置と値は一致しない
      for (var i = 0; i < 8; i++) {
        await g.moveBy(const Offset(0, -10));
        await tester.pump();
      }
      expect(rig.system.brightSets.last, greaterThan(0.5));
      for (var i = 0; i < 8; i++) {
        await g.moveBy(const Offset(0, 10));
        await tester.pump();
      }
      expect(rig.system.brightSets.last, closeTo(0.5, 0.01));
      await g.up();
      await tester.pump(const Duration(seconds: 1));
      await _dispose(tester);
    });

    testWidgets('取り消し（ドラッグのキャンセル）では値も表示も残さない', (tester) async {
      final rig = await _pump(tester);
      rig.system.bright = 0.4;
      final g = await tester.startGesture(const Offset(200, 300));
      await tester.pump();
      await g.moveBy(const Offset(0, -25));
      await tester.pump();
      await g.cancel();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('brightness-indicator')), findsNothing);
      expect(rig.system.brightSets, isEmpty);
      await _dispose(tester);
    });

    testWidgets('ダブルタップのシークとタップの開閉は縦ドラッグと競合しない', (tester) async {
      final rig = await _pump(tester);
      await tester.tapAt(const Offset(600, 300));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(const Offset(600, 300));
      await tester.pump(const Duration(seconds: 1));
      expect(rig.video.seeks.last, const Duration(seconds: 30));
      expect(rig.system.volumeSets, isEmpty);
      expect(rig.system.brightSets, isEmpty);
      await _dispose(tester);
    });

    testWidgets('操作バーの「明るさ・音量」でスライダーが開き、実値を出す', (tester) async {
      final rig = await _pump(tester);
      rig.system.bright = 0.3;
      rig.system.vol = 0.6;
      await tester.tap(find.byKey(const ValueKey('level-toggle')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('level-panel')), findsOneWidget);
      expect(find.text('30%'), findsOneWidget);
      expect(find.text('60%'), findsOneWidget);
      expect(find.textContaining('画面の左側を上下になぞると明るさ'), findsOneWidget);

      final slider = tester.widget<Slider>(find.byKey(const ValueKey('level-明るさ')));
      slider.onChanged!(0.8);
      await tester.pump();
      expect(rig.system.brightSets.last, 0.8);
      await tester.pump(const Duration(seconds: 1));
      await _dispose(tester);
      expect(rig.system.resets, 1);
    });

    testWidgets('パネルを開いている間は操作バーを自動で隠さない', (tester) async {
      await _pump(tester);
      await tester.tap(find.byKey(const ValueKey('level-toggle')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 10));
      expect(find.byKey(const ValueKey('level-panel')), findsOneWidget);
      await _dispose(tester);
    });

    testWidgets('端末の音量ボタンなど外での変更にパネルが追従する', (tester) async {
      final rig = await _pump(tester);
      await tester.tap(find.byKey(const ValueKey('level-toggle')));
      await tester.pump();
      await tester.pump();
      expect(find.text('50%'), findsOneWidget);
      rig.system.vol = 0.9;
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(find.text('90%'), findsOneWidget);
      await _dispose(tester);
    });

    testWidgets('読めない値のスライダーは実値のように見せず、理由を出す', (tester) async {
      final rig = await _pump(tester);
      rig.system.bright = null;
      rig.system.vol = null;
      await tester.tap(find.byKey(const ValueKey('level-toggle')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('level-明るさ-unavailable')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('level-音量')), findsOneWidget,
          reason: '音量はこの動画の音量で代わりに動かせる');
      expect(find.byKey(const ValueKey('level-明るさ')), findsNothing);
      await _dispose(tester);
    });

    testWidgets('スライダーは読み上げ用の名前と値を持つ', (tester) async {
      final handle = tester.ensureSemantics();
      final rig = await _pump(tester);
      rig.system.bright = 0.3;
      await tester.tap(find.byKey(const ValueKey('level-toggle')));
      await tester.pump();
      await tester.pump();
      final values = tester.semantics
          .simulatedAccessibilityTraversal()
          .map((n) => n.value)
          .toList();
      expect(values, contains('明るさ 30%'));
      expect(find.byTooltip('明るさ・音量'), findsOneWidget);
      await _dispose(tester);
      handle.dispose();
    });

    testWidgets('画面の端に何を変える操作かの案内を出し、操作バーと一緒に消える', (tester) async {
      await _pump(tester);
      expect(find.byKey(const ValueKey('edge-hint-brightness')), findsOneWidget);
      expect(find.byKey(const ValueKey('edge-hint-volume')), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 3600));
      expect(find.byKey(const ValueKey('edge-hint-brightness')), findsNothing);
      await _dispose(tester);
    });

    test('画面の端の案内は、真っ白な動画の上でも文字のコントラスト比が 4.5 以上', () {
      double lin(int c) {
        final v = c / 255;
        return v <= 0.03928
            ? v / 12.92
            : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
      }

      double lum(int v) => lin(v);
      // 最悪は白い動画。背景は 白 x (1 - 不透明度) になる。
      final bg = (255 * (1 - kLevelHintScrim.a)).round();
      final fa = kLevelHintForeground.a;
      final fgOver = (255 * fa + bg * (1 - fa)).round();
      final l1 = lum(fgOver);
      final l2 = lum(bg);
      final ratio = (math.max(l1, l2) + 0.05) / (math.min(l1, l2) + 0.05);
      expect(ratio, greaterThanOrEqualTo(4.5));
    });

    testWidgets('背面へ回ると端末の明るさに戻し、前に戻ったら選んだ値を付け直す', (tester) async {
      final rig = await _pump(tester);
      rig.system.bright = 0.5;
      await drag(tester, const Offset(200, 300), -150);
      final chosen = rig.system.brightSets.last;
      final before = rig.system.resets;
      final writes = rig.system.brightSets.length;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(rig.system.resets, before + 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      // 付け直しの書き込みが 1 回増え、その値が選んだ値であること（増えなければ素通り）
      expect(rig.system.brightSets.length, writes + 1);
      expect(rig.system.brightSets.last, chosen);
      await _dispose(tester);
    });

    testWidgets('明るさを触っていなければ、背面へ回っても端末の設定を書き換えない', (tester) async {
      final rig = await _pump(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(rig.system.resets, 0);
      expect(rig.system.brightSets, isEmpty);
      await _dispose(tester);
    });

    testWidgets('操作ロック中は縦ドラッグでも値を変えない', (tester) async {
      final rig = await _pump(tester);
      await tester.tap(find.byTooltip('ロック'));
      await tester.pump();
      await drag(tester, const Offset(200, 300), -150);
      expect(rig.system.brightSets, isEmpty);
      await _dispose(tester);
    });
  });
}
