import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/state/app_state.dart';
import 'package:r2_gallery/src/store/kv.dart';

class _FakeApi extends ApiClient {
  _FakeApi(this.probeResult);
  final bool probeResult;
  int probes = 0;

  @override
  Future<bool> probe(String endpoint, String token) async {
    probes++;
    return probeResult;
  }

  @override
  Future<List<Library>> libraries() async => const [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('保存済みの接続が無く埋め込み値が通れば、入力なしで接続して保存する', () async {
    final api = _FakeApi(true);
    final app = AppState(
      api: api,
      bakedEndpoint: 'https://w.example',
      bakedToken: 'tk',
    );
    await app.init();

    expect(app.connected, isTrue);
    expect(app.bakedProbeFailed, isFalse);
    expect(api.conn?.endpoint, 'https://w.example');
    expect(await Kv.get(Keys.endpoint), 'https://w.example');
    expect(await Kv.get(Keys.token), 'tk');
  });

  test('埋め込み値で繋がらなければ保存せず接続画面に理由を出す', () async {
    final app = AppState(
      api: _FakeApi(false),
      bakedEndpoint: 'https://w.example',
      bakedToken: 'tk',
    );
    await app.init();

    expect(app.connected, isFalse);
    expect(app.bakedProbeFailed, isTrue);
    expect(await Kv.get(Keys.token), isNull);
  });

  test('保存済みの接続があれば埋め込み値は試さない', () async {
    FlutterSecureStorage.setMockInitialValues({
      Keys.endpoint: 'https://saved.example',
      Keys.token: 'saved',
    });
    final api = _FakeApi(true);
    final app = AppState(
      api: api,
      bakedEndpoint: 'https://w.example',
      bakedToken: 'tk',
    );
    await app.init();

    expect(api.probes, 0);
    expect(api.conn?.endpoint, 'https://saved.example');
  });

  bakedRaceTests();

  test('埋め込み値が空なら何もせず接続画面のまま', () async {
    final api = _FakeApi(true);
    final app = AppState(api: api, bakedEndpoint: '', bakedToken: '');
    await app.init();

    expect(api.probes, 0);
    expect(app.connected, isFalse);
    expect(app.bakedProbeFailed, isFalse);
  });
}

class _SlowFakeApi extends _FakeApi {
  _SlowFakeApi() : super(true);
  final gate = Completer<void>();

  @override
  Future<bool> probe(String endpoint, String token) async {
    probes++;
    if (endpoint == 'https://w.example') await gate.future;
    return true;
  }
}

void bakedRaceTests() {
  test('埋め込み値を確かめている間にペアリングで繋いだら、そちらを上書きしない', () async {
    final api = _SlowFakeApi();
    final app = AppState(
      api: api,
      bakedEndpoint: 'https://w.example',
      bakedToken: 'tk',
    );
    final init = app.init();
    final err = await app.connect('https://paired.example', 'paired');
    expect(err, isNull);
    api.gate.complete();
    await init;

    expect(api.conn?.endpoint, 'https://paired.example');
    expect(await Kv.get(Keys.endpoint), 'https://paired.example');
    expect(await Kv.get(Keys.token), 'paired');
  });
}
