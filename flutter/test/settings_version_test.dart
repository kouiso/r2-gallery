import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:r2_gallery/src/ui/settings_tab.dart';

Future<void> _pump(WidgetTester t) async {
  await t.pumpWidget(const MaterialApp(
      home: Scaffold(body: Center(child: AppVersionLabel()))));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('版数はビルドの値から出し、Flutter の文字を含めない', (t) async {
    PackageInfo.setMockInitialValues(
      appName: 'R2 Gallery',
      packageName: 'app.r2gallery',
      version: '9.8.7',
      buildNumber: '654',
      buildSignature: '',
    );
    await _pump(t);
    expect(find.text('9.8.7（654）'), findsOneWidget);
    expect(find.textContaining('Flutter'), findsNothing);
    expect(find.textContaining('0.1.0'), findsNothing);
  });

  testWidgets('版数が取れないときは製品名だけを出す', (t) async {
    PackageInfo.setMockInitialValues(
      appName: 'R2 Gallery',
      packageName: 'app.r2gallery',
      version: '',
      buildNumber: '',
      buildSignature: '',
    );
    await _pump(t);
    expect(find.text('—'), findsOneWidget);
  });

  test('ビルド番号が空なら版だけ', () {
    expect(formatAppVersion('1.2.3', ''), '1.2.3');
    expect(formatAppVersion('1.2.3', '45'), '1.2.3（45）');
  });
}
