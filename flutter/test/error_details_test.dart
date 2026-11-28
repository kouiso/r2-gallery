import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/diag/error_details.dart';
import 'package:r2_gallery/src/state/app_state.dart';
import 'package:r2_gallery/src/state/trash_ops.dart';
import 'package:r2_gallery/src/store/device_auth.dart';
import 'package:r2_gallery/src/store/kv.dart';
import 'package:r2_gallery/src/ui/settings_tab.dart';
import 'package:r2_gallery/src/ui/theme.dart';

class _NoAuth implements DeviceAuth {
  @override
  Future<bool> isAvailable() async => false;
  @override
  Future<bool> verify(String reason) async => false;
}

/// ゴミ箱への移動を Worker の 404 で落とす。理由（code）と呼び出しが画面の文に載るかを見る
class _TrashFails extends ApiClient {
  @override
  Future<String> trash(String lib, String key) async => throw const ApiError(
      404, 'Not Found',
      code: 'not_found',
      request: 'POST /v1/personal/trash',
      kind: 'badResponse');
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    ErrorDetails.enabled.value = false;
  });

  group('describeErrorDetail', () {
    test('ApiError は HTTP の番号・Worker の理由・呼び出し・種類を出す', () {
      const e = ApiError(409, 'Conflict',
          code: 'name_taken', request: 'PUT /v1/personal/a.jpg', kind: 'badResponse');
      final s = describeErrorDetail(e);
      expect(s, contains('HTTP 409'));
      expect(s, contains('理由: name_taken'));
      expect(s, contains('呼び出し: PUT /v1/personal/a.jpg'));
      expect(s, contains('種類: badResponse'));
    });

    test('応答の無い失敗は「通信エラー」と種類で見分けられる', () {
      const e = ApiError(0, 'connection timeout', kind: 'connectionTimeout');
      final s = describeErrorDetail(e);
      expect(s, contains('通信エラー（応答なし）'));
      expect(s, contains('種類: connectionTimeout'));
    });

    test('DioException もホストとクエリを出さずに呼び出しを出す', () {
      final e = DioException(
        requestOptions:
            RequestOptions(path: 'https://w.example/v1/p/list?token=abc', method: 'GET'),
        type: DioExceptionType.receiveTimeout,
        message: 'timeout',
      );
      final s = describeErrorDetail(e);
      expect(s, contains('呼び出し: GET /v1/p/list'));
      expect(s, isNot(contains('w.example')));
      expect(s, isNot(contains('abc')));
    });

    test('トークンや署名は伏せる', () {
      final s = describeErrorDetail(
          StateError('Bearer secret-token https://x/f/p/a.jpg?e=1&s=sig123 token=zzz'));
      expect(s, isNot(contains('secret-token')));
      expect(s, isNot(contains('sig123')));
      expect(s, contains('Bearer ***'));
      expect(s, contains('s=***'));
    });

    test('長すぎる理由は切る', () {
      expect(describeErrorDetail(StateError('x' * 2000)).length, lessThan(700));
    });
  });

  group('ErrorDetails.compose', () {
    test('OFF の時は今まで通り決まった文だけ', () {
      expect(ErrorDetails.compose('ゴミ箱への移動に失敗しました', const ApiError(500, 'x')),
          'ゴミ箱への移動に失敗しました');
    });

    test('ON の時は決まった文の下に理由を足す', () {
      ErrorDetails.enabled.value = true;
      final s = ErrorDetails.compose(
          'ゴミ箱への移動に失敗しました', const ApiError(500, 'x', code: 'r2_error'));
      expect(s, startsWith('ゴミ箱への移動に失敗しました\n\n'));
      expect(s, contains('HTTP 500'));
      expect(s, contains('理由: r2_error'));
    });

    test('ON でも理由が無ければ決まった文だけ', () {
      ErrorDetails.enabled.value = true;
      expect(ErrorDetails.compose('失敗しました', null), '失敗しました');
    });

    test('ON の時の text は理由（code）まで出す。OFF は今まで通り toString', () {
      const e = ApiError(404, 'Not Found', code: 'not_found');
      expect(ErrorDetails.text(e), 'HTTP 404: Not Found');
      ErrorDetails.enabled.value = true;
      expect(ErrorDetails.text(e), contains('理由: not_found'));
    });
  });

  test('切り替えは保存され、次の起動で読み戻される', () async {
    await ErrorDetails.setEnabled(true);
    expect(await Kv.get(Keys.errorDetails), '1');
    ErrorDetails.enabled.value = false;
    await ErrorDetails.load();
    expect(ErrorDetails.on, isTrue);
    await ErrorDetails.setEnabled(false);
    expect(await Kv.get(Keys.errorDetails), '0');
  });

  test('まとめてゴミ箱へ送れなかった時、最初の失敗の理由を控える', () async {
    final res = await trashAll(_TrashFails(), [(lib: 'personal', key: 'a.jpg')]);
    expect(res.failed, 1);
    ErrorDetails.enabled.value = true;
    final s = ErrorDetails.compose('ゴミ箱への移動に失敗しました', res.firstError);
    expect(s, contains('HTTP 404'));
    expect(s, contains('理由: not_found'));
    expect(s, contains('呼び出し: POST /v1/personal/trash'));
  });

  testWidgets('設定の「エラーの詳しい理由を表示」で切り替えられる', (t) async {
    PackageInfo.setMockInitialValues(
      appName: 'R2 Gallery',
      packageName: 'app.r2gallery',
      version: '0.4.0',
      buildNumber: '400',
      buildSignature: '',
    );
    t.view.physicalSize = const Size(390, 2000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final app = AppState(
      api: ApiClient(),
      bakedEndpoint: '',
      bakedToken: '',
      deviceAuth: _NoAuth(),
      isWeb: false,
    );
    await t.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(body: SettingsTab(app: app)),
    ));
    await t.pumpAndSettle();
    expect(find.text('エラーの詳しい理由を表示'), findsOneWidget);
    final sw = find.byKey(const ValueKey('error-details-switch'));
    expect(t.widget<SwitchListTile>(sw).value, isFalse);
    await t.ensureVisible(sw);
    await t.tap(sw);
    await t.pumpAndSettle();
    expect(ErrorDetails.on, isTrue);
    expect(t.widget<SwitchListTile>(sw).value, isTrue);
    expect(await Kv.get(Keys.errorDetails), '1');
  });
}
