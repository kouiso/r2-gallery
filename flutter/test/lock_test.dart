import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/main.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/state/app_state.dart';
import 'package:r2_gallery/src/store/device_auth.dart';
import 'package:r2_gallery/src/store/kv.dart';
import 'package:r2_gallery/src/store/lock_platform.dart';
import 'package:r2_gallery/src/store/lock_policy.dart';
import 'package:r2_gallery/src/ui/app_lock_layer.dart';
import 'package:r2_gallery/src/ui/home_shell.dart';
import 'package:r2_gallery/src/ui/lock_gate.dart';

class _FakeAuth implements DeviceAuth {
  _FakeAuth({this.available = true, this.verifyResult = true});
  bool available;
  bool verifyResult;
  int verifyCalls = 0;
  AppState? watch;
  bool sawAuthenticating = false;

  /// 端末側のエラーで問い合わせが失敗する
  bool probeThrows = false;

  /// 一部端末のように問い合わせが返ってこない
  bool probeHangs = false;

  @override
  Future<bool> isAvailable() {
    if (probeHangs) return Completer<bool>().future;
    if (probeThrows) {
      return Future.error(PlatformException(code: 'auth_error'));
    }
    return Future.value(available);
  }

  @override
  Future<bool> verify(String reason) async {
    verifyCalls++;
    sawAuthenticating = watch?.authenticating ?? false;
    return verifyResult;
  }
}

/// 端末起動からの経過（boot）・Stopwatch（mono）・壁時計（wall）を別々に動かせる時計
class _FakeClock implements LockClock {
  int? boot = 0;
  int mono = 0;
  int wall = 1000000;

  void advance(int ms) {
    if (boot != null) boot = boot! + ms;
    mono += ms;
    wall += ms;
  }

  @override
  Future<ClockReading> read() async => (boot: boot, mono: mono, wall: wall);
}

class _FakeSecureWindow implements SecureWindow {
  final calls = <bool>[];
  @override
  Future<void> setSecure(bool on) async => calls.add(on);
}

class _Api extends ApiClient {
  @override
  Future<List<Library>> libraries() async => const [];
}

// 起動前に保存されている値（PIN や設定）を差し込む
Map<String, String> _seededValues = {};

