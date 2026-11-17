import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/viewer/device_export.dart';

class _Api extends Fake implements ApiClient {
  final downloads = <String>[];
  @override
  Future<void> downloadToFile(String url, String path) async {
    downloads.add(url);
    await File(path).writeAsBytes([1, 2, 3]);
  }
}

class _Store implements MediaStoreBridge {
  int saves = 0;
  String? lastPath;
  @override
  bool get supported => true;
  @override
  Future<void> save(String path, String displayName, String mime) async {
    saves++;
    lastPath = path;
  }
}

void main() {
  test('端末に保存は一時平文を作り、bridgeへ登録し、登録の外へ平文は残さない', () async {
    final api = _Api();
    final store = _Store();
    var guardCalls = 0;
    final exporter = DeviceExporter(
      api: api,
      store: store,
      tempDir: () => Directory.systemTemp.createTemp('r2g-export-test-'),
    );
    expect(exporter.supported, isTrue);
    await exporter.export(
      MediaItem(key: 'a.jpg', type: 'image', url: 'https://fixture.invalid/a.jpg'),
      'lib',
      guardSave: (body) async {
        guardCalls++;
        await body();
      },
    );
    expect(guardCalls, 1);
    expect(store.saves, 1);
    expect(api.downloads, ['https://fixture.invalid/a.jpg']);
    expect(store.lastPath, isNotNull);
    // 登録後は一時平文を片付ける
    expect(await File(store.lastPath!).exists(), isFalse);
  });

  test('端末に保存は画像/動画以外の形式を断り、bridgeへ進まない', () async {
    final store = _Store();
    final exporter = DeviceExporter(
      api: _Api(),
      store: store,
      tempDir: () => Directory.systemTemp.createTemp('r2g-export-test-'),
    );
    await expectLater(
      exporter.export(
        MediaItem(key: 'c.bin', type: 'file', url: 'https://fixture.invalid/c'),
        'lib',
      ),
      throwsA(isA<DeviceExportError>()),
    );
    expect(store.saves, 0);
  });
}