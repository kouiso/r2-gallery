import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/state/app_state.dart';
import 'package:r2_gallery/src/store/kv.dart';

/// 回線の答えを好きな速さで返せるライブラリ取得。
class _LibApi extends ApiClient {
  _LibApi(this.netLibs);
  List<Library> netLibs;
  final gate = Completer<void>();
  var callCount = 0;

  @override
  Future<List<Library>> libraries() async {
    callCount++;
    await gate.future;
    return netLibs;
  }
}

/// 接続の確かめ（probe）が通り、ライブラリもすぐ返す API。
class _BakedApi extends ApiClient {
  _BakedApi(this.netLibs);
  final List<Library> netLibs;

  @override
  Future<bool> probe(String endpoint, String token) async => true;

  @override
  Future<List<Library>> libraries() async => netLibs;
}

Map<String, dynamic> _snap(
        String endpoint, List<Map<String, dynamic>> libs, String? active) =>
    {'v': 1, 'endpoint': endpoint, 'activeLib': active, 'libraries': libs};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('保存済み接続の起動で、回線の答えを待たず控えの一覧を出す', () async {
    FlutterSecureStorage.setMockInitialValues({
      Keys.endpoint: 'https://w.example',
      Keys.token: 'tk',
      Keys.library: 'photos',
      Keys.libraries: jsonEncode(_snap('https://w.example', [
        {'id': 'photos', 'title': '写真', 'readOnly': false},
        {'id': 'work', 'title': '仕事', 'readOnly': true},
      ], 'photos')),
    });
    final api = _LibApi(const [Library(id: 'net', title: 'Net')]);
    final app = AppState(api: api, bakedEndpoint: '', bakedToken: '');

    await app.init();
    // 回線の答え（gate 待ち）より先に控えが出ている
    expect(app.libraries.map((l) => l.id), ['photos', 'work']);
    expect(app.activeLib, 'photos');
    expect(app.librariesFromNet, isFalse);

    api.gate.complete();
    await pumpEventQueue();
    expect(app.librariesFromNet, isTrue);
    expect(app.libraries.single.id, 'net');
    // 新しい答えは次の起動のために控え直す
    final saved = jsonDecode((await Kv.get(Keys.libraries))!) as Map;
    expect((saved['libraries'] as List).single['id'], 'net');
    expect(saved['activeLib'], 'net');
  });

  test('違う接続先の控えは戻さない', () async {
    FlutterSecureStorage.setMockInitialValues({
      Keys.endpoint: 'https://w.example',
      Keys.token: 'tk',
      Keys.libraries: jsonEncode(_snap('https://other.example', [
        {'id': 'stale', 'title': '古い', 'readOnly': false},
      ], 'stale')),
    });
    final api = _LibApi(const [Library(id: 'net', title: 'Net')]);
    final app = AppState(api: api, bakedEndpoint: '', bakedToken: '');

    await app.init();
    expect(app.libraries, isEmpty);
    api.gate.complete();
    await pumpEventQueue();
    expect(app.libraries.single.id, 'net');
    expect(app.librariesFromNet, isTrue);
  });

  test('接続を外すと控えを捨てる', () async {
    FlutterSecureStorage.setMockInitialValues({
      Keys.endpoint: 'https://w.example',
      Keys.token: 'tk',
      Keys.libraries: jsonEncode(_snap('https://w.example', [
        {'id': 'photos', 'title': '写真', 'readOnly': false},
      ], 'photos')),
    });
    final api = _LibApi(const [Library(id: 'net', title: 'Net')]);
    final app = AppState(api: api, bakedEndpoint: '', bakedToken: '');
    await app.init();
    api.gate.complete();
    await pumpEventQueue();
    expect(await Kv.get(Keys.libraries), isNotNull);

    await app.disconnect();
    await pumpEventQueue();
    expect(await Kv.get(Keys.libraries), isNull);
    expect(app.libraries, isEmpty);
    expect(app.connected, isFalse);
  });

  test('控えだけで起動し、起動の取得がまだ終わっていなければ解除で重ねて頼まずその答えを使う', () async {
    FlutterSecureStorage.setMockInitialValues({
      Keys.endpoint: 'https://w.example',
      Keys.token: 'tk',
      Keys.libraries: jsonEncode(_snap('https://w.example', [
        {'id': 'photos', 'title': '写真', 'readOnly': false},
      ], 'photos')),
    });
    final api = _LibApi(const [Library(id: 'net', title: 'Net')]);
    final app = AppState(api: api, bakedEndpoint: '', bakedToken: '');
    await app.init();
    api.gate.complete();
    await pumpEventQueue();
    expect(app.librariesFromNet, isTrue);

    // 回線の答えが来ていない状態（控えのみ）を作り直す
    final api2 = _LibApi(const [Library(id: 'net', title: 'Net')]);
    final app2 = AppState(api: api2, bakedEndpoint: '', bakedToken: '');
    await app2.init();
    expect(app2.librariesFromNet, isFalse);
    final before = api2.callCount;
    app2.unlock();
    // 取得中に頼み直すと世代が進んで先の答えが捨てられ、同じ要求が2本飛んでいた。
    // 起動の取得が失敗していた時の取り直しは resume_resign_test の
    // 「控えだけで起動して一覧を取れていなければ、前面へ戻った時に取り直す」が見る
    api2.gate.complete();
    await pumpEventQueue();
    expect(api2.callCount, before);
    expect(app2.librariesFromNet, isTrue);
  });

  test('焼き込み接続の初回でも、取れた一覧を控えに書く', () async {
    // 焼き込みの接続は _lastEndpoint を入れず、控えが黙って書かれなかった（次の起動で libs.cached が出ない）
    final api = _BakedApi(const [Library(id: 'net', title: 'Net')]);
    final app = AppState(
        api: api, bakedEndpoint: 'https://baked.example', bakedToken: 'tk');

    await app.init();
    expect(app.connected, isTrue);
    await pumpEventQueue();
    expect(app.librariesFromNet, isTrue);
    final saved = jsonDecode((await Kv.get(Keys.libraries))!) as Map;
    expect(saved['endpoint'], 'https://baked.example');
    expect(saved['activeLib'], 'net');
    expect((saved['libraries'] as List).single['id'], 'net');
  });

  test('手入力の接続（connect）の初回でも、取れた一覧を控えに書く', () async {
    final api = _BakedApi(const [Library(id: 'net', title: 'Net')]);
    final app = AppState(api: api, bakedEndpoint: '', bakedToken: '');
    await app.init();

    expect(await app.connect('https://manual.example', 'tk'), isNull);
    await pumpEventQueue();
    final saved = jsonDecode((await Kv.get(Keys.libraries))!) as Map;
    expect(saved['endpoint'], 'https://manual.example');
    expect((saved['libraries'] as List).single['id'], 'net');
  });
}
