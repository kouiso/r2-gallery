import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/api/review_meta.dart';
import 'package:r2_gallery/src/state/app_state.dart';
import 'package:r2_gallery/src/ui/home_shell.dart';
import 'package:r2_gallery/src/ui/media_tile.dart';
import 'package:r2_gallery/src/ui/theme.dart';
import 'package:r2_gallery/src/ui/viewer_screen.dart';

import 'support/fake_video.dart';

const _captureKey = ValueKey('footer-evidence');
const _clip = MediaItem(
  key: 'clip.mp4',
  type: 'video',
  url: 'https://fixture.invalid/clip.mp4',
  size: 4,
);

class _Api extends ApiClient {
  @override
  Future<FolderPage> folder(String libId,
          {String prefix = '', String? cursor, bool recursive = false}) async =>
      const FolderPage(items: [_clip]);
  @override
  Future<ReviewMeta?> meta(String libId, String key) async => null;
}

/// 実際の Flutter ウィジェットだけを撮る。未実行時に画像を作ったり、別の画面で代用しない。
Future<void> _capture(WidgetTester tester, String name) async {
  const dir = String.fromEnvironment('FOOTER_EVIDENCE_DIR');
  if (dir.isEmpty) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(_captureKey));
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('No PNG bytes');
      final file = File('$dir/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  setUpAll(() async {
    final icons = FontLoader('MaterialIcons');
    icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    const font = String.fromEnvironment('FOOTER_EVIDENCE_FONT');
    const loadBundled = bool.fromEnvironment('FOOTER_EVIDENCE_LOAD_BUNDLED', defaultValue: true);
    if (font.isNotEmpty) {
      final loader = FontLoader('FooterEvidence');
      loader.addFont(File(font).readAsBytes().then((b) => ByteData.sublistView(b)));
      await loader.load();
    } else if (loadBundled) {
      final loader = FontLoader('R2GalleryJP');
      for (final weight in ['Regular', 'Bold']) {
        loader.addFont(rootBundle.load('assets/fonts/R2GalleryJP-$weight.otf'));
      }
      await loader.load();
    }
  });

  for (final scenario in [
    (name: 'narrow-1.3', size: const Size(320, 640), scale: 1.3,
      safe: const FakeViewPadding(top: 24, bottom: 34)),
    (name: 'narrow-2.0', size: const Size(320, 640), scale: 2.0,
      safe: const FakeViewPadding(top: 24, bottom: 34)),
    (name: 'landscape', size: const Size(640, 360), scale: 1.3,
      safe: const FakeViewPadding(left: 44, right: 44, bottom: 21)),
  ]) {
    testWidgets('一覧→動画→情報→ロック解除→元一覧 ${scenario.name}', (tester) async {
      tester.view.physicalSize = scenario.size;
      tester.view.devicePixelRatio = 1;
      tester.view.padding = scenario.safe;
      tester.platformDispatcher.textScaleFactorTestValue = scenario.scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final api = _Api();
      final app = AppState(api: api, bakedEndpoint: '', bakedToken: '')
        ..connected = true
        ..libraries = const [Library(id: 'lib', title: '合成fixture')]
        ..activeLib = 'lib';
      addTearDown(() {
        app.transfers.dispose();
        app.webQueue.dispose();
        app.dispose();
      });
      const font = String.fromEnvironment('FOOTER_EVIDENCE_FONT');
      await tester.pumpWidget(RepaintBoundary(
        key: _captureKey,
        child: MaterialApp(
          theme: buildAppTheme().copyWith(
            textTheme: font.isEmpty ? null : buildAppTheme().textTheme.apply(
              fontFamily: 'FooterEvidence'),
          ),
          home: HomeShell(app: app, initialTab: HomeShell.photosTab),
        ),
      ));
      await tester.pumpAndSettle();
      final before = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(before.selectedIndex, HomeShell.photosTab);
      expect(before.destinations.map((d) => (d as NavigationDestination).label),
          ['写真', 'アルバム', '取り込み', '設定']);
      await _capture(tester, '${scenario.name}-01-list');

      // 一覧の本物の Navigator へ同じ openViewer 経路で積み、動画デコーダーだけ合成代役にする。
      final video = FakeVideo();
      final route = openViewer(tester.element(find.byType(MediaTile)),
        app: app, lib: 'lib', items: const [_clip], index: 0,
        videoFactory: (_) => video,
        offline: OfflineHooks(isSaved: (_, _) => false, save: (_, _) async {}));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsNothing);
      await _capture(tester, '${scenario.name}-02-video');
      final hasBackLabel = find.byTooltip('一覧に戻る').evaluate().isNotEmpty;
      final footer = find.byKey(const ValueKey('viewer-actions'));
      final controls = find.byKey(const ValueKey('video-controls'));
      final footerRect = footer.evaluate().isEmpty ? null : tester.getRect(footer);
      final controlsRect = controls.evaluate().isEmpty ? null : tester.getRect(controls);
      final labels = ['情報', 'オフライン保存', 'アルバムへ', 'ゴミ箱へ'];
      final externalAbsent = find.text('端末に保存').evaluate().isEmpty;
      final buttons = <String, Rect>{};
      for (final label in labels) {
        final button = find.byTooltip(label);
        if (button.evaluate().isNotEmpty) buttons[label] = tester.getRect(button);
      }
      final clippedLabels = [
        for (final label in labels)
          if (find.text(label).evaluate().isNotEmpty &&
              tester.renderObject<RenderParagraph>(find.text(label)).didExceedMaxLines)
            label,
      ];
      final labelStyles = [
        for (final label in labels)
          tester.renderObject<RenderParagraph>(find.text(label)).text.style!,
      ];
      await tester.tap(find.byTooltip('+10秒'));
      await tester.pump();
      expect(video.seeks.last, const Duration(seconds: 30));
      await tester.tap(find.byTooltip('一時停止'));
      await tester.pump();
      expect(video.value.isPlaying, isFalse);

      // 明るさ・音量の入口は main の #198 の操作バーのアイコン（key: level-toggle）
      final adjustments = find.byKey(const ValueKey('level-toggle'));
      final hasAdjustments = adjustments.evaluate().isNotEmpty;
      if (hasAdjustments) {
        expect(adjustments.hitTestable(), findsOneWidget);
        await tester.tap(adjustments);
        await tester.pump();
        await _capture(tester, '${scenario.name}-03-adjustments');
        await tester.tap(adjustments);
        await tester.pump();
      }
      await tester.tap(find.byTooltip('ロック'));
      await tester.pump();
      await _capture(tester, '${scenario.name}-04-locked');
      final unlock = find.byTooltip('解除');
      final unlockRect = tester.getRect(unlock);
      final unlockTappable = unlock.hitTestable().evaluate().isNotEmpty;
      await tester.tap(unlock);
      await tester.pump();
      expect(video.value.isPlaying, isFalse);
      expect(video.value.position, const Duration(seconds: 30));
      await tester.tap(find.text('情報'));
      await tester.pumpAndSettle();
      expect(find.byType(ViewerInfoSheet), findsOneWidget);
      await _capture(tester, '${scenario.name}-05-info');
      Navigator.of(tester.element(find.byType(ViewerInfoSheet))).pop();
      await tester.pumpAndSettle();
      final back = find.byIcon(Icons.arrow_back);
      expect(back.hitTestable(), findsOneWidget);
      await tester.tap(back);
      await tester.pumpAndSettle();
      await route;
      expect(video.disposed, isTrue);
      expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
          HomeShell.photosTab);
      expect(find.byType(MediaTile), findsOneWidget);
      await _capture(tester, '${scenario.name}-06-return');

      // 同じ harness を基点で動かした時にも前後比較用の画像を撮り終えてから差分を検出する。
      expect(hasBackLabel, isTrue);
      expect(hasAdjustments, isTrue);
      expect(externalAbsent, isTrue);
      expect(clippedLabels, isEmpty);
      expect(buttons.keys, unorderedEquals(labels));
      for (final rect in [...buttons.values, unlockRect]) {
        expect(rect.width, greaterThanOrEqualTo(48));
        expect(rect.height, greaterThanOrEqualTo(48));
        expect(rect.left, greaterThanOrEqualTo(scenario.safe.left));
        expect(rect.right, lessThanOrEqualTo(scenario.size.width - scenario.safe.right));
        expect(rect.bottom, lessThanOrEqualTo(scenario.size.height - scenario.safe.bottom));
      }
      expect(unlockTappable, isTrue);
      expect(footerRect, isNotNull);
      expect(controlsRect, isNotNull);
      expect(controlsRect!.bottom, closeTo(footerRect!.top, 0.1));
      for (final style in labelStyles) {
        expect(style.fontFamily, font.isEmpty ? AppTypography.fontFamily : 'FooterEvidence');
        expect(style.locale, AppTypography.locale);
        expect(style.fontFamilyFallback, AppTypography.fallback);
        expect(style.decoration ?? TextDecoration.none, TextDecoration.none);
        expect(style.fontWeight, isNot(FontWeight.w900));
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
