import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/state/app_state.dart';
import 'package:r2_gallery/src/store/kv.dart';

class _LibApi extends ApiClient {
  int libraryCalls = 0;
  bool fail = false;

  @override
  Future<List<Library>> libraries() async {
    libraryCalls++;
    if (fail) throw const ApiError(0, 'offline');
    return const [Library(id: 'review', title: 'review')];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({
        Keys.endpoint: 'https://saved.example',
        Keys.token: 'saved',
        Keys.pinHash: 'abcd',
      }));

  test('PIN ロック中でもライブラリ一覧は先に取っておく', () async {
    final api = _LibApi();
    final app = AppState(api: api, bakedEndpoint: '', bakedToken: '');
    await app.init();
    await Future<void>.delayed(Duration.zero);

    expect(app.locked, isTrue);
    expect(api.libraryCalls, 1);
    expect(app.activeLib, 'review');
  });

  test('解除時、先読みが通っていれば取り直さない', () async {
    final api = _LibApi();
    final app = AppState(api: api, bakedEndpoint: '', bakedToken: '');
    await app.init();
    await Future<void>.delayed(Duration.zero);
    app.unlock();
    await Future<void>.delayed(Duration.zero);

    expect(api.libraryCalls, 1);
  });

  test('先読みが圏外で空のままなら、解除時にもう一度取る', () async {
    final api = _LibApi()..fail = true;
    final app = AppState(api: api, bakedEndpoint: '', bakedToken: '');
    await app.init();
    await Future<void>.delayed(Duration.zero);
    expect(app.libraries, isEmpty);

    api.fail = false;
    app.unlock();
    await Future<void>.delayed(Duration.zero);

    expect(api.libraryCalls, 2);
    expect(app.activeLib, 'review');
  });
}
