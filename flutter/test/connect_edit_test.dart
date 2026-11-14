import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/state/app_state.dart';
import 'package:r2_gallery/src/store/device_auth.dart';
import 'package:r2_gallery/src/store/kv.dart';
import 'package:r2_gallery/src/transfer/transfer_platform.dart';
import 'package:r2_gallery/src/transfer/transfer_queue.dart';
import 'package:r2_gallery/src/ui/settings_tab.dart';
import 'package:r2_gallery/src/ui/theme.dart';

class _Api extends ApiClient {
  ProbeOutcome next = const ProbeOutcome.ok(libraryCount: 2);
  bool probeOk = true;
  final probed = <String>[];

  @override
  Future<ProbeOutcome> probeOutcome(String endpoint, String token) async {
    probed.add('o:$endpoint');
    return next;
  }

  @override
  Future<bool> probe(String endpoint, String token) async {
    probed.add('p:$endpoint');
    return probeOk;
  }

  @override
  Future<List<Library>> libraries() async =>
      const [Library(id: 'review', title: 'Review')];
}

// 端末の口を通らない転送の見張り。回線の知らせは出さない
class _NoPlatform implements TransferPlatform {
  @override
  Future<void> setKeepAlive(bool active) async {}
  @override
  Stream<bool> get online => const Stream.empty();
}

class _NoAuth implements DeviceAuth {
  @override
  Future<bool> isAvailable() async => false;
  @override
  Future<bool> verify(String reason) async => false;
}

Future<(AppState, _Api)> _pump(WidgetTester t) async {
  FlutterSecureStorage.setMockInitialValues({Keys.deviceLock: '0'});
  PackageInfo.setMockInitialValues(
      appName: 'R2 Gallery',
      packageName: 'app.r2gallery',
      version: '0.4.0',
      buildNumber: '400',
      buildSignature: '');
  final api = _Api();
  final app = AppState(
      api: api,
      bakedEndpoint: '',
      bakedToken: '',
      deviceAuth: _NoAuth(),
      transferPlatform: _NoPlatform(),
      isWeb: false);
  expect(await app.connect('https://old.example', 'old-token'), isNull);
  api.probed.clear();
  t.view.physicalSize = const Size(390, 1000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(body: SettingsTab(app: app))));
  await t.pumpAndSettle();
  return (app, api);
}

