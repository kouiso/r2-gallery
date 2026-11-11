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

class _TransientKeyKv extends MemKv {
  int keyReads = 0;
  @override
  Future<String?> get(String key) async {
    if (key == OfflineStore.dekKey && ++keyReads == 1) {
      throw StateError('synthetic temporary key-store failure');
    }
    return super.get(key);
  }
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

  test('大きい保存も同じ形式で復号し、別isolate側の暗号文・tag・鍵の不一致を拒否する', () async {
    final plain = Uint8List.fromList(List<int>.generate(1024 * 1024, (i) => i % 251));
    await store.saveBytes(lib: 'lib', key: 'large.mp4', type: 'video',
      name: 'synthetic', plain: plain);
    final file = tmp.listSync().single as File;
    final original = await file.readAsBytes();
    expect(original.length, plain.length + 28);
    expect(await store.readBytes('lib', 'large.mp4'), plain);
    for (final offset in [12, original.length - 1]) {
      final corrupt = Uint8List.fromList(original)..[offset] ^= 1;
      await file.writeAsBytes(corrupt);
      expect(await store.readBytes('lib', 'large.mp4'), isNull);
    }
    await file.writeAsBytes(original);
    final key = base64Decode(kv.values[OfflineStore.dekKey]!)..[0] ^= 1;
    kv.values[OfflineStore.dekKey] = base64Encode(key);
    final wrongKey = OfflineStore(kv: kv, dir: () async => tmp);
    addTearDown(wrongKey.dispose);
    expect(await wrongKey.readBytes('lib', 'large.mp4'), isNull);
    expect(await file.readAsBytes(), original);
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

  test('秘密置き場の一時障害で失敗した鍵取得は次の保存で再試行できる', () async {
    final transient = _TransientKeyKv();
    final base = OfflineStore(kv: transient, dir: () async => tmp);
    final a = base.forAccount('account-A');
    final b = base.forAccount('account-B');
    Future<void> save(OfflineStore target) => target.saveBytes(
        lib: 'lib', key: 'a.jpg', type: 'image', name: 'a.jpg',
        plain: Uint8List.fromList([1, 2, 3]));
    await expectLater(save(a), throwsStateError);
    expect(transient.values[OfflineStore.dekKey], isNull);
    await Future.wait([save(a), save(b)]);
    expect(transient.keyReads, 2);
    expect(await a.readBytes('lib', 'a.jpg'), [1, 2, 3]);
    expect(await b.readBytes('lib', 'a.jpg'), [1, 2, 3]);
  });

  test('接続ごとの同じキーを分離し、件数・容量・削除も他の接続へ届かない', () async {
    final a = store.forAccount('account-A');
    final b = store.forAccount('account-B');
    expect(identical(a, store.forAccount('account-A')), isTrue);
    expect(a.accountId, 'account-A');
    await a.saveBytes(lib: 'lib', key: 'same.jpg', type: 'image', name: 'A.jpg',
        plain: Uint8List.fromList([1, 2]));
    expect(await b.count(), 0);
    expect(await b.readBytes('lib', 'same.jpg'), isNull);
    await b.saveBytes(lib: 'lib', key: 'same.jpg', type: 'image', name: 'B.jpg',
        plain: Uint8List.fromList([3, 4, 5]));
    expect(await a.totalBytes(), 2);
    expect(await b.totalBytes(), 3);
    expect((await a.list()).single.accountId, 'account-A');
    expect((await b.list()).single.entry.name, 'B.jpg');
    final again = OfflineStore(kv: kv, dir: () async => tmp).forAccount('account-A');
    expect(await again.readBytes('lib', 'same.jpg'), [1, 2]);
    await a.clear();
    expect(await a.count(), 0);
    expect(await b.readBytes('lib', 'same.jpg'), [3, 4, 5]);
    expect(tmp.listSync(), hasLength(1));
  });

  test('未所属の旧保存を自動で取り込まず、接続の保存を消しても旧保存は残る', () async {
    await store.saveBytes(lib: 'lib', key: 'old.jpg', type: 'image', name: 'old.jpg',
        plain: Uint8List.fromList([9]));
    final legacyManifest = kv.values[OfflineStore.manifestKey];
    final legacyFiles = tmp.listSync().map((f) => f.path).toSet();
    final current = store.forAccount('current-account');
    expect(await current.hasLegacyData(), isTrue);
    expect(await current.list(), isEmpty);
    expect(await current.readBytes('lib', 'old.jpg'), isNull);
    await current.clear();
    expect(kv.values[OfflineStore.manifestKey], legacyManifest);
    expect(tmp.listSync().map((f) => f.path).toSet(), legacyFiles);
    expect(await store.readBytes('lib', 'old.jpg'), [9]);
  });

  test('別接続の初回保存が同時でも既存の鍵を一度だけ決め、両方読み直せる', () async {
    final a = store.forAccount('account-A');
    final b = store.forAccount('account-B');
    await Future.wait([
      a.saveBytes(lib: 'lib', key: 'a.mp4', type: 'video', name: 'a.mp4',
          plain: Uint8List.fromList([1])),
      b.saveBytes(lib: 'lib', key: 'b.mp4', type: 'video', name: 'b.mp4',
          plain: Uint8List.fromList([2])),
    ]);
    final fresh = OfflineStore(kv: kv, dir: () async => tmp);
    expect(await fresh.forAccount('account-A').readBytes('lib', 'a.mp4'), [1]);
    expect(await fresh.forAccount('account-B').readBytes('lib', 'b.mp4'), [2]);
  });

  test('古い転送が保持した保存先は、新しい接続の保存先へ変わらない', () async {
    final pendingTarget = store.forAccount('account-A');
    final current = store.forAccount('account-B');
    await pendingTarget.saveBytes(lib: 'lib', key: 'pending.mp4', type: 'video',
        name: 'pending.mp4', plain: Uint8List.fromList([8]));
    expect(await current.list(), isEmpty);
    expect(await current.readBytes('lib', 'pending.mp4'), isNull);
    expect(await store.forAccount('account-A').readBytes('lib', 'pending.mp4'), [8]);
  });

  test('目録に保存領域外へのパスがあっても読まない・削除しない', () async {
    final outside = File('${tmp.path}/outside.txt');
    await outside.writeAsString('keep');
    kv.values[OfflineStore.manifestKey] = jsonEncode({
      OfflineStore.entryKey('lib', 'bad.jpg'): {
        'file': '../outside.txt', 'mime': 'image/*', 'name': 'bad.jpg',
        'size': 4, 'savedAt': 1,
      },
    });
    expect(await store.list(), isEmpty);
    expect(await store.readBytes('lib', 'bad.jpg'), isNull);
    await store.clear();
    expect(await outside.readAsString(), 'keep');
  });
}
