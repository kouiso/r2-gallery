// 手元の worker（wrangler dev --local）に対して、本物の画面と ApiClient で
// 複数選択→ゴミ箱→元に戻す を通す確認用。fake API のテストでは届かない
// 「POST /ops/trash が本当に Worker の中身を動かすか」を見るため。
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/state/app_state.dart';
import 'package:r2_gallery/src/ui/home_shell.dart';
import 'package:r2_gallery/src/ui/media_tile.dart';

const _endpoint = String.fromEnvironment('LIVE_ENDPOINT',
    defaultValue: 'http://127.0.0.1:8787');
const _token = String.fromEnvironment('LIVE_TOKEN', defaultValue: 'live-token');

// flutter_test は HttpClient を差し替えて外へ出さない。Dio だけ素の HttpClient を使わせる
class _Real extends HttpOverrides {}

ApiClient _liveApi() {
  final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 10)))
    ..httpClientAdapter =
        IOHttpClientAdapter(createHttpClient: () => _Real().createHttpClient(null));
  return ApiClient(dio: dio)..conn = const Connection(_endpoint, _token);
}

// 1x1 の PNG。中身は見ないので、拡張子つきのキーで一覧に出れば足りる
final _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==');
const _bulk = ['bulk/p0.png', 'bulk/p1.png', 'bulk/p2.png', 'bulk/p3.png'];

Finder _tile(String key) =>
    find.byWidgetPredicate((w) => w is MediaTile && w.item.key == key);

/// 本物の通信は fake の時計では進まないので、実時間を少し待っては描き直す
Future<void> _until(WidgetTester tester, bool Function() done,
    {String what = ''}) async {
  for (var i = 0; i < 100; i++) {
    if (done()) return;
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 100)));
    await tester.pump(const Duration(milliseconds: 50));
  }
  fail('待ちきれなかった: $what');
}

Future<List<String>> _keys(ApiClient api, String lib, String prefix) async {
  final p = await api.folder(lib, prefix: prefix, recursive: true);
  return [for (final i in p.items) i.key]..sort();
}

Future<AppState> _connectedApp(WidgetTester tester, ApiClient api, String lib) async {
  final libs = (await tester.runAsync(api.libraries))!;
  final app = AppState(api: api, bakedEndpoint: '', bakedToken: '')
    ..connected = true
    ..loading = false
    ..libraries = libs
    ..activeLib = lib;
  return app;
}