Future<void> _fill(WidgetTester t, String ep, String tok) async {
  await t.enterText(find.byKey(const Key('endpointField')), ep);
  await t.enterText(find.byKey(const Key('tokenField')), tok);
  await t.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('接続中の行から「接続先を変更」を開け、今の接続先が入っている', (t) async {
    await _pump(t);
    await t.tap(find.text('変更'));
    await t.pumpAndSettle();
    expect(find.text('接続先を変更'), findsOneWidget);
    expect(find.text('https://old.example'), findsOneWidget);
  });

  testWidgets('接続を試すだけでは今の接続は変わらない', (t) async {
    final (app, api) = await _pump(t);
    await t.tap(find.text('変更'));
    await t.pumpAndSettle();
    await _fill(t, 'https://new.example', 'new-token');
    await t.tap(find.text('接続を試す'));
    await t.pumpAndSettle();
    expect(find.textContaining('ライブラリ 2 件が見つかりました'), findsOneWidget);
    expect(app.api.conn?.endpoint, 'https://old.example');
    expect(await Kv.get(Keys.endpoint), 'https://old.example');
    expect(api.probed, ['o:https://new.example']);
  });

  testWidgets('失敗は理由を出し、保存せず今の接続のまま', (t) async {
    final (app, api) = await _pump(t);
    api.next = ProbeOutcome.badToken;
    await t.tap(find.text('変更'));
    await t.pumpAndSettle();
    await _fill(t, 'https://new.example', 'bad');
    await t.tap(find.text('接続を試す'));
    await t.pumpAndSettle();
    expect(find.textContaining('トークンが違います'), findsOneWidget);

    // 保存の失敗も試すボタンと同じ理由を出す（共通の文言にしない）
    await t.tap(find.text('保存して切り替える'));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('errorNote')), findsOneWidget);
    expect(find.textContaining('トークンが違います'), findsOneWidget);
    // デザインどおり、失敗の時は下の説明と入れ替えて理由だけを出す
    expect(find.textContaining('今の接続のまま使えます'), findsNothing);

    api.next = ProbeOutcome.unreachable;
    await t.tap(find.text('保存して切り替える'));
    await t.pumpAndSettle();
    expect(find.textContaining('接続先に届きません'), findsOneWidget);
    expect(find.textContaining(connectFailedMessage), findsNothing);
    expect(find.text('接続先を変更'), findsOneWidget); // 画面に残る
    expect(app.connected, isTrue);
    expect(app.api.conn?.endpoint, 'https://old.example');
    expect(app.api.conn?.token, 'old-token');
    expect(await Kv.get(Keys.endpoint), 'https://old.example');
    expect(await Kv.get(Keys.token), 'old-token');
  });

  testWidgets('保存に成功した時だけ切り替わり、画面を閉じる', (t) async {
    final (app, _) = await _pump(t);
    await t.tap(find.text('変更'));
    await t.pumpAndSettle();
    await _fill(t, 'https://new.example', 'new-token');
    await t.tap(find.text('保存して切り替える'));
    await t.pumpAndSettle();
    expect(app.api.conn?.endpoint, 'https://new.example');
    expect(await Kv.get(Keys.endpoint), 'https://new.example');
    expect(find.text('接続先を変更'), findsNothing);
  });

  testWidgets('同じホストならトークン欄が空でも今のトークンのまま保存できる', (t) async {
    final (app, api) = await _pump(t);
    await t.tap(find.text('変更'));
    await t.pumpAndSettle();
    await t.enterText(
        find.byKey(const Key('endpointField')), 'https://OLD.example/');
    await t.pump();
    await t.tap(find.text('保存して切り替える'));
    await t.pumpAndSettle();
    expect(api.probed, ['o:https://OLD.example']);
    expect(app.api.conn?.token, 'old-token');
    expect(await Kv.get(Keys.token), 'old-token');
    expect(find.text('接続先を変更'), findsNothing);
  });

  testWidgets('別のホストでトークン欄が空なら、今のトークンを送らずに新しいトークンを求める', (t) async {
    final (app, api) = await _pump(t);
    await t.tap(find.text('変更'));
    await t.pumpAndSettle();
    await t.enterText(
        find.byKey(const Key('endpointField')), 'https://new.example');
    await t.pump();
    await t.tap(find.text('接続を試す'));
    await t.pumpAndSettle();
    expect(find.text('接続先を変える時は、新しい接続先のトークンを入れてください。'),
        findsOneWidget);
    await t.tap(find.text('保存して切り替える'));
    await t.pumpAndSettle();
    expect(find.text('接続先を変える時は、新しい接続先のトークンを入れてください。'),
        findsOneWidget);
    expect(api.probed, isEmpty);
    expect(find.text('接続先を変更'), findsOneWidget);
    expect(app.api.conn?.endpoint, 'https://old.example');
    expect(await Kv.get(Keys.endpoint), 'https://old.example');
  });

  group('送り終えていない転送がある時', () {
    Future<void> queueUpload(WidgetTester t, AppState app) async {
      // 台帳の復元は端末の口（path_provider）を通り、テストの時計では返ってこないので本物の非同期で積む。
      // 回線なしにして、行を待機中のまま残す
      final n = await t.runAsync(() async {
        app.transfers.setOnline(false);
        return app.upload('review', [
          UploadSource(
              name: 'a.jpg',
              size: 3,
              mime: 'image/jpeg',
              bytes: Uint8List.fromList([1, 2, 3])),
        ]);
      });
      expect(n, 1);
      expect(app.transfers.tasks.single.status, TransferStatus.queued);
    }

    testWidgets('別の接続先への保存は止め、何も確かめず保存もしない', (t) async {
      final (app, api) = await _pump(t);
      await queueUpload(t, app);
      await t.tap(find.text('変更'));
      await t.pumpAndSettle();
      await _fill(t, 'https://new.example', 'new-token');
      await t.tap(find.text('保存して切り替える'));
      await t.pumpAndSettle();
      expect(find.text(AppState.unsentTransfersMessage), findsOneWidget);
      expect(api.probed, isEmpty);
      expect(find.text('接続先を変更'), findsOneWidget);
      expect(app.api.conn?.endpoint, 'https://old.example');
      expect(app.api.conn?.token, 'old-token');
      expect(await Kv.get(Keys.endpoint), 'https://old.example');

      // 取り消して転送が無くなれば保存できる
      await t.runAsync(
          () => app.transfers.cancel(app.transfers.tasks.single.id));
      await t.pumpAndSettle();
      expect(app.hasUnsentTransfers, isFalse);
      await t.tap(find.text('保存して切り替える'));
      await t.pumpAndSettle();
      expect(app.api.conn?.endpoint, 'https://new.example');
      expect(find.text('接続先を変更'), findsNothing);
    });

    testWidgets('同じホストでトークンだけ替える保存は止めない', (t) async {
      final (app, _) = await _pump(t);
      await queueUpload(t, app);
      await t.tap(find.text('変更'));
      await t.pumpAndSettle();
      await _fill(t, 'https://old.example', 'new-token');
      await t.tap(find.text('保存して切り替える'));
      await t.pumpAndSettle();
      expect(app.api.conn?.token, 'new-token');
      expect(await Kv.get(Keys.token), 'new-token');
      expect(app.transfers.tasks.single.status, TransferStatus.queued);
    });
  });

  test('転送が空なら別の接続先へ保存できる', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final api = _Api();
    final app = AppState(
        api: api,
        bakedEndpoint: '',
        bakedToken: '',
        transferPlatform: _NoPlatform(),
        isWeb: false);
    expect(await app.connect('https://old.example', 'old-token'), isNull);
    expect(app.hasUnsentTransfers, isFalse);
    expect(await app.saveConnection('https://new.example', 'new-token'), isNull);
    expect(app.api.conn?.endpoint, 'https://new.example');
  });

  testWidgets('トークン欄の案内と、今の接続先の緑の点・成功の枠が出る', (t) async {
    await _pump(t);
    await t.tap(find.text('変更'));
    await t.pumpAndSettle();
    expect(find.text('変えない時は空のまま'), findsOneWidget);
    expect(find.byKey(const Key('currentDot')), findsOneWidget);
    await t.tap(find.text('接続を試す'));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('okBox')), findsOneWidget);
    expect(find.text('接続できました'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
  });
}
