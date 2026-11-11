import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/offline/offline_screen.dart';
import 'package:r2_gallery/src/offline/offline_store.dart';
import 'package:r2_gallery/src/state/app_state.dart';
import 'package:r2_gallery/src/ui/theme.dart';

class _NoReads implements SecretKv {
  @override
  Future<String?> get(String key) =>
      throw StateError('unsupported storage was read');
  @override
  Future<void> set(String key, String value) =>
      throw StateError('unsupported storage was written');
}

class _Unsupported extends AppState {
  _Unsupported()
    : super(
        bakedEndpoint: '',
        bakedToken: '',
        offline: OfflineStore(kv: _NoReads()),
      );
  @override
  bool get offlineSupported => false;
  @override
  bool get offlineAccessible => true;
}

void main() {
  setUpAll(() async {
    final icons = FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    final font = FontLoader('R2GalleryJP');
    for (final weight in ['Regular', 'Bold']) {
      font.addFont(rootBundle.load('assets/fonts/R2GalleryJP-$weight.otf'));
    }
    await font.load();
  });
  testWidgets('Web等の非対応環境では保存せず、アプリだけの保存だと表示しない', (tester) async {
    final app = _Unsupported();
    addTearDown(app.dispose);
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    const capture = ValueKey('storage-evidence');
    await tester.pumpWidget(RepaintBoundary(key: capture, child:
      MaterialApp(
        theme: buildAppTheme(),
        debugShowCheckedModeBanner: false,
        home: Scaffold(body: OfflineSettingsCard(app: app)),
      ),
    ));
    await tester.pump();
    expect(find.text('アプリ専用保存'), findsOneWidget);
    expect(find.textContaining('Web版はアプリ専用保存に対応していません'), findsOneWidget);
    expect(find.textContaining('このアプリ内のみ'), findsNothing);
    expect(find.text('オフライン保存をすべて削除'), findsNothing);
    expect(tester.takeException(), isNull);
    const dir = String.fromEnvironment('PRIVATE_STORAGE_EVIDENCE_DIR');
    if (dir.isNotEmpty) {
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(capture));
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        try {
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('$dir/unsupported-storage.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(data!.buffer.asUint8List());
        } finally { image.dispose(); }
      });
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
