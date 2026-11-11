import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/offline/offline_store.dart';
import 'package:r2_gallery/src/state/app_state.dart';
import 'package:r2_gallery/src/store/kv.dart';
import 'package:r2_gallery/src/transfer/transfer_api.dart';
import 'package:r2_gallery/src/transfer/transfer_queue.dart';

import 'offline_store_test.dart' show MemKv;

class _GatedTransfer extends Fake implements TransferApi {
  final seen = Completer<void>();
  final bytes = Completer<Uint8List>();
  @override
  Future<Uint8List> fetchBytes(String url,
      {CancelToken? cancelToken, void Function(int got, int total)? onProgress}) {
    if (!seen.isCompleted) seen.complete();
    return bytes.future;
  }
}

class _GatedLibraries extends ApiClient {
  final first = Completer<List<Library>>();
  final firstRequested = Completer<void>();
  int calls = 0;
  @override
  Future<bool> probe(String endpoint, String token) async => true;
  @override
  Future<List<Library>> libraries() {
    if (++calls == 1) {
      firstRequested.complete();
      return first.future;
    }
    return Future.value(const [Library(id: 'new-lib', title: 'New fixture')]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late OfflineStore root;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('r2g-private-offline-');
    final kv = MemKv();
    kv.values[OfflineStore.dekKey] = base64Encode(Uint8List(32));
    root = OfflineStore(kv: kv, dir: () async => tmp);
  });
  tearDown(() async => tmp.delete(recursive: true));

  Future<void> save(OfflineStore store) => store.saveBytes(
    lib: 'lib', key: 'a.jpg', type: 'image', name: 'a.jpg',
    plain: Uint8List.fromList([1, 2, 3]),
  );

  test('接続資格の切替・ログアウト・アプリロックで保存内容を見せず、旧データは消さない', () async {
    final api = ApiClient()..setConnection(
        const Connection('https://fixture.invalid', 'fixture-a'));
    final app = AppState(api: api, offline: root, bakedEndpoint: '', bakedToken: '')
      ..connected = true
      ..libraries = const [Library(id: 'lib', title: 'Fixture')];
    addTearDown(app.dispose);
    await save(root);
    final a = app.offline;
    await save(a);
    expect(await a.hasLegacyData(), isTrue);
    expect(await a.count(), 1);
    expect(app.isOffline('lib', 'a.jpg'), isTrue);
    expect(await app.offlineBytes('lib', 'a.jpg'), [1, 2, 3]);

    app.locked = true;
    expect(app.isOffline('lib', 'a.jpg'), isFalse);
    expect(await app.offlineBytes('lib', 'a.jpg'), isNull);
    app.locked = false;
    api.setConnection(const Connection('https://fixture.invalid', 'fixture-b'));
    expect(await app.offline.count(), 0);
    expect(await app.offlineBytes('lib', 'a.jpg'), isNull);
    expect(await a.readBytes('lib', 'a.jpg'), [1, 2, 3]);
    await app.disconnect();
    expect(app.offlineAccessible, isFalse);
    expect(await app.offlineBytes('lib', 'a.jpg'), isNull);
    expect(await root.count(), 1);
    expect(await a.count(), 1);
  });

  test('取得中にアカウントを替えても、新しいアカウントへ保存しない', () async {
    final api = _GatedTransfer();
    var account = 'account-a';
    final a = root.forAccount(account);
    final b = root.forAccount('account-b');
    final queue = TransferQueue(
      api: api, offline: root, persist: false,
      requireDownloadAccount: true,
      canUseOfflineAccount: (id, _) => id == account,
    );
    addTearDown(queue.dispose);
    await queue.restore();
    final tasks = await queue.enqueueDownloads('lib', const [
      MediaItem(key: 'a.jpg', type: 'image', url: 'https://fixture.invalid/a.jpg'),
    ], targetStore: a);
    await api.seen.future;
    account = 'account-b';
    api.bytes.complete(Uint8List.fromList([1, 2, 3]));
    await queue.idle();
    expect(queue.tasks, isEmpty);
    expect(queue.hasActiveWork, isFalse);
    expect(tasks.single.status, TransferStatus.error);
    expect(await a.count(), 0);
    expect(await b.count(), 0);

    account = 'account-a';
    queue.retry(tasks.single.id);
    await queue.idle();
    expect(tasks.single.status, TransferStatus.done);
    expect(await a.readBytes('lib', 'a.jpg'), [1, 2, 3]);
    expect(await b.count(), 0);
  });

