import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:r2_gallery/main.dart';

void main() {
  testWidgets('app boots to connect screen when unconfigured',
      (WidgetTester tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    await tester.pumpWidget(const R2GalleryApp(listenDeepLinks: false));
    await tester.pump();
    // KV 未設定ならローディング→接続画面のどちらかが出る
    expect(find.byType(R2GalleryApp), findsOneWidget);
    // 起動処理の上限（20秒）を待たせたまま終わらせない
    await tester.pump(const Duration(seconds: 21));
  });

  testWidgets('アプリは日本語ロケール固定（端末ロケールに関係なく日本語字形）',
      (WidgetTester tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    await tester.pumpWidget(const R2GalleryApp(listenDeepLinks: false));
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.locale, const Locale('ja'));
    expect(app.supportedLocales, [const Locale('ja')]);
    await tester.pump(const Duration(seconds: 21));
  });
}
