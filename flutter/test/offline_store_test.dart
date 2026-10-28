import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/offline/offline_store.dart';

class MemKv implements SecretKv {
  final Map<String, String> values = {};
  @override
  Future<String?> get(String key) async => values[key];
  @override
  Future<void> set(String key, String value) async => values[key] = value;
}

Uint8List _hex(String h) => Uint8List.fromList([
      for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16),
    ]);

void main() {
  late Directory tmp;
  late MemKv kv;
  late OfflineStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('r2g-offline-test-');
    kv = MemKv();
    store = OfflineStore(kv: kv, dir: () async => tmp);
  });

  tearDown(() => tmp.delete(recursive: true));

  test('KMP 版（JCE の AES/GCM）と同じ並び: 先頭12バイトの IV・暗号文・16バイトのタグ', () async {
    // NIST GCM 仕様のテストケース14（鍵・IV・平文すべて0）を、KMP 版が書く形でそのまま置く
    kv.values[OfflineStore.dekKey] = base64Encode(Uint8List(32));
    final ek = OfflineStore.entryKey('lib', 'a.jpg');
    final file = OfflineStore.fileNameFor(ek);
    kv.values[OfflineStore.manifestKey] = jsonEncode({
      ek: {'file': file, 'mime': 'image/*', 'name': 'a.jpg', 'size': 16, 'savedAt': 1},
    });
    await File('${tmp.path}/$file').writeAsBytes([
      ...Uint8List(12),
      ..._hex('cea7403d4d606b6e074ec5d3baf39d18'),
      ..._hex('d0d1c8a799996bf0265b98b5d48ab919'),
    ]);
    expect(await store.readBytes('lib', 'a.jpg'), Uint8List(16));
  });

  test('保存すると平文は端末に残らず、復号すると元に戻る', () async {
    final plain = Uint8List.fromList(utf8.encode('secret photo bytes' * 50));
    await store.saveBytes(
        lib: 'lib', key: 'p/a.jpg', type: 'image', name: 'a.jpg', plain: plain);
    final blob = tmp.listSync().single as File;
    final raw = blob.readAsBytesSync();
    expect(raw.length, 12 + plain.length + 16);
    expect(utf8.decode(raw, allowMalformed: true), isNot(contains('secret photo')));
    expect(blob.path.endsWith(OfflineStore.fileNameFor(
        OfflineStore.entryKey('lib', 'p/a.jpg'))), isTrue);
    expect(await store.readBytes('lib', 'p/a.jpg'), plain);
    expect(store.hasCached('lib', 'p/a.jpg'), isTrue);
    expect(await store.count(), 1);
  });

  test('同じキーでもライブラリが違えば別の保存として扱う', () async {
    await store.saveBytes(
        lib: 'a', key: 'x.jpg', type: 'image', name: 'x.jpg', plain: Uint8List.fromList([1]));
    await store.saveBytes(
        lib: 'b', key: 'x.jpg', type: 'video', name: 'x.jpg', plain: Uint8List.fromList([2]));
    expect(await store.count(), 2);
    expect(await store.readBytes('a', 'x.jpg'), [1]);
    expect(await store.readBytes('b', 'x.jpg'), [2]);
    final list = await store.list();
    expect({for (final r in list) r.lib}, {'a', 'b'});
    expect(list.firstWhere((r) => r.lib == 'b').entry.isVideo, isTrue);
  });

  test('書き換えられた暗号文は読まずに null を返す', () async {
    await store.saveBytes(
        lib: 'lib', key: 'a.jpg', type: 'image', name: 'a.jpg', plain: Uint8List(64));
    final blob = tmp.listSync().single as File;
    final raw = blob.readAsBytesSync();
    raw[20] ^= 0xff;
    blob.writeAsBytesSync(raw);
    expect(await store.readBytes('lib', 'a.jpg'), isNull);
  });

  test('すべて削除で暗号文と目録が消える。秘密置き場には鍵と目録しか書かない', () async {
    for (var i = 0; i < 3; i++) {
      await store.saveBytes(
          lib: 'lib', key: '$i.jpg', type: 'image', name: '$i.jpg', plain: Uint8List(8));
    }
    expect(kv.values.keys.toSet(), {OfflineStore.dekKey, OfflineStore.manifestKey});
    await store.clear();
    expect(await store.count(), 0);
    expect(tmp.listSync(), isEmpty);
    expect(await store.readBytes('lib', '0.jpg'), isNull);
  });

  test('鍵は1回作ったら使い回す（作り直すと前の保存が読めなくなる）', () async {
    await store.saveBytes(
        lib: 'l', key: 'a.jpg', type: 'image', name: 'a.jpg', plain: Uint8List(4));
    final dek = kv.values[OfflineStore.dekKey];
    final again = OfflineStore(kv: kv, dir: () async => tmp);
    expect(await again.readBytes('l', 'a.jpg'), Uint8List(4));
    expect(kv.values[OfflineStore.dekKey], dek);
    expect(base64Decode(dek!).length, 32);
  });
}