Future<AppState> _connected({
  required _FakeAuth auth,
  LockClock? clock,
  bool isWeb = false,
}) async {
  FlutterSecureStorage.setMockInitialValues({
    Keys.endpoint: 'https://w.example',
    Keys.token: 'tk',
    ..._seededValues,
  });
  final app = AppState(
    api: _Api(),
    bakedEndpoint: '',
    bakedToken: '',
    deviceAuth: auth,
    clock: clock ?? _FakeClock(),
    isWeb: isWeb,
  );
  auth.watch = app;
  await app.init();
  return app;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _seededValues = {};
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('ロックの判定（純粋関数）', () {
    test('起動時は画面ロックが既定ONでロックする。web は PIN がある時だけ', () {
      expect(
          shouldGateAtStart(
              hasPin: false, deviceLockEnabled: true, isWeb: false),
          isTrue);
      expect(
          shouldGateAtStart(
              hasPin: false, deviceLockEnabled: false, isWeb: false),
          isFalse);
      expect(
          shouldGateAtStart(
              hasPin: false, deviceLockEnabled: true, isWeb: true),
          isFalse);
      expect(
          shouldGateAtStart(
              hasPin: true, deviceLockEnabled: false, isWeb: true),
          isTrue);
    });

    test('解除手段が無ければロックできない（行き止まりを作らない）', () {
      expect(
          canLockNow(
              hasPin: false, deviceLockEnabled: true, deviceAvailable: false),
          isFalse);
      expect(
          canLockNow(
              hasPin: false, deviceLockEnabled: false, deviceAvailable: true),
          isFalse);
      expect(
          canLockNow(
              hasPin: false, deviceLockEnabled: true, deviceAvailable: true),
          isTrue);
      expect(
          canLockNow(
              hasPin: true, deviceLockEnabled: false, deviceAvailable: false),
          isTrue);
    });

    test('猶予を超えた時だけ再ロックする（ちょうどは許す）', () {
      bool relock(int? elapsed, int grace,
              {bool locked = false, bool canLock = true}) =>
          shouldRelock(
              elapsedMs: elapsed,
              graceMs: grace,
              locked: locked,
              canLock: canLock);
      expect(relock(3600000, 3600000), isFalse);
      expect(relock(3600001, 3600000), isTrue);
      expect(relock(1, 0), isTrue);
      expect(relock(null, 0), isFalse);
      expect(relock(99999999, 0, locked: true), isFalse);
      expect(relock(99999999, 0, canLock: false), isFalse);
    });

    test('猶予の表示名', () {
      expect(graceLabel(0), '毎回ロック');
      expect(graceLabel(3600000), '1時間');
      expect(graceLabel(120000), '2分');
    });
  });

  group('保存値', () {
    test('画面ロックは既定ON、猶予は既定1時間、保存すると読み戻せる', () async {
      expect(await LockSettings.deviceLockEnabled(), isTrue);
      expect(await LockSettings.relockGraceMs(), relockGraceDefaultMs);
      await LockSettings.setDeviceLockEnabled(false);
      await LockSettings.setRelockGraceMs(60000);
      expect(await LockSettings.deviceLockEnabled(), isFalse);
      expect(await LockSettings.relockGraceMs(), 60000);
    });

    test('壊れた猶予の値は既定に戻す', () async {
      await Kv.set(Keys.lockGraceMs, 'abc');
      expect(await LockSettings.relockGraceMs(), relockGraceDefaultMs);
      await Kv.set(Keys.lockGraceMs, '-5');
      expect(await LockSettings.relockGraceMs(), relockGraceDefaultMs);
    });
  });

  group('AppState のロック', () {
    test('PIN が無くても、端末の画面ロックがあれば起動時にロックされる', () async {
      final app = await _connected(auth: _FakeAuth());
      expect(app.hasPin, isFalse);
      expect(app.locked, isTrue);
    });

    test('端末の認証に成功したら解除できる', () async {
      final auth = _FakeAuth();
      final app = await _connected(auth: auth);
      expect(await app.deviceUnlock(), isTrue);
      expect(auth.sawAuthenticating, isTrue);
      expect(app.authenticating, isFalse);
      expect(app.locked, isFalse);
    });

    test('認証に失敗したらロックのまま', () async {
      final app = await _connected(auth: _FakeAuth(verifyResult: false));
      expect(await app.deviceUnlock(), isFalse);
      expect(app.locked, isTrue);
    });

    test('PIN が無くても「今すぐロック」でロックできる', () async {
      final app = await _connected(auth: _FakeAuth());
      app.unlock();
      expect(app.lockNow(), isTrue);
      expect(app.locked, isTrue);
    });

    test('画面ロックを切ると起動時にロックしない', () async {
      _seededValues = {Keys.deviceLock: '0'};
      final app = await _connected(auth: _FakeAuth());
      expect(app.locked, isFalse);
      expect(app.lockNow(), isFalse);
    });

    test('解除手段が無い端末では覆わず、起動時の画面から続けられる', () async {
      final app = await _connected(auth: _FakeAuth(available: false));
      expect(app.locked, isTrue); // 「画面ロックがありません」画面
      app.unlock();
      expect(app.locked, isFalse);
      expect(app.lockNow(), isFalse); // 解除できない覆いはかけない
      expect(app.locked, isFalse);
    });

    test('web は PIN が無ければロックしない。PIN があればロックする', () async {
      final web = await _connected(auth: _FakeAuth(available: false), isWeb: true);
      expect(web.locked, isFalse);
      expect(web.lockNow(), isFalse);

      _seededValues = {Keys.pinHash: 'x', Keys.pinSalt: '00'};
      final withPin =
          await _connected(auth: _FakeAuth(available: false), isWeb: true);
      expect(withPin.locked, isTrue);
      withPin.unlock();
      expect(withPin.lockNow(), isTrue);
    });

    test('猶予を超えてバックグラウンドにいたら再ロックする', () async {
      final clock = _FakeClock();
      final app = await _connected(auth: _FakeAuth(), clock: clock);
      app.unlock();
      app.onBackground();
      clock.advance(relockGraceDefaultMs + 1);
      await app.onForeground();
      expect(app.locked, isTrue);
    });

    test('猶予内に戻ったらロックしない', () async {
      final clock = _FakeClock();
      final app = await _connected(auth: _FakeAuth(), clock: clock);
      app.unlock();
      app.onBackground();
      clock.advance(60000);
      await app.onForeground();
      expect(app.locked, isFalse);
    });

    test('画面が閉じられた後に戻ったら、猶予内でも起動時と同じくロックする', () async {
      final clock = _FakeClock();
      final app = await _connected(auth: _FakeAuth(), clock: clock);
      app.unlock();
      app.onBackground();
      // 転送中に最近使ったアプリの一覧から消された。エンジンだけ残り、次の画面が同じ状態につながる
      app.onDetached();
      clock.advance(60000);
      await app.onForeground();
      expect(app.locked, isTrue);
    });

    test('閉じられた印は1回きり。解除した後の普通の出入りでは猶予が効く', () async {
      final clock = _FakeClock();
      final app = await _connected(auth: _FakeAuth(), clock: clock);
      app.unlock();
      app.onBackground();
      app.onDetached();
      await app.onForeground();
      expect(app.locked, isTrue);
      app.unlock();
      app.onBackground();
      clock.advance(60000);
      await app.onForeground();
      expect(app.locked, isFalse);
    });

    test('解除の手段が無ければ、閉じられた後でも覆わない（行き止まりを作らない）', () async {
      _seededValues = {Keys.deviceLock: '0'};
      final app = await _connected(auth: _FakeAuth(available: false));
      expect(app.locked, isFalse);
      app.onBackground();
      app.onDetached();
      await app.onForeground();
      expect(app.locked, isFalse);
    });

    test('設定した猶予が効く（毎回ロック）', () async {
      final clock = _FakeClock();
      final app = await _connected(auth: _FakeAuth(), clock: clock);
      await app.setRelockGraceMs(0);
      expect(await LockSettings.relockGraceMs(), 0);
      app.unlock();
      app.onBackground();
      clock.advance(1);
      await app.onForeground();
      expect(app.locked, isTrue);
    });

    test('認証ダイアログが出す一時停止は、バックグラウンドに数えない', () async {
      final clock = _FakeClock();
      final app = await _connected(auth: _FakeAuth(), clock: clock);
      app.unlock();
      app.authenticating = true;
      app.onBackground();
      app.authenticating = false;
      clock.advance(relockGraceDefaultMs * 2);
      await app.onForeground();
      expect(app.locked, isFalse);
    });

    test('ロック中に裏へ行っても、戻った時に二重で処理しない', () async {
      final clock = _FakeClock();
      final app = await _connected(auth: _FakeAuth(), clock: clock);
      expect(app.locked, isTrue);
      app.onBackground();
      clock.advance(relockGraceDefaultMs * 2);
      await app.onForeground();
      expect(app.locked, isTrue);
    });

    test('画面ロックをONにすると、その場でロックして解除できるか確かめさせる', () async {
      _seededValues = {Keys.deviceLock: '0'};
      final app = await _connected(auth: _FakeAuth());
      expect(app.locked, isFalse);
      await app.setDeviceLockEnabled(true);
      expect(app.locked, isTrue);
      expect(await LockSettings.deviceLockEnabled(), isTrue);
      await app.setDeviceLockEnabled(false);
      expect(app.locked, isFalse);
      expect(await LockSettings.deviceLockEnabled(), isFalse);
    });
  });

  group('画面', () {
    testWidgets('ロック画面は入った瞬間に認証を一度出し、失敗したら再試行ボタンを出す', (tester) async {
      final auth = _FakeAuth(verifyResult: false);
      final app = await _connected(auth: auth);
      await tester.pumpWidget(MaterialApp(home: LockGate(app: app)));
      await tester.pumpAndSettle();

      expect(auth.verifyCalls, 1);
      expect(find.text('認証できませんでした。もう一度お試しください。'), findsOneWidget);
      expect(find.text('ロックを解除'), findsOneWidget);

      auth.verifyResult = true;
      await tester.tap(find.text('ロックを解除'));
      await tester.pumpAndSettle();
      expect(auth.verifyCalls, 2);
      expect(app.locked, isFalse);
    });

    testWidgets('画面ロックが無く PIN も無ければ「ロックなしで続ける」で抜けられる', (tester) async {
      final app = await _connected(auth: _FakeAuth(available: false));
      await tester.pumpWidget(MaterialApp(home: LockGate(app: app)));
      await tester.pumpAndSettle();

      expect(find.text('画面ロックがありません'), findsOneWidget);
      await tester.tap(find.text('ロックなしで続ける'));
      await tester.pump();
      expect(app.locked, isFalse);
    });

    testWidgets('PIN がある端末では PIN 入力も並べる', (tester) async {
      _seededValues = {Keys.pinHash: 'x', Keys.pinSalt: '00'};
      final app = await _connected(auth: _FakeAuth());
      await tester.pumpWidget(MaterialApp(home: LockGate(app: app)));
      await tester.pumpAndSettle();

      expect(find.text('ロックを解除'), findsOneWidget);
      expect(find.text('PINで解除'), findsOneWidget);
    });

    testWidgets('「今すぐロック」は PIN が無くてもホームに常に出る', (tester) async {
      final app = await _connected(auth: _FakeAuth());
      app.unlock();
      expect(app.hasPin, isFalse);
      await tester.pumpWidget(MaterialApp(home: HomeShell(app: app)));
      await tester.pump();

      expect(find.byTooltip('今すぐロック'), findsOneWidget);
      await tester.tap(find.byTooltip('今すぐロック'));
      await tester.pump();
      expect(app.locked, isTrue);
    });

    testWidgets('ロックできない時は無反応にせず理由を出す', (tester) async {
      final app = await _connected(auth: _FakeAuth(available: false));
      app.unlock();
      await tester.pumpWidget(MaterialApp(home: HomeShell(app: app)));
      await tester.pump();

      await tester.tap(find.byTooltip('今すぐロック'));
      await tester.pump();
      expect(app.locked, isFalse);
      expect(find.textContaining('画面ロックがありません'), findsOneWidget);
    });
  });

  // 指摘1: ロックは積んだ画面（再生画面・シート・ダイアログ）ごと覆う
  group('ロックは Navigator の上に被せる', () {
    Future<(AppState, _FakeSecureWindow)> pumpApp(WidgetTester tester,
        {_FakeAuth? auth}) async {
      // 認証ダイアログが即通るとロック画面を確かめられんので、既定は失敗させる
      final app = await _connected(auth: auth ?? _FakeAuth(verifyResult: false));
      app.unlock();
      final secure = _FakeSecureWindow();
      await tester.pumpWidget(R2GalleryApp(
          app: app, secureWindow: secure, listenDeepLinks: false));
      await tester.pump();
      return (app, secure);
    }

    Future<void> pushSecret(WidgetTester tester, {VoidCallback? onTap}) async {
      tester.state<NavigatorState>(find.byType(Navigator)).push(
          MaterialPageRoute<void>(
              builder: (_) => Scaffold(
                    body: Center(
                        child: TextButton(
                            onPressed: onTap, child: const Text('SECRET'))),
                  )));
      await tester.pumpAndSettle();
      expect(find.text('SECRET'), findsOneWidget);
    }

    testWidgets('転送中に画面を消され、開き直した時はロック画面から始まる', (tester) async {
      final (app, _) = await pumpApp(tester);
      await pushSecret(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(app.locked, isTrue);
      expect(find.text('ロック中'), findsOneWidget);
      expect(find.text('SECRET'), findsNothing);
    });

    testWidgets('上に積んだ画面もロックで見えなくなり、触れなくなる', (tester) async {
      final (app, _) = await pumpApp(tester);
      var taps = 0;
      await pushSecret(tester, onTap: () => taps++);

      expect(app.lockNow(), isTrue);
      await tester.pumpAndSettle();

      expect(find.text('ロック中'), findsOneWidget);
      expect(find.text('SECRET'), findsNothing);
      await tester.tap(find.text('SECRET', skipOffstage: false),
          warnIfMissed: false);
      expect(taps, 0);
    });

    testWidgets('積んだダイアログもロックで見えなくなる', (tester) async {
      final (app, _) = await pumpApp(tester);
      showDialog<void>(
          context: tester.element(find.byType(Scaffold).first),
          builder: (_) => const AlertDialog(content: Text('DIALOG')));
      // 下のホームはライブラリ待ちのくるくるが回り続けるので、settle ではなく時間で進める
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('DIALOG'), findsOneWidget);

      app.lockNow();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('DIALOG'), findsNothing);
      expect(find.text('ロック中'), findsOneWidget);
    });

    testWidgets('ロックしても下の画面は捨てず、解除すると元の状態のまま戻る', (tester) async {
      final (app, _) = await pumpApp(tester);
      final key = GlobalKey<_CounterState>();
      tester.state<NavigatorState>(find.byType(Navigator)).push(
          MaterialPageRoute<void>(builder: (_) => _Counter(key: key)));
      await tester.pumpAndSettle();
      final before = key.currentState;
      before!.count = 7;
      // ホーム（選んだファイルやアップロード中のシートを持つ側）も捨てないこと
      final shell = tester.state(find.byType(HomeShell, skipOffstage: false));

      app.lockNow();
      await tester.pumpAndSettle();
      expect(shell.mounted, isTrue);
      app.unlock();
      await tester.pumpAndSettle();

      expect(key.currentState, same(before));
      expect(key.currentState!.count, 7);
      expect(
          tester.state(find.byType(HomeShell, skipOffstage: false)), same(shell));
    });

    testWidgets('ロックした瞬間に再生中の画面へ止めるよう知らせる', (tester) async {
      final (app, _) = await pumpApp(tester);
      final key = GlobalKey<_PausableState>();
      tester.state<NavigatorState>(find.byType(Navigator)).push(
          MaterialPageRoute<void>(builder: (_) => _Pausable(key: key)));
      await tester.pumpAndSettle();
      expect(key.currentState!.paused, 0);

      app.lockNow();
      await tester.pump();
      expect(key.currentState!.paused, 1);
      expect(key.currentState!.isAppLocked, isTrue);
    });
  });

  // 指摘2: アプリが開いたファイル選択から戻っただけでロックしない
  group('外部画面（ファイル選択）からの復帰', () {
    test('選択中に裏へ回って戻っても「毎回ロック」で即ロックしない', () async {
      final clock = _FakeClock();
      final app = await _connected(auth: _FakeAuth(), clock: clock);
      await app.setRelockGraceMs(0);
      app.unlock();

      // 端末では選択結果が先に返り、その後で前面復帰が届くことがある
      await app.runExternal(() async {
        app.onBackground();
        clock.advance(30000);
        return 'picked';
      });
      await app.onForeground();
      expect(app.locked, isFalse);

      // 外部画面を開いていない普通の裏回りは今まで通りロックする
      app.onBackground();
      clock.advance(1);
      await app.onForeground();
      expect(app.locked, isTrue);
    });

    test('選択画面を開いたまま長く放置されたらロックする', () async {
      final clock = _FakeClock();
      final app = await _connected(auth: _FakeAuth(), clock: clock);
      await app.setRelockGraceMs(0);
      app.unlock();

      await app.runExternal(() async {
        app.onBackground();
        clock.advance(externalActivityGraceMs + 1);
        await app.onForeground();
      });
      expect(app.locked, isTrue);
    });

    test('猶予が外部画面の下限より長ければ、そちらを使う', () {
      expect(effectiveGraceMs(graceMs: 0, duringExternal: true),
          externalActivityGraceMs);
      expect(effectiveGraceMs(graceMs: 0, duringExternal: false), 0);
      expect(
          effectiveGraceMs(
              graceMs: relockGraceDefaultMs, duringExternal: true),
          relockGraceDefaultMs);
    });
  });

  // 指摘3: 端末の画面ロックの問い合わせが失敗してもロックを外さない
  group('問い合わせの失敗ではロックを外さない', () {
    test('起動時に問い合わせが返らなくても、ロックしたまま抜け道を出さない', () async {
      final auth = _FakeAuth()..probeHangs = true;
      final app = await _connected(auth: auth);
      expect(app.locked, isTrue);
      expect(app.deviceLockProbe, DeviceLockProbe.unknown);
      // 「無い」と決めつけず、端末認証を試させる
      expect(app.deviceUnlockOffered, isTrue);
      expect(app.canLock, isTrue);
    });

    testWidgets('起動時に問い合わせが失敗したら「ロックなしで続ける」を出さない', (tester) async {
      final auth = _FakeAuth(verifyResult: false)..probeThrows = true;
      final app = await _connected(auth: auth);
      await tester.pumpWidget(MaterialApp(home: LockGate(app: app)));
      await tester.pumpAndSettle();

      expect(find.text('ロックなしで続ける'), findsNothing);
      expect(find.text('ロックを解除'), findsOneWidget);

      // 問い合わせが壊れていても認証そのものは通る端末なら、そのまま解除できる
      auth.verifyResult = true;
      await tester.tap(find.text('ロックを解除'));
      await tester.pumpAndSettle();
      expect(app.locked, isFalse);
    });

    test('前面復帰ではまずロックし、問い合わせはその後。時間切れでもロックのまま', () async {
      final clock = _FakeClock();
      final auth = _FakeAuth();
      final app = await _connected(auth: auth, clock: clock);
      app.unlock();
      app.onBackground();
      clock.advance(relockGraceDefaultMs + 1);
      auth.probeHangs = true;

      final done = app.onForeground();
      // 問い合わせ（最大3秒）を待たずにロックがかかっている
      await Future<void>.delayed(Duration.zero);
      expect(app.locked, isTrue);
      await done;
      expect(app.locked, isTrue);
    });

    test('問い合わせがエラーでも、前に使えた端末なら使える扱いのまま', () async {
      final auth = _FakeAuth();
      final app = await _connected(auth: auth);
      expect(app.deviceLockProbe, DeviceLockProbe.available);
      auth.probeThrows = true;
      await app.refreshDeviceLockAvailable();
      expect(app.deviceLockProbe, DeviceLockProbe.available);
      app.unlock();
      expect(app.lockNow(), isTrue);
    });

    test('問い合わせの結果が変わったら画面に知らせる', () async {
      final clock = _FakeClock();
      final auth = _FakeAuth();
      final app = await _connected(auth: auth, clock: clock);
      app.unlock();
      var notified = 0;
      app.addListener(() => notified++);
      app.onBackground();
      clock.advance(1000);
      auth.available = false;
      await app.onForeground();
      expect(app.deviceLockAvailable, isFalse);
      expect(notified, greaterThan(0));
    });
  });

  // 指摘4: 猶予は端末の時計を戻しても縮まない時計で測る。ロック中は窓を保護する
  group('猶予の時計と窓の保護', () {
    test('端末の時計を戻しても、起動からの経過で再ロックする', () async {
      final clock = _FakeClock();
      final app = await _connected(auth: _FakeAuth(), clock: clock);
      app.unlock();
      app.onBackground();
      clock.advance(relockGraceDefaultMs + 1);
      clock.wall -= relockGraceDefaultMs * 3;
      await app.onForeground();
      expect(app.locked, isTrue);
    });

    test('起動からの経過が取れない環境では、Stopwatch と壁時計の長い方で測る', () {
      ClockReading r(int mono, int wall) => (boot: null, mono: mono, wall: wall);
      // 時計を戻された: Stopwatch 側で数える
      expect(elapsedBetween(r(0, 5000000), r(4000000, 1000000)), 4000000);
      // スリープで Stopwatch が止まった: 壁時計側で数える
      expect(elapsedBetween(r(0, 1000000), r(10, 5000000)), 4000000);
      // 両方取れる時は起動からの経過だけを信じる
      expect(
          elapsedBetween((boot: 100, mono: 0, wall: 99999999),
              (boot: 200, mono: 0, wall: 0)),
          100);
    });

    test('ロックを使っている間は窓を保護する', () async {
      final app = await _connected(auth: _FakeAuth());
      expect(app.wantsSecureWindow, isTrue);
      app.unlock();
      // 解除中も保護したまま（裏へ回った瞬間の画面を一覧に残さない）
      expect(app.wantsSecureWindow, isTrue);
      await app.setDeviceLockEnabled(false);
      expect(app.wantsSecureWindow, isFalse);
    });

    testWidgets('アプリは保護の要否が変わる度に窓へ伝える', (tester) async {
      final app = await _connected(auth: _FakeAuth(verifyResult: false));
      final secure = _FakeSecureWindow();
      await tester.pumpWidget(R2GalleryApp(
          app: app, secureWindow: secure, listenDeepLinks: false));
      await tester.pump();
      await app.setDeviceLockEnabled(false);
      await tester.pump();
      expect(secure.calls, [true, false]);
    });
  });
}

class _Counter extends StatefulWidget {
  const _Counter({super.key});
  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int count = 0;
  @override
  Widget build(BuildContext context) =>
      Scaffold(body: Text('count $count'));
}

class _Pausable extends StatefulWidget {
  const _Pausable({super.key});
  @override
  State<_Pausable> createState() => _PausableState();
}

class _PausableState extends State<_Pausable> with PauseOnLock {
  int paused = 0;
  @override
  void onLocked() => paused++;
  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('PLAYING'));
}
