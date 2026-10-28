import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/main.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/state/app_state.dart';
import 'package:r2_gallery/src/state/pairing.dart';
import 'package:r2_gallery/src/state/write_guard.dart';
import 'package:r2_gallery/src/store/device_auth.dart';
import 'package:r2_gallery/src/store/kv.dart';
import 'package:r2_gallery/src/store/lock_platform.dart';
import 'package:r2_gallery/src/ui/connect_screen.dart';
import 'package:r2_gallery/src/ui/gallery_tab.dart';
import 'package:r2_gallery/src/ui/home_shell.dart';
import 'package:r2_gallery/src/ui/import_browser_tab.dart';
import 'package:r2_gallery/src/ui/settings_tab.dart';
import 'package:r2_gallery/src/ui/trash_tab.dart';

/// 通信の代わり。probe に渡った値と、書き込み系が呼ばれたかを覚える
class _Api extends ApiClient {
  _Api({List<Library>? libs})
    : libs = libs ?? const [Library(id: 'review', title: 'Review')];
  bool probeOk = true;
  List<Library> libs;
  final probes = <(String, String)>[];
  int libraryCalls = 0;
  Object? librariesError;
  final restored = <String>[];

  @override
  Future<bool> probe(String endpoint, String token) async {
    probes.add((endpoint, token));
    return probeOk;
  }

  @override
  Future<List<Library>> libraries() async {
    libraryCalls++;
    final err = librariesError;
    if (err != null) throw err;
    return libs;
  }

  @override
  Future<FolderPage> folder(
    String libId, {
    String prefix = '',
    String? cursor,
    bool recursive = false,
  }) async => const FolderPage(items: []);

  @override
  Future<TrashPage> trashList(String libId, {String? cursor}) async =>
      const TrashPage([
        TrashItem(trashKey: 't1', key: 'a.jpg', deletedAt: 0, size: 1),
      ], null);

  @override
  Future<String> restore(String libId, String trashKey) async {
    restored.add(trashKey);
    return 'a.jpg';
  }
}

class _NoAuth implements DeviceAuth {
  @override
  Future<bool> isAvailable() async => false;
  @override
  Future<bool> verify(String reason) async => false;
}

class _Window implements SecureWindow {
  @override
  Future<void> setSecure(bool on) async {}
}

AppState _app(_Api api) => AppState(
  api: api,
  bakedEndpoint: '',
  bakedToken: '',
  deviceAuth: _NoAuth(),
  isWeb: false,
);

Future<void> _tapVisible(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pump();
  await tester.tap(f);
}

Widget _shell(AppState app) =>
    R2GalleryApp(app: app, secureWindow: _Window(), listenDeepLinks: false);

// ロックの話はこのファイルでは扱わないので、端末ロックは切った状態から始める
void _seed([Map<String, String> extra = const {}]) =>
    FlutterSecureStorage.setMockInitialValues({Keys.deviceLock: '0', ...extra});

