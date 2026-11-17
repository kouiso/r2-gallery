import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/store/kv.dart';
import 'package:r2_gallery/src/store/private_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('既存Keychainの属性保護が完了するまで読まず、新規値も同期しない端末限定属性で扱う', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const policy = MethodChannel('app.r2gallery/private-storage');
    const secure = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var ready = false;
    var prepares = 0;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(policy, (_) async {
      prepares++;
      return ready;
    });
    messenger.setMockMethodCallHandler(secure, (call) async {
      calls.add(call);
      return call.method == 'read' ? 'synthetic-value' : null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(policy, null);
      messenger.setMockMethodCallHandler(secure, null);
    });
    await expectLater(
      Kv.get('r2g.offline.dek'),
      throwsA(isA<PrivateStorageError>()),
    );
    expect(calls, isEmpty);
    ready = true;
    expect(await Kv.get('r2g.offline.dek'), 'synthetic-value');
    await Kv.set('r2g.offline.manifest', 'synthetic-value');
    await Kv.remove('r2g.token');
    expect(prepares, 2);
    expect(calls.map((c) => c.method), ['read', 'write', 'delete']);
    for (final call in calls) {
      final options = (call.arguments as Map)['options'] as Map;
      expect(options['accessibility'], 'unlocked_this_device');
      expect(options['synchronizable'], 'false');
      expect(options['accountName'], 'flutter_secure_storage_service');
      expect(options.containsKey('groupId'), isFalse);
    }
  });
}
