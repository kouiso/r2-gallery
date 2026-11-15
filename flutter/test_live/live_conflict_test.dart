// 手元の Worker に対する確認: 同名への書き込みが 409 になること。
// 転送キュー（TransferQueue）は、再開時の 409 を中身の照合に回す前提でこの挙動に頼っている。
// 本物の Worker（wrangler dev --local）を、本物の ApiClientTransferApi で叩く。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/transfer/transfer_api.dart';

const _endpoint =
    String.fromEnvironment('LIVE_ENDPOINT', defaultValue: 'http://127.0.0.1:8787');
const _token = String.fromEnvironment('LIVE_TOKEN', defaultValue: 'live-token');

Future<int> _status(Future<void> Function() f) async {
  try {
    await f();
    return 200;
  } on ApiError catch (e) {
    return e.status;
  }
}

void main() {
  // flutter_test は HttpClient を差し替えて外へ出さない。実通信のため外す
  setUpAll(() => HttpOverrides.global = null);
  final api = ApiClient()..setConnection(const Connection(_endpoint, _token));
  final t = ApiClientTransferApi(api);
  final run = DateTime.now().millisecondsSinceEpoch;
  Uint8List bytes(int seed) => Uint8List.fromList(List.generate(64, (i) => i + seed));

  test('単発 PUT: 既にあるキーへの create-only は 409', () async {
    final key = 'conflict-$run/small.jpg';
    await t.putObject('a', key, bytes(1), 'image/jpeg');
    final s = await _status(() => t.putObject('a', key, bytes(2), 'image/jpeg'));
    // ignore: avoid_print
    print('LIVE put existing key -> $s');
    expect(s, 409);
  });

  test('multipart: 先に完了した同名があれば、完了は 409（開始時は両方通る）', () async {
    final key = 'conflict-$run/big.mp4';
    final idA = await t.multipartCreate('a', key, 'video/mp4');
    final idB = await t.multipartCreate('a', key, 'video/mp4');
    final pa = await t.putPart('a', key, idA, 1, bytes(1));
    final pb = await t.putPart('a', key, idB, 1, bytes(2));
    await t.multipartComplete('a', key, idA, [pa]);
    final s = await _status(() => t.multipartComplete('a', key, idB, [pb]));
    // ignore: avoid_print
    print('LIVE multipart complete on existing key -> $s');
    expect(s, 409);
    // 開始も、既にあれば 409
    final c = await _status(() => t.multipartCreate('a', key, 'video/mp4'));
    // ignore: avoid_print
    print('LIVE multipart create on existing key -> $c');
    expect(c, 409);
  });

  test('multipart: 完了済みの uploadId でもう一度完了しても 409（応答が落ちた再開）', () async {
    final key = 'conflict-$run/lost-response.mp4';
    final id = await t.multipartCreate('a', key, 'video/mp4');
    final p = await t.putPart('a', key, id, 1, bytes(3));
    await t.multipartComplete('a', key, id, [p]);
    final s = await _status(() => t.multipartComplete('a', key, id, [p]));
    // ignore: avoid_print
    print('LIVE multipart re-complete after success -> $s');
    expect(s, 409);
  });
}