void main() {
  // サムネのディスクキャッシュが置き場所を聞く。ここでは中身を見ないので一時置き場を返すだけ
  setUp(() {
    final dir = Directory.systemTemp.createTempSync('r2g_live_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => dir.path);
    // 鍵まわりの保存先。この確認では PIN を使わないので「何も無い」を返す
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (call) async => call.method == 'readAll' ? <String, String>{} : null);
  });

  testWidgets('書けるライブラリ: 4枚を選んでゴミ箱へ→Worker から消え .trash に移る→元に戻すで戻る',
      (tester) async {
    final api = _liveApi();
    // 前回の実行が途中で落ちてゴミ箱に残っていても、同じ出発点から始める
    await tester.runAsync(() async {
      for (final t in (await api.trashList('a')).items) {
        await api.restore('a', t.trashKey);
      }
      final have = await _keys(api, 'a', 'bulk/');
      for (final k in _bulk) {
        if (!have.contains(k)) await api.putObject('a', k, _png, 'image/png');
      }
    });
    final before = (await tester.runAsync(() => _keys(api, 'a', 'bulk/')))!;
    debugPrint('LIVE a/bulk before: $before');
    expect(before, _bulk);

    final app = await _connectedApp(tester, api, 'a');
    expect(app.libraries.firstWhere((l) => l.id == 'a').readOnly, isFalse);
    await tester.pumpWidget(MaterialApp(home: HomeShell(app: app, initialTab: HomeShell.photosTab)));
    await _until(tester, () => _tile('bulk/p0.png').evaluate().isNotEmpty,
        what: '一覧の表示');

    await tester.longPress(_tile('bulk/p0.png'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('すべて選択'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('ゴミ箱へ'), findsOneWidget);
    await tester.tap(find.text('ゴミ箱へ'));
    await _until(tester, () => find.text('4件をゴミ箱に移しました').evaluate().isNotEmpty,
        what: 'ゴミ箱へ移した知らせ');

    final after = (await tester.runAsync(() => _keys(api, 'a', 'bulk/')))!;
    final trash = (await tester.runAsync(() => api.trashList('a')))!;
    debugPrint('LIVE a/bulk after trash: $after');
    debugPrint('LIVE a trash: ${[for (final t in trash.items) t.trashKey]}');
    expect(after, isEmpty);
    expect(trash.items.length, 4);
    expect(_tile('bulk/p0.png'), findsNothing);

    // 知らせが下から出てくる途中だと押せないので、出きるまで進める
    await tester.pump(const Duration(milliseconds: 800));
    await tester.tap(find.text('元に戻す'));
    await _until(tester, () => _tile('bulk/p3.png').evaluate().isNotEmpty,
        what: '元に戻した後の一覧');
    final restored = (await tester.runAsync(() => _keys(api, 'a', 'bulk/')))!;
    final trash2 = (await tester.runAsync(() => api.trashList('a')))!;
    debugPrint('LIVE a/bulk after undo: $restored, trash left ${trash2.items.length}');
    expect(restored, before);
    expect(trash2.items, isEmpty);
    // 通信の待ち上限などのタイマーを流し切ってから終える
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 30));
  });

  testWidgets('読み取り専用ライブラリ: 選択はできる（オフライン保存用）がゴミ箱・アルバムは出ない。API で直接送っても 403 で中身は残る',
      (tester) async {
    final api = _liveApi();
    final before = (await tester.runAsync(() => _keys(api, 'b', 'ro/')))!;
    debugPrint('LIVE b/ro before: $before');
    // 読み取り専用には API で置けないので、README の手順で wrangler から入れておく
    expect(before, ['ro/p0.png', 'ro/p1.png'],
        reason: 'test_live/README.md の手順で live-b に ro/p0.png・ro/p1.png を入れておく');

    final app = await _connectedApp(tester, api, 'b');
    expect(app.libraries.firstWhere((l) => l.id == 'b').readOnly, isTrue);
    await tester.pumpWidget(MaterialApp(home: HomeShell(app: app, initialTab: HomeShell.photosTab)));
    await _until(tester, () => _tile('ro/p0.png').evaluate().isNotEmpty,
        what: '一覧の表示');
    expect(find.byIcon(Icons.lock), findsOneWidget);

    await tester.longPress(_tile('ro/p0.png'));
    await tester.pump(const Duration(milliseconds: 300));
    // オフライン保存できる端末では、読み取り専用でも選択には入る（KMP 版と同じ）
    debugPrint('LIVE b offlineSupported=${app.offlineSupported} '
        'selecting=${find.textContaining('件を選択').evaluate().isNotEmpty} '
        'trashBtn=${find.text('ゴミ箱へ').evaluate().length} '
        'albumBtn=${find.text('アルバムへ').evaluate().length} '
        'offlineBtn=${find.text('オフライン').evaluate().length}');
    if (app.offlineSupported) {
      expect(find.text('1件を選択'), findsOneWidget);
      expect(find.text('オフライン'), findsOneWidget);
    } else {
      expect(find.textContaining('件を選択'), findsNothing);
    }
    expect(find.text('ゴミ箱へ'), findsNothing);
    expect(find.text('アルバムへ'), findsNothing);

    final err = (await tester.runAsync(() async {
      try {
        await api.trash('b', 'ro/p0.png');
        return null;
      } on ApiError catch (e) {
        return e;
      }
    }));
    debugPrint('LIVE b direct trash -> ${err?.status} ${err?.message}');
    expect(err?.status, 403);
    final after = (await tester.runAsync(() => _keys(api, 'b', 'ro/')))!;
    debugPrint('LIVE b/ro after: $after');
    expect(after, before);
    // 通信の待ち上限などのタイマーを流し切ってから終える
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 30));
  });
}
