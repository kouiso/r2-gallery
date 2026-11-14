import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/viewer/device_export.dart';

class _Api extends Fake implements ApiClient {}

class _Store implements MediaStoreBridge {
  int saves = 0;
  @override
  bool get supported => true;
  @override
  Future<void> save(String path, String displayName, String mime) async {
    saves++;
  }
}

void main() {
  test('古いexport APIを直接呼んでもbridge・一時平文・ネットワークへ進まない', () async {
    final store = _Store();
    final exporter = DeviceExporter(
      api: _Api(),
      store: store,
      tempDir: () => throw StateError('must not create plaintext'),
    );
    expect(exporter.supported, isFalse);
    for (final type in ['image', 'video', 'file']) {
      await expectLater(
        exporter.export(
          MediaItem(
            key: '$type.bin',
            type: type,
            url: 'https://fixture.invalid/private',
          ),
          'lib',
          guardSave: (_) => throw StateError('must not share'),
        ),
        throwsA(isA<DeviceExportError>()),
      );
    }
    expect(store.saves, 0);
  });
}
