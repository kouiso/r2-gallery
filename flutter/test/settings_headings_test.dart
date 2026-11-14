import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
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

class _Api extends ApiClient {
  @override
  Future<bool> probe(String endpoint, String token) async => true;
  @override
  Future<List<Library>> libraries() async => const [
    Library(id: 'a', title: 'A'),
    Library(id: 'b', title: 'B'),
  ];
}

/// 非対応環境（Web）の再現。テストは VM なので OfflineStore.supported は true になり、
/// そのままでは「出さない」分岐を通れない
class _NoOfflineApp extends AppState {
  _NoOfflineApp({
    super.api,
    super.deviceAuth,
    super.isWeb,
    super.bakedEndpoint,
    super.bakedToken,
  });
  @override
  bool get offlineSupported => false;
}

AppState _mk({bool offline = true, ApiClient? api}) {
  if (!offline) {
    return _NoOfflineApp(
      api: api ?? ApiClient(),
      bakedEndpoint: '',
      bakedToken: '',
      deviceAuth: _NoAuth(),
      isWeb: false,
    );
  }
  return AppState(
    api: api ?? ApiClient(),
    bakedEndpoint: '',
    bakedToken: '',
    deviceAuth: _NoAuth(),
    isWeb: false,
  );
}

Future<void> _pump(WidgetTester t, AppState app) async {
  FlutterSecureStorage.setMockInitialValues({});
  PackageInfo.setMockInitialValues(
    appName: 'R2 Gallery',
    packageName: 'app.r2gallery',
    version: '0.4.0',
    buildNumber: '400',
    buildSignature: '',
  );
  t.view.physicalSize = const Size(390, 1600);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
      // 実機では親が AppState を聞いて作り直すので、同じ形にする
      body: ListenableBuilder(
          listenable: app, builder: (_, __) => SettingsTab(app: app)),
    ),
    ),
  );
  await t.pumpAndSettle();
}

Finder _heading(String s) => find.widgetWithText(SettingsHeading, s);

void main() {
  testWidgets('設定タブは見出しで区切られ、今ある操作が全部残っている', (t) async {
    await _pump(t, _mk());
    // テストは VM なので OfflineStore.supported が true: オフライン保存の見出しも出る
    for (final h in ['接続', 'ロック', 'オフライン保存', 'このアプリについて']) {
      expect(_heading(h), findsOneWidget, reason: h);
    }
    double y(String s) => t.getTopLeft(_heading(s)).dy;
    expect(y('接続') < y('ロック'), isTrue);
    expect(y('ロック') < y('オフライン保存'), isTrue);
    expect(y('オフライン保存') < y('このアプリについて'), isTrue);
    for (final s in [
      '画面ロックで保護',
      '開くとき指紋・顔・PINを求めます',
      '再ロックまでの時間',
      '今すぐロック',
      'PINを設定',
      '端末に暗号化して保存中',
      '一覧',
      'オフライン保存をすべて削除',
      'バージョン',
      '0.4.0（400）',
    ]) {
      expect(find.text(s), findsOneWidget, reason: s);
    }
  });

  testWidgets('見出しごとに枠は1つで、行の間は線で区切る', (t) async {
    await _pump(t, _mk());
    // 接続 / ロック / オフライン保存 / このアプリについて
    expect(find.byType(SettingsGroup), findsNWidgets(4));
    expect(find.byType(Card), findsNWidgets(4));
    // ロックは4行 → 線は3本
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('今すぐロック'),
          matching: find.byType(SettingsGroup),
        ),
        matching: find.byType(Divider),
      ),
      findsNWidgets(3),
    );
  });

  testWidgets('非対応環境ではオフライン保存の見出しも行も出さない', (t) async {
    await _pump(t, _mk(offline: false));
    expect(_heading('オフライン保存'), findsNothing);
    expect(find.text('端末に暗号化して保存中'), findsNothing);
    expect(find.text('オフライン保存をすべて削除'), findsNothing);
    for (final h in ['接続', 'ロック', 'このアプリについて']) {
      expect(_heading(h), findsOneWidget, reason: h);
    }
  });

  testWidgets('接続中は切断が接続の枠に入り、押すと確認のうえ未接続に戻る', (t) async {
    final app = _mk(api: _Api());
    await app.connect('https://w.example', 'tk');
    await _pump(t, app);
    expect(find.text('接続中'), findsOneWidget);
    final group = find.ancestor(
      of: find.text('接続中'),
      matching: find.byType(SettingsGroup),
    );
    expect(
      find.descendant(of: group, matching: find.text('切断')),
      findsOneWidget,
    );
    // 切断は接続のすぐ下で、ロックの見出しより上
    expect(
      t.getTopLeft(find.text('切断')).dy > t.getTopLeft(find.text('接続中')).dy,
      isTrue,
    );
    expect(
      t.getTopLeft(find.text('切断')).dy < t.getTopLeft(_heading('ロック')).dy,
      isTrue,
    );

    await t.tap(find.text('切断'));
    await t.pumpAndSettle();
    expect(find.text('切断しますか？'), findsOneWidget);
    await t.tap(find.widgetWithText(FilledButton, '切断'));
    await t.pumpAndSettle();
    expect(app.connected, isFalse);
    expect(find.text('未接続'), findsOneWidget);
    expect(find.text('切断'), findsNothing);
  });
}
