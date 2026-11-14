import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/ui/theme.dart';

const _captureKey = ValueKey('japanese-font-evidence');
const _samples = [
  '骨 直 令 辺 門 葛 辻 道 週 返',
  '写真・動画　明るさ・音量　保存済み',
  'ひらがな カタカナ ｶﾀｶﾅ ABC abc 0123',
  '動画 MP4 · 1080p / 1.25 GB · 00:30',
];

void main() {
  const loadBundled = bool.fromEnvironment('JAPANESE_FONT_LOAD_BUNDLED', defaultValue: true);
  setUpAll(() async {
    if (!loadBundled) return;
    final loader = FontLoader('R2GalleryJP');
    for (final weight in ['Regular', 'Bold']) {
      loader.addFont(rootBundle.load('assets/fonts/R2GalleryJP-$weight.otf'));
    }
    await loader.load();
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets('同梱日本語字形と混在文字を表示 scale=$scale', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final theme = buildAppTheme();
      await tester.pumpWidget(RepaintBoundary(
        key: _captureKey,
        child: MaterialApp(
          theme: theme,
          home: Scaffold(
            appBar: AppBar(title: const Text('日本語の字体・Japanese')),
            body: ListView(padding: const EdgeInsets.all(16), children: [
              for (final sample in _samples) ...[
                Text(sample),
                Text(sample, style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 16),
              ],
            ]),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      if (loadBundled) {
        expect(theme.textTheme.bodyMedium?.fontFamily, 'R2GalleryJP');
        expect(theme.textTheme.bodyMedium?.locale, const Locale('ja', 'JP'));
      }
      expect(tester.takeException(), isNull);
      const dir = String.fromEnvironment('JAPANESE_FONT_EVIDENCE_DIR');
      const stage = String.fromEnvironment('JAPANESE_FONT_EVIDENCE_STAGE', defaultValue: 'after');
      if (dir.isNotEmpty) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(_captureKey));
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          try {
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            if (data == null) throw StateError('PNG encoding failed');
            final file = File('$dir/$stage-japanese-$scale.png');
            await file.parent.create(recursive: true);
            await file.writeAsBytes(data.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
      }
    });
  }
}
