import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/playback/playback_session.dart';
import 'package:r2_gallery/src/ui/theme.dart';
import 'package:r2_gallery/src/ui/video_view.dart';

import 'support/fake_playback.dart';
import 'support/fake_video.dart';

const _captureKey = ValueKey('mobile-playback-evidence');

Future<void> _capture(WidgetTester tester, String name) async {
  const dir = String.fromEnvironment('MOBILE_PLAYBACK_EVIDENCE_DIR');
  if (dir.isEmpty) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_captureKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('$dir/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  setUpAll(() async {
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    final japanese = FontLoader('R2GalleryJP');
    for (final weight in ['Regular', 'Bold']) {
      japanese.addFont(rootBundle.load('assets/fonts/R2GalleryJP-$weight.otf'));
    }
    await japanese.load();
  });

  for (final scale in [1.3, 2.0]) {
    testWidgets('日本語の再生方法・小窓・背景再生を同じ動画へ接続する $scale', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final port = FakePlaybackPort();
      final owner = PlaybackCoordinator(port);
      final video = FakeVideo();
      final chrome = <bool>[];
      await tester.pumpWidget(
        RepaintBoundary(
          key: _captureKey,
          child: MaterialApp(
            theme: buildAppTheme(),
            locale: AppTypography.locale,
            home: Scaffold(
              body: VideoView(
                url: 'https://fixture.invalid/private.mp4',
                controllerFactory: (_) => video,
                playbackCoordinator: owner,
                onControlsVisibleChange: chrome.add,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(video.value.isPlaying, isTrue);
      final session = owner.current!;
      expect(session.controller, same(video));
      await tester.tap(find.byTooltip('再生方法'));
      await tester.pumpAndSettle();
      expect(find.text('バックグラウンド再生'), findsOneWidget);
      expect(find.text('小窓で再生'), findsOneWidget);
      final title = tester.element(find.text('バックグラウンド再生'));
      expect(
        DefaultTextStyle.of(title).style.fontFamily,
        AppTypography.fontFamily,
      );
      expect(
        DefaultTextStyle.of(title).style.decoration,
        isNot(TextDecoration.underline),
      );
      await _capture(tester, 'playback-menu-$scale');
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(session.backgroundAllowed, isTrue);
      await tester.tap(find.text('小窓で再生'));
      await tester.pumpAndSettle();
      expect(port.pipRequests, 1);
      expect(session.pipPending, isTrue);
      expect(chrome.last, isFalse);
      session.pipChanged(true);
      await tester.pump();
      expect(find.byTooltip('再生方法'), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(video.value.isPlaying, isTrue);
      await session.seek(const Duration(seconds: 37));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      session.pipChanged(false);
      await tester.pump();
      await tester.pump();
      expect(video.value.position, const Duration(seconds: 37));
      expect(owner.current, same(session));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(video.disposed, isTrue);
      expect(port.bound, isNull);
      expect(port.focus, isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('非対応のOS操作を成功表示せず、基本再生を維持する', (tester) async {
    final port = FakePlaybackPort()..supported = false;
    final owner = PlaybackCoordinator(port);
    final video = FakeVideo();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: VideoView(
            url: 'https://fixture.invalid/a.mp4',
            controllerFactory: (_) => video,
            playbackCoordinator: owner,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byTooltip('再生方法'));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
    await tester.tap(find.text('小窓で再生'));
    await tester.pump();
    expect(port.pipRequests, 0);
    expect(video.value.isPlaying, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(video.disposed, isTrue);
  });

  testWidgets('非表示ページはdecoder所有権を奪わず、再表示で位置を保つ', (tester) async {
    final owner = PlaybackCoordinator(FakePlaybackPort());
    final videos = <FakeVideo>[];
    Future<void> host(bool active) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VideoView(
              url: 'https://fixture.invalid/a.mp4',
              active: active,
              playbackCoordinator: owner,
              controllerFactory: (_) {
                final video = FakeVideo();
                videos.add(video);
                return video;
              },
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    await host(false);
    expect(owner.current, isNull);
    expect(videos.single.value.isInitialized, isFalse);
    await host(true);
    await owner.current!.seek(const Duration(seconds: 31));
    await host(false);
    expect(videos.first.disposed, isTrue);
    expect(videos.last.value.isInitialized, isFalse);
    await host(true);
    expect(videos.last.value.isPlaying, isTrue);
    expect(videos.last.value.position, const Duration(seconds: 31));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
