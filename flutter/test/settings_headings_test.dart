import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/state/app_state.dart';
import 'package:r2_gallery/src/store/device_auth.dart';
import 'package:r2_gallery/src/ui/settings_tab.dart';
import 'package:r2_gallery/src/ui/theme.dart';

class _NoAuth implements DeviceAuth {
  @override
  Future<bool> isAvailable() async => false;
  @override
  Future<bool> verify(String reason) async => false;
}

Future<void> _pump(WidgetTester t) async {
  FlutterSecureStorage.setMockInitialValues({});
  PackageInfo.setMockInitialValues(
    appName: 'R2 Gallery',
    packageName: 'app.r2gallery',
    version: '0.4.0',
    buildNumber: '400',
    buildSignature: '',
  );
  final app = AppState(
    api: ApiClient(),
    bakedEndpoint: '',
    bakedToken: '',
    deviceAuth: _NoAuth(),
    isWeb: false,
  );
  t.view.physicalSize = const Size(390, 1400);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildAppTheme(),
    home: Scaffold(body: SettingsTab(app: app)),
  ));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('設定タブは見出しで区切られ、今ある操作が全部残っている', (t) async {
    await _pump(t);
    // 非対応環境（テスト・Web）ではオフライン保存の見出しは出さない
    for (final h in ['接続', 'ロック', 'このアプリについて']) {
      expect(find.text(h), findsOneWidget, reason: h);
    }
    final y = (String s) => t.getTopLeft(find.text(s)).dy;
    expect(y('接続') < y('ロック'), isTrue);
    expect(y('ロック') < y('このアプリについて'), isTrue);
    for (final s in [
      '画面ロックで保護',
      '再ロックまでの時間',
      '今すぐロック',
      'PINを設定',
      'バージョン',
      '0.4.0（400）',
    ]) {
      expect(find.text(s), findsOneWidget, reason: s);
    }
  });
}