const _toolPairing =
    'r2g://setup?e=https%3A%2F%2Fw.example%2Fsub#tok%2Bx%2F%3D';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => _seed());

  group('S1 ペアリングリンク', () {
    test('tools/pairing-url.mjs の出力を読める', () {
      final p = parsePairingString(_toolPairing);
      expect(p?.endpoint, 'https://w.example/sub');
      expect(p?.token, 'tok+x/=');
    });

    test('作った文字列はそのまま読み戻せる', () {
      final s = buildPairingString('https://w.example/x/', 'a b+c');
      final p = parsePairingString(s);
      expect(p?.endpoint, 'https://w.example/x');
      expect(p?.token, 'a b+c');
    });

    test('崩れた文字列は例外にせず null', () {
      for (final bad in [
        'r2g://setup?e=https%3A%2F%2Fw.example', // トークンが無い
        'r2g://setup?e=https%3A%2F%2Fw.example#', // トークンが空
        'r2g://other?e=https%3A%2F%2Fw.example#t', // ホスト違い
        'r2g://setup?e=http%3A%2F%2Fw.example#t', // https でない
        'r2g://setup?e=https%3A%2F%2Fu%3Ap%40w.example#t', // 認証情報入り
        'r2g://setup?e=https%3A%2F%2Fw.example#t%ZZ', // 壊れたエスケープ
        'https://w.example#t',
        '',
      ]) {
        expect(parsePairingString(bad), isNull, reason: bad);
      }
    });

    test('リンクで開くと、その接続先とトークンで繋ぐ', () async {
      final api = _Api();
      final app = _app(api);
      final ok = await app.connectFromUri(Uri.parse(_toolPairing));
      expect(ok, isTrue);
      expect(api.probes.single, ('https://w.example/sub', 'tok+x/='));
      expect(app.connected, isTrue);
      expect(await Kv.get(Keys.token), 'tok+x/=');
    });

    test('以前の Flutter 版の endpoint/token 形式も受ける', () async {
      final api = _Api();
      final app = _app(api);
      final ok = await app.connectFromUri(
        Uri.parse('r2g://setup?endpoint=https%3A%2F%2Fw.example&token=tk'),
      );
      expect(ok, isTrue);
      expect(api.probes.single, ('https://w.example', 'tk'));
    });

    test('読めないリンクでは何も試さない', () async {
      final api = _Api();
      final ok = await _app(api).connectFromUri(Uri.parse('r2g://setup?x=1'));
      expect(ok, isFalse);
      expect(api.probes, isEmpty);
    });
  });

  group('S2 ペアリング文字列の貼り付け', () {
    testWidgets('トークン欄に貼ると両方の欄が埋まり、そのまま接続できる', (tester) async {
      final api = _Api();
      final app = _app(api);
      await tester.pumpWidget(MaterialApp(home: ConnectScreen(app: app)));

      await tester.enterText(
        find.widgetWithText(TextField, 'アクセストークン'),
        _toolPairing,
      );
      await tester.pump();
      expect(find.text('https://w.example/sub'), findsOneWidget);

      await _tapVisible(tester, find.text('接続する'));
      await tester.pumpAndSettle();
      expect(api.probes.single, ('https://w.example/sub', 'tok+x/='));
      expect(app.connected, isTrue);
    });
  });

  group('S3 接続入力の補正', () {
    test('ホスト名だけ・末尾スラッシュ・トークンの改行を補って繋ぐ', () async {
      final api = _Api();
      final app = _app(api);
      final err = await app.connect('  w.example/sub/ ', ' tk\n');
      expect(err, isNull);
      expect(api.probes.single, ('https://w.example/sub', 'tk'));
      expect(await Kv.get(Keys.endpoint), 'https://w.example/sub');
      expect(await Kv.get(Keys.token), 'tk');
    });

    test('http は平文でトークンが流れるので試さずに断る', () async {
      final api = _Api();
      final err = await _app(api).connect('http://w.example', 'tk');
      expect(err, 'エンドポイントは https:// で始めてください');
      expect(api.probes, isEmpty);
    });

    test('トークンが空白だけなら試さない', () async {
      final api = _Api();
      final err = await _app(api).connect('https://w.example', '  \n');
      expect(err, connectFailedMessage);
      expect(api.probes, isEmpty);
    });

    test('表示用のホスト名は userinfo もパスも落とす', () {
      expect(hostOf('https://w.example/sub?x=1'), 'w.example');
      expect(hostOf('https://user:se/cret@w.example/p'), 'w.example');
    });
  });

  group('S4 読み取り専用への書き込みを止める', () {
    const libs = [
      Library(id: 'rw', title: 'RW'),
      Library(id: 'ro', title: 'RO', readOnly: true),
    ];
    String? block(String? lib, WriteAction a, {bool connected = true}) =>
        writeBlockMessage(
          connected: connected,
          libraries: libs,
          lib: lib,
          action: a,
        );

    test('操作ごとに KMP 版と同じ文言で止める', () {
      expect(block('rw', WriteAction.upload), isNull);
      expect(block('ro', WriteAction.upload), 'このライブラリは読み取り専用なので、アップロードできません。');
      expect(block('ro', WriteAction.save), 'このライブラリは読み取り専用なので、保存できません。');
      expect(block('ro', WriteAction.restore), 'このライブラリは読み取り専用のため、戻せません');
      expect(block('ro', WriteAction.trash), 'このライブラリは読み取り専用です');
      // 一覧に無いものは、読み取り専用か分からないので書かせない
      expect(
        block('gone', WriteAction.edit),
        '接続先にライブラリが見つかりません。接続先と権限を確認してください。',
      );
      expect(block(null, WriteAction.edit), isNotNull);
      expect(block('rw', WriteAction.edit, connected: false), '保存先が未接続です。');
    });

    // #146（H10）で、読み取り専用では追加の入口そのものを出さなくなった。入口が無いことを確かめる
    testWidgets('読み取り専用ライブラリでは追加の＋も「写真・動画を追加」も出さない', (tester) async {
      final app = _app(_Api())
        ..connected = true
        ..libraries = libs;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GalleryTab(app: app, lib: 'ro'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.text('写真・動画を追加'), findsNothing);
    });

    testWidgets('読み取り専用ライブラリのゴミ箱では復元を送らず理由を出す', (tester) async {
      final api = _Api();
      final app = _app(api)
        ..connected = true
        ..libraries = libs;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TrashTab(app: app, lib: 'ro'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // #148 以降、読み取り専用のゴミ箱は一覧も復元ボタンも出さず、理由だけを出す
      expect(find.text('読み取り専用のライブラリです'), findsOneWidget);
      expect(find.text('a.jpg'), findsNothing);
      expect(find.text('復元'), findsNothing);
      expect(api.restored, isEmpty);
    });

    testWidgets('書けるライブラリなら復元は通る', (tester) async {
      final api = _Api();
      final app = _app(api)
        ..connected = true
        ..libraries = libs;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TrashTab(app: app, lib: 'rw'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('a.jpg'));
      await tester.pump();
      await tester.tap(find.text('復元'));
      await tester.pumpAndSettle();
      expect(api.restored, ['t1']);
    });
  });

  group('S6 ロックの設定', () {
    testWidgets('再ロックまでの時間を選ぶと保存され、行にも出る', (tester) async {
      final app = _app(_Api());
      await app.init();
      // 実アプリでは上の画面が AppState の変化で作り直す。単体でも同じく作り直させる
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: app,
              builder: (_, _) => SettingsTab(app: app),
            ),
          ),
        ),
      );
      await tester.tap(find.text('再ロックまでの時間'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('10分'));
      await tester.pumpAndSettle();
      expect(app.relockGraceMs, 600000);
      expect(await Kv.get(Keys.lockGraceMs), '600000');
      expect(find.text('10分'), findsOneWidget);
    });
  });

  group('S8 接続状態', () {
    testWidgets('接続中はホスト名とライブラリ数だけ出し、URL 全体やトークンは出さない', (tester) async {
      final api = _Api(
        libs: const [
          Library(id: 'a', title: 'A'),
          Library(id: 'b', title: 'B'),
        ],
      );
      final app = _app(api);
      await app.connect('https://w.example/very/long/path', 'secret-token');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SettingsTab(app: app)),
        ),
      );
      expect(find.text('接続中'), findsOneWidget);
      expect(find.text('w.example · ライブラリ 2'), findsOneWidget);
      expect(find.textContaining('secret-token'), findsNothing);
      expect(find.textContaining('/very/long'), findsNothing);
    });

    testWidgets('未接続ならそう出し、タップで接続画面へ戻れる', (tester) async {
      final app = _app(_Api())..skipConnect();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SettingsTab(app: app)),
        ),
      );
      expect(find.text('未接続'), findsOneWidget);
      expect(find.text('切断'), findsNothing);
      await tester.tap(find.text('未接続'));
      expect(app.browseOnly, isFalse);
    });
  });

  group('S9 起動失敗バナー', () {
    testWidgets('ライブラリが取れなければ理由を出し、再試行で直れば消える', (tester) async {
      _seed({Keys.endpoint: 'https://w.example', Keys.token: 'tk'});
      final api = _Api()..librariesError = const ApiError(503, 'unavailable');
      final app = _app(api);
      await tester.pumpWidget(_shell(app));
      await app.init();
      await tester.pumpAndSettle();
      expect(find.textContaining('初期化に失敗: ライブラリを取得できませんでした'), findsOneWidget);
      // スピナーで固まらず、写真タブにも理由と再試行が出る
      expect(find.byType(CircularProgressIndicator), findsNothing);

      api.librariesError = null;
      await tester.tap(find.widgetWithText(TextButton, '再試行'));
      await tester.pumpAndSettle();
      expect(find.textContaining('初期化に失敗'), findsNothing);
      expect(app.activeLib, 'review');
    });

    testWidgets('閉じるで帯だけ消せる', (tester) async {
      _seed({Keys.endpoint: 'https://w.example', Keys.token: 'tk'});
      final api = _Api()..librariesError = const ApiError(0, 'offline');
      final app = _app(api);
      await tester.pumpWidget(_shell(app));
      await app.init();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('閉じる'));
      await tester.pumpAndSettle();
      expect(find.textContaining('初期化に失敗'), findsNothing);
    });

    test('起動処理が想定外のエラーで落ちても、読み込み中のまま止めず理由を出す', () async {
      final app = AppState(
        api: _Api(),
        bakedEndpoint: '',
        bakedToken: '',
        deviceAuth: _BrokenAuth(),
      );
      await app.init();
      expect(app.loading, isFalse);
      expect(app.startupError, contains('keystore wedged'));
    });

    test('一度取れた一覧は、取り直しに失敗しても手元のまま使い続ける', () async {
      _seed({Keys.endpoint: 'https://w.example', Keys.token: 'tk'});
      final api = _Api();
      final app = _app(api);
      await app.init();
      await pumpEventQueue();
      expect(app.libraries.length, 1);
      api.librariesError = const ApiError(0, 'offline');
      await app.retryStartup();
      expect(app.libraries.length, 1);
      expect(app.startupError, isNull);
    });

    test('起動時の失敗の説明にトークンを出さない', () {
      expect(
        describeStartupError(Exception('Authorization: Bearer abc123')),
        isNot(contains('abc123')),
      );
    });
  });

  group('S10 接続せずに取り込みだけ使う', () {
    testWidgets('スキップすると取り込みタブが開き、写真タブは接続画面に戻る', (tester) async {
      final app = _app(_Api());
      await tester.pumpWidget(_shell(app));
      await app.init();
      await tester.pumpAndSettle();
      expect(find.byType(ConnectScreen), findsOneWidget);

      await _tapVisible(tester, find.text('接続せずに取り込みだけ使う'));
      await tester.pumpAndSettle();
      expect(find.byType(HomeShell), findsOneWidget);
      expect(find.byType(ImportBrowserTab), findsOneWidget);
      expect(find.text('動画ページのURLを入力して移動'), findsOneWidget);

      await tester.tap(find.text('写真'));
      await tester.pumpAndSettle();
      expect(find.byType(ConnectScreen), findsOneWidget);

      // 写真タブの接続画面でスキップすると、取り込みタブへ戻る（行き止まりにしない）
      await _tapVisible(tester, find.text('接続せずに取り込みだけ使う'));
      await tester.pumpAndSettle();
      expect(find.text('動画ページのURLを入力して移動'), findsOneWidget);
    });

    testWidgets('写真タブの接続画面から繋ぐと、そのまま一覧に切り替わる', (tester) async {
      final api = _Api();
      final app = _app(api);
      await tester.pumpWidget(_shell(app));
      await app.init();
      await tester.pumpAndSettle();
      await _tapVisible(tester, find.text('接続せずに取り込みだけ使う'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('写真'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'エンドポイント'),
        'w.example',
      );
      await tester.enterText(find.widgetWithText(TextField, 'アクセストークン'), 'tk');
      await tester.pump();
      await _tapVisible(tester, find.text('接続する'));
      await tester.pumpAndSettle();
      expect(app.connected, isTrue);
      expect(app.browseOnly, isFalse);
      expect(find.byType(GalleryTab), findsOneWidget);
    });
  });

  group('S12 ライブラリ切替', () {
    testWidgets('読み取り専用のライブラリには鍵を付ける', (tester) async {
      _seed({Keys.endpoint: 'https://w.example', Keys.token: 'tk'});
      final app = _app(
        _Api(
          libs: const [
            Library(id: 'rw', title: 'Personal'),
            Library(id: 'ro', title: 'Shared', readOnly: true),
          ],
        ),
      );
      await tester.pumpWidget(_shell(app));
      await app.init();
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate((w) => w is Icon && w.semanticLabel == '読み取り専用'),
        findsOneWidget,
      );
      expect(
        find.ancestor(
          of: find.text('Shared'),
          matching: find.byType(ChoiceChip),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.ancestor(
            of: find.text('Shared'),
            matching: find.byType(ChoiceChip),
          ),
          matching: find.byIcon(Icons.lock),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.ancestor(
            of: find.text('Personal'),
            matching: find.byType(ChoiceChip),
          ),
          matching: find.byIcon(Icons.lock),
        ),
        findsNothing,
      );
    });

    test('最後に開いたライブラリが消えていたら、残っている先頭へ切り替える', () async {
      _seed({
        Keys.endpoint: 'https://w.example',
        Keys.token: 'tk',
        Keys.library: 'gone',
      });
      final app = _app(
        _Api(
          libs: const [
            Library(id: 'a', title: 'A'),
            Library(id: 'b', title: 'B'),
          ],
        ),
      );
      await app.init();
      await pumpEventQueue();
      expect(app.activeLib, 'a');
    });
  });
}

// Exception ではない失敗（端末側の不具合）を投げる認証
class _BrokenAuth implements DeviceAuth {
  @override
  Future<bool> isAvailable() async => throw StateError('keystore wedged');
  @override
  Future<bool> verify(String reason) async => false;
}
