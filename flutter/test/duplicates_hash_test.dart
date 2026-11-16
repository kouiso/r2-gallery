import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/duplicates/content_hash.dart';
import 'package:r2_gallery/src/transfer/transfer_queue.dart';

// FIPS 180-2 の既知の値
const _empty =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
const _abc = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  test('空と "abc" が既知の値になる', () async {
    expect(await sha256OfBytes(Uint8List(0)), _empty);
    expect(await sha256OfBytes(_b('abc')), _abc);
    expect(await sha256OfStream(const Stream.empty()), _empty);
  });

  test('区切って足しても一度に計算した値と同じ', () async {
    expect(await sha256OfBytes(_b('abc'), chunk: 1), _abc);
    expect(await sha256OfBytes(_b('abc'), chunk: 2), _abc);
    expect(await sha256OfStream(Stream.fromIterable([_b('a'), _b('bc')])), _abc);
    final big = Uint8List.fromList(List.generate(300000, (i) => i * 31 & 0xff));
    final whole = await sha256OfBytes(big, chunk: big.length);
    expect(await sha256OfBytes(big, chunk: 4096), whole);
    expect(
        await sha256OfStream(Stream.fromIterable([
          Uint8List.sublistView(big, 0, 1000),
          Uint8List.sublistView(big, 1000),
        ])),
        whole);
  });

  test('選んだファイルはバイト列・パス・読み口のどれでも同じ値になる', () async {
    final dir = await Directory.systemTemp.createTemp('r2g-hash-');
    addTearDown(() => dir.delete(recursive: true));
    final f = File('${dir.path}/a.jpg');
    await f.writeAsBytes(_b('abc'));
    expect(
        await hashUploadSource(UploadSource(
            name: 'a.jpg', size: 3, mime: 'image/jpeg', bytes: _b('abc'))),
        _abc);
    expect(
        await hashUploadSource(UploadSource(
            name: 'a.jpg', size: 3, mime: 'image/jpeg', path: f.path)),
        _abc);
    expect(
        await hashUploadSource(UploadSource(
            name: 'a.jpg', size: 3, mime: 'image/jpeg', reader: f.openRead)),
        _abc);
  });
}
