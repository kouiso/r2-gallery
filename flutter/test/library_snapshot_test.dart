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

  test('控えだけで起動した時はロック解除で回線の一覧を取り直す', () async {
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
    api2.gate.complete();
    await pumpEventQueue();
    expect(api2.callCount, before + 1);
    expect(app2.librariesFromNet, isTrue);
  });
}