  for (final oldFails in [false, true]) {
    test('旧接続の一覧${oldFails ? "失敗" : "応答"}が新接続の認可や表示を上書きしない', () async {
      final api = _GatedLibraries()..setConnection(
          const Connection('https://fixture.invalid', 'fixture-a'));
      final app = AppState(api: api, offline: root, bakedEndpoint: '', bakedToken: '')
        ..connected = true;
      addTearDown(app.dispose);
      final old = app.retryStartup();
      expect(api.calls, 1);
      expect(await app.connect('https://fixture.invalid', 'fixture-b'), isNull);
      expect(app.canReadOffline('new-lib'), isTrue);
      expect(app.canReadOffline('old-lib'), isFalse);
      if (oldFails) {
        api.first.completeError(const ApiError(0, 'fixture failure'));
      } else {
        api.first.complete(const [Library(id: 'old-lib', title: 'Old fixture')]);
      }
      await old;
      expect(app.libraries.single.id, 'new-lib');
      expect(app.activeLib, 'new-lib');
      expect(app.startupError, isNull);
      expect(app.librariesLoading, isFalse);
      expect(app.canReadOffline('old-lib'), isFalse);
    });
  }

  test('ログアウトは資格情報の削除完了を待つ前に表示と読出しを閉じる', () async {
    final api = ApiClient()..setConnection(
        const Connection('https://fixture.invalid', 'fixture-a'));
    final app = AppState(api: api, offline: root, bakedEndpoint: '', bakedToken: '')
      ..connected = true;
    addTearDown(app.dispose);
    var notifiedClosed = false;
    app.addListener(() { notifiedClosed = !app.offlineAccessible; });
    final signingOut = app.disconnect();
    expect(notifiedClosed, isTrue);
    expect(app.offlineAccessible, isFalse);
    expect(api.conn, isNull);
    await signingOut;
  });


  test('切替通知からログアウトしても古い資格情報が後から保存されない', () async {
    final api = _GatedLibraries();
    final app = AppState(api: api, offline: root, bakedEndpoint: '', bakedToken: '');
    addTearDown(app.dispose);
    Future<void>? logout;
    app.addListener(() {
      if (!app.connected && logout == null) {
        // disconnect 自身の通知からの再入を避ける。
        logout = Future<void>.value();
        logout = app.disconnect();
      }
    });
    expect(await app.connect('https://fixture.invalid', 'fixture-a'), isNotNull);
    await logout;
    expect(app.connected, isFalse);
    expect(await Kv.get(Keys.endpoint), isNull);
    expect(await Kv.get(Keys.token), isNull);
    expect(api.calls, 0);
  });


  test('一覧待ちでログアウトした接続は成功を返さず資格も復活しない', () async {
    final api = _GatedLibraries();
    final app = AppState(api: api, offline: root, bakedEndpoint: '', bakedToken: '');
    addTearDown(app.dispose);
    final connecting = app.connect('https://fixture.invalid', 'fixture-a');
    await api.firstRequested.future;
    await app.disconnect();
    api.first.complete(const [Library(id: 'old-lib', title: 'Old fixture')]);
    expect(await connecting, isNotNull);
    expect(app.connected, isFalse);
    expect(app.libraries, isEmpty);
    expect(await Kv.get(Keys.endpoint), isNull);
    expect(await Kv.get(Keys.token), isNull);
  });

}
