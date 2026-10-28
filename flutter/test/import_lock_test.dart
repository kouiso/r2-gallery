import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/main.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/state/app_state.dart';
import 'package:r2_gallery/src/store/device_auth.dart';
import 'package:r2_gallery/src/store/kv.dart';
import 'package:r2_gallery/src/store/lock_platform.dart';
import 'package:r2_gallery/src/webdl/detected.dart';

class _Auth implements DeviceAuth {
  @override
  Future<bool> isAvailable() async => true;
  // ロック画面を確かめるため、認証ダイアログは通さない
  @override
  Future<bool> verify(String reason) async => false;
}

class _Clock implements LockClock {
  @override
  Future<ClockReading> read() async => (boot: 0, mono: 0, wall: 0);
}

class _Window implements SecureWindow {
  @override
  Future<void> setSecure(bool on) async {}
}

class _Api extends ApiClient {
  @override
  Future<List<Library>> libraries() async =>
      const [Library(id: 'lib', title: 'Lib')];
  @override
  Future<FolderPage> folder(String libId,
          {String prefix = '', String? cursor, bool recursive = false}) async =>
      const FolderPage(items: []);
  @override
  Future<List<Album>> albums(String libId) async => const [];
}

Future<AppState> _app() async {
  FlutterSecureStorage.setMockInitialValues({
    Keys.endpoint: 'https://w.example',
    Keys.token: 'tk',
  });
  final app = AppState(
    api: _Api(),
    bakedEndpoint: '',
    bakedToken: '',
    deviceAuth: _Auth(),
    clock: _Clock(),
    isWeb: false,
  );
  await app.init();
  app.unlock();
  return app;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppState> openImportTab(WidgetTester tester) async {
    final app = await _app();
    await tester.pumpWidget(R2GalleryApp(
        app: app, secureWindow: _Window(), listenDeepLinks: false));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('取り込み'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('ネットから取り込む'), findsOneWidget);
    return app;
  }

  testWidgets('ロックすると取り込みタブ（内蔵ブラウザ）も見えず触れなくなる', (tester) async {
    final app = await openImportTab(tester);

    expect(app.lockNow(), isTrue);
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('ロック中'), findsOneWidget);
    expect(find.text('ネットから取り込む'), findsNothing);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('取り込みタブから開いた転送シートもロックで隠れる', (tester) async {
    final app = await openImportTab(tester);
    // 音声は取りに行かずその場で失敗の行になるので、通信なしで転送の行を作れる
    app.webQueue.enqueue('lib', const [
      DetectedItem('https://cdn.example.com/a/song.mp3', DetectedKind.audio),
    ]);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('失敗 1件'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('転送の状況'), findsOneWidget);

    app.lockNow();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('転送の状況'), findsNothing);
    expect(find.text('ロック中'), findsOneWidget);
  });
}
