import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/offline/offline_store.dart';
import 'package:r2_gallery/src/store/private_storage.dart';

import 'offline_store_test.dart' show MemKv;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('app.r2gallery/private-storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('非対応のbackendは全ての接続で保存・復号・削除を拒否し、秘密KVとfilesystemへ進まない', () async {
    final kv = MemKv();
    var directories = 0;
    final root = OfflineStore(kv: kv, forceUnsupported: true, dir: () async {
      directories++;
      throw StateError('must not access filesystem');
    });
    addTearDown(root.dispose);
    for (final store in [root, root.forAccount('synthetic-account')]) {
      final operations = <Future<dynamic> Function()>[
        () => store.saveBytes(lib: 'lib', key: 'fixture.jpg', type: 'image',
          name: 'fixture.jpg', plain: Uint8List.fromList([1])),
        () => store.readBytes('lib', 'fixture.jpg'), store.list, store.count,
        store.totalBytes, store.hasLegacyData, store.clear,
        () => store.remove('lib', 'fixture.jpg'),
      ];
      for (final operation in operations) {
        await expectLater(operation(), throwsUnsupportedError);
      }
    }
    expect(kv.values, isEmpty);
    expect(directories, 0);
  });

  test('iOSの保護設定を待つ間は暗号文を書かず、準備は並列でも1回にまとめる', () async {
    final gate = Completer<bool>();
    final seen = Completer<void>();
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'prepare');
      expect(call.arguments, isNull);
      calls++;
      if (!seen.isCompleted) seen.complete();
      return gate.future;
    });
    final policy = PrivateStoragePolicy(platform: TargetPlatform.iOS);
    final temp = await Directory.systemTemp.createTemp('r2g-backup-policy-');
    addTearDown(() => temp.delete(recursive: true));
    final old = File('${temp.path}/keep-existing')..writeAsStringSync('keep');
    final store = OfflineStore(
      kv: MemKv(),
      dir: () async {
        await policy.prepare();
        return temp;
      },
    ).forAccount('synthetic-account');
    addTearDown(store.dispose);
    final saving = store.saveBytes(
      lib: 'lib',
      key: 'fixture.jpg',
      type: 'image',
      name: 'fixture.jpg',
      plain: Uint8List.fromList([1, 2, 3]),
    );
    await seen.future;
    final concurrent = policy.prepare();
    expect(temp.listSync(), hasLength(1));
    gate.complete(true);
    await Future.wait([saving, concurrent]);
    expect(calls, 1);
    expect(await store.readBytes('lib', 'fixture.jpg'), [1, 2, 3]);
    expect(await old.readAsString(), 'keep');
  });

  test('iOSの失敗・未登録・falseを保護済みとせず、私的な診断を隠して再試行できる', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      calls++;
      if (calls == 1) {
        throw PlatformException(
          code: 'failed',
          message: '/private/path?token=fixture',
        );
      }
      if (calls == 2) return false;
      return true;
    });
    final policy = PrivateStoragePolicy(platform: TargetPlatform.iOS);
    for (var i = 0; i < 2; i++) {
      await expectLater(
        policy.prepare(),
        throwsA(
          isA<PrivateStorageError>().having(
            (e) => e.toString(),
            'message',
            'アプリ専用保存の保護設定を確認できませんでした',
          ),
        ),
      );
    }
    await policy.prepare();
    await policy.prepare();
    expect(calls, 3);
    messenger.setMockMethodCallHandler(channel, null);
    await expectLater(
      PrivateStoragePolicy(platform: TargetPlatform.iOS).prepare(),
      throwsA(isA<PrivateStorageError>()),
    );
  });

  test('Androidは設定ファイルでbackupを制御し、iOSチャネルや外部保存先へ渡さない', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      calls++;
      return true;
    });
    await PrivateStoragePolicy(platform: TargetPlatform.android).prepare();
    expect(calls, 0);
    await expectLater(
      privatePersistentDirectory('../public'),
      throwsArgumentError,
    );
  });
}
