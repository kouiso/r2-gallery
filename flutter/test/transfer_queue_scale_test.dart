import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/offline/offline_store.dart';
import 'package:r2_gallery/src/transfer/transfer_api.dart';
import 'package:r2_gallery/src/transfer/transfer_ledger.dart';
import 'package:r2_gallery/src/transfer/transfer_queue.dart';

/// ネットを通さない偽の送り先。5000件を数秒で終わらせるための実装。
class FakeTransferApi implements TransferApi {
  final Map<String, Uint8List> objects = {};
  final Set<String> failNames = {};

  @override
  Future<String> multipartCreate(
      String lib, String key, String contentType) async {
    return 'up';
  }

  @override
  Future<UploadPart> putPart(String lib, String key, String uploadId, int part,
      Uint8List bytes,
      {CancelToken? cancelToken,
      void Function(int sent)? onProgress}) async {
    onProgress?.call(bytes.length);
    return UploadPart(part, 'epart');
  }

  @override
  Future<void> multipartComplete(
      String lib, String key, String uploadId, List<UploadPart> parts) async {
    objects[key] = Uint8List(0);
  }

  @override
  Future<void> multipartAbort(String lib, String key, String uploadId) async {}

  @override
  Future<void> multipartAbortOn(String endpoint, String token, String lib,
      String key, String uploadId) async {}

  @override
  Future<void> putObject(String lib, String key, Uint8List bytes, String mime,
      {CancelToken? cancelToken,
      void Function(int sent)? onProgress,
      String? sha256}) async {
    if (failNames.contains(key)) {
      throw const ApiError(500, 'x');
    }
    if (objects.containsKey(key)) {
      throw DioException(
          requestOptions: RequestOptions(),
          response: Response(
              requestOptions: RequestOptions(), statusCode: 409));
    }
    onProgress?.call(bytes.length);
    objects[key] = bytes;
  }

  @override
  Future<void> putThumb(String lib, String key, Uint8List bytes) async {}

  @override
  Future<Uint8List> fetchBytes(String url,
      {CancelToken? cancelToken,
      void Function(int got, int total)? onProgress}) async {
    throw UnimplementedError();
  }

  @override
  Future<bool> storedMatches(
      String lib, String key, int size, Stream<List<int>> Function() local,
      {CancelToken? cancelToken,
      void Function(int matched)? onProgress}) async {
    return false;
  }

  @override
  Future<String?> itemUrl(String lib, String key) async => null;

  @override
  Future<String?> itemViewUrl(String lib, String key) async => null;

  @override
  Future<void> albumAdd(String lib, String albumId, List<String> keys) async {}
}

/// 行ごとの台帳をメモリで真似る。書いた量を数えて、件数に比例することを見る。
class MemLedger implements TransferLedger {
  final Map<String, String> rows = {};
  int bytesWritten = 0;
  int writes = 0;
  @override
  Future<List<Map<String, Object?>>> readRows() async => [
        for (final j in rows.values)
          Map<String, Object?>.from(jsonDecode(j) as Map),
      ];
  @override
  Future<void> writeRow(String id, String json) async {
    rows[id] = json;
    bytesWritten += json.length;
    writes++;
  }

  @override
  Future<void> deleteRow(String id) async {
    rows.remove(id);
    writes++;
  }
}

class MemLegacyLedger implements LedgerStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String json) async => value = json;
}

class MemKv implements SecretKv {
  final Map<String, String> values = {};
  @override
  Future<String?> get(String key) async => values[key];
  @override
  Future<void> set(String key, String value) async => values[key] = value;
}


TransferQueue _make(FakeTransferApi api, MemLedger ledger, MemKv kv,
    MemLegacyLedger legacy, Directory tmp,
    {int stageParallel = 2, UriStager? uriStager}) {
  return TransferQueue(
    api: api,
    offline: OfflineStore(
        kv: kv, dir: () async => Directory('${tmp.path}/offline')),
    ledger: ledger,
    legacyLedger: legacy,
    secrets: kv,
    stageDir: () async => Directory('${tmp.path}/stage'),
    persist: true,
    multipartThreshold: 1024 * 1024,
    netRetryDelay: const Duration(milliseconds: 50),
    stageParallel: stageParallel,
    // URI の元を使わない試験では呼ばれない口。呼ばれたら分かるように失敗にする
    uriStager: uriStager ??
        (uri, dest) =>
            throw UnimplementedError('URI stager not expected in this test'),
    configured: () => true,
  );
}

Future<void> until(bool Function() cond, {String? what, int tries = 6000}) async {
  for (var i = 0; i < tries; i++) {
    if (cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('timed out waiting for ${what ?? 'condition'}');
}

void main() {
  test('5000件のうち3件が 500 でも残りは done になり、失敗の3件は理由つきで残る',
      () async {
    const n = 5000;
    final tmp = await Directory.systemTemp.createTemp('r2g-scale-');
    final api = FakeTransferApi()
      ..failNames.addAll({'p7.jpg', 'p777.jpg', 'p4999.jpg'});
    final ledger = MemLedger();
    final q =
        _make(api, ledger, MemKv(), MemLegacyLedger(), tmp);
    try {
      await q.restore();
      final srcDir = Directory('${tmp.path}/picked');
      await srcDir.create();
      final sources = <UploadSource>[];
      for (var i = 0; i < n; i++) {
        final f = File('${srcDir.path}/p$i.jpg');
        await f.writeAsBytes(Uint8List.fromList([i & 0xff, 1, 2, 3]));
        sources.add(UploadSource(
            name: 'p$i.jpg', size: 4, mime: 'image/jpeg', path: f.path));
        if (i % 500 == 499) {
          await q.enqueueUploads('lib', sources.sublist(i - 499));
        }
      }
      await until(
          () => q.tasks
                  .where((t) =>
                      t.status == TransferStatus.done ||
                      t.status == TransferStatus.error)
                  .length ==
              n,
          what: 'all settled',
          tries: 9000);
      final failed = q.tasks
          .where((t) => t.status == TransferStatus.error)
          .toList();
      expect(q.tasks.where((t) => t.status == TransferStatus.done).length,
          n - 3);
      expect(failed, hasLength(3));
      for (final t in failed) {
        expect(t.error, contains('500'));
      }
    } finally {
      q.dispose();
      await tmp.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 8)));

  test('古い形の記録に5000行が残っていても、行ごとの記録へ移して全部送る', () async {
    const n = 5000;
    final tmp = await Directory.systemTemp.createTemp('r2g-scale-');
    final api = FakeTransferApi();
    final ledger = MemLedger();
    final legacy = MemLegacyLedger();
    // 退避済みで送るだけの行を古い形で5000行残しておく
    final stage = Directory('${tmp.path}/stage-old');
    await stage.create();
    final rows = <Map<String, Object?>>[];
    for (var i = 0; i < n; i++) {
      final f = File('${stage.path}/up-u$i.bin');
      await f.writeAsBytes(Uint8List.fromList([i & 0xff]));
      rows.add({
        'id': 'u$i',
        'kind': 'up',
        'lib': 'lib',
        'name': 'p$i.jpg',
        'size': 1,
        'mime': 'image/jpeg',
        'status': 'queued',
        'stagedPath': f.path,
      });
    }
    legacy.value = jsonEncode(rows);
    final q = _make(api, ledger, MemKv(), legacy, tmp);
    try {
      await q.restore();
      try {
        await until(() => q.tasks.every((t) => t.status == TransferStatus.done),
            what: 'all done', tries: 9000);
      } catch (_) {
        final counts = <TransferStatus, int>{};
        for (final t in q.tasks) {
          counts[t.status] = (counts[t.status] ?? 0) + 1;
        }
        // ignore: avoid_print
        print('STATUS-DIST: $counts ERR: ${q.tasks.where((t) => t.error != null).take(3).map((t) => t.error).toList()}');
        rethrow;
      }
      expect(q.tasks.length, n);
      await q.idle();
      // 古い形は空になり、行のファイルは完了分が消えて0
      expect(legacy.value, '[]');
      expect(ledger.rows, isEmpty);
    } finally {
      q.dispose();
      await tmp.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 8)));

  test('5000件を積んでも退避は同時に2件まで', () async {
    const n = 5000;
    final tmp = await Directory.systemTemp.createTemp('r2g-scale-');
    final api = FakeTransferApi();
    final ledger = MemLedger();
    var maxStaging = 0;
    final q = _make(api, ledger, MemKv(), MemLegacyLedger(), tmp);
    q.addListener(() {
      if (q.stagingCount > maxStaging) maxStaging = q.stagingCount;
    });
    try {
      await q.restore();
      final srcDir = Directory('${tmp.path}/picked');
      await srcDir.create();
      final sources = <UploadSource>[];
      for (var i = 0; i < n; i++) {
        final f = File('${srcDir.path}/p$i.jpg');
        await f.writeAsBytes(Uint8List.fromList([i & 0xff, 1, 2, 3]));
        sources.add(UploadSource(
            name: 'p$i.jpg', size: 4, mime: 'image/jpeg', path: f.path));
        if (i % 500 == 499) {
          await q.enqueueUploads('lib', sources.sublist(i - 499));
        }
      }
      await until(() => q.tasks.every((t) => t.finished),
          what: 'all finished', tries: 9000);
      expect(q.tasks.length, n);
      // 上限を外すと 5000 に届く。2件ずつ進むのが今の決まり
      expect(maxStaging, lessThanOrEqualTo(2));
      expect(maxStaging, greaterThan(0));
    } finally {
      q.dispose();
      await tmp.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 8)));



  test('5000件を一度に積んでも全部 done になり、記録へ書く量は件数に比例する', () async {
    const n = 5000;
    final tmp = await Directory.systemTemp.createTemp('r2g-scale-');
    final api = FakeTransferApi();
    final ledger = MemLedger();
    final q = TransferQueue(
      api: api,
      offline: OfflineStore(
          kv: MemKv(), dir: () async => Directory('${tmp.path}/offline')),
      ledger: ledger,
      legacyLedger: MemLegacyLedger(),
      secrets: MemKv(),
      stageDir: () async => Directory('${tmp.path}/stage'),
      persist: true,
      multipartThreshold: 1024 * 1024,
      netRetryDelay: const Duration(milliseconds: 50),
      configured: () => true,
    );
    try {
      await q.restore();
      // 端末に置いた選択ファイルを真似る（小さい中身で十分、量が問題なので）
      final srcDir = Directory('${tmp.path}/picked');
      await srcDir.create();
      final sources = <UploadSource>[];
      for (var i = 0; i < n; i++) {
        final f = File('${srcDir.path}/p$i.jpg');
        await f.writeAsBytes(Uint8List.fromList([i & 0xff, 1, 2, 3]));
        sources.add(UploadSource(
            name: 'p$i.jpg', size: 4, mime: 'image/jpeg', path: f.path));
        if (i % 500 == 499) {
          // 一括で積むが、追い越されないよう段々に分けて呼ぶ
          await q.enqueueUploads('lib', sources.sublist(i - 499));
        }
      }
      await until(() => q.tasks.every((t) => t.finished),
          what: 'all finished', tries: 9000);
      expect(q.tasks.where((t) => t.status == TransferStatus.error), isEmpty);
      expect(q.tasks.length, n);
      await q.idle();
      // 書き込み量は「行の大きさ × 件数 × 状態遷移の回数」の桁。
      // 全行を毎回書き直す形（件数の2乗）なら数十MBを超えるのでこの線で落ちる
      expect(ledger.bytesWritten, lessThan(n * 512 * 8));
      // 記録のファイルも完了分は消えている
      expect(ledger.rows, isEmpty);
    } finally {
      q.dispose();
      await tmp.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 8)));

  test('content の元5000件を2件ずつ写して全部送る', () async {
    const n = 5000;
    final tmp = await Directory.systemTemp.createTemp('r2g-scale-');
    final api = FakeTransferApi();
    final ledger = MemLedger();
    var active = 0;
    var maxActive = 0;
    var copied = 0;
    // content:// の写しは権利が切れないうちに順に済ませたい。同時に走る数を数えて
    // 上限（stageParallel=2）を超えないことを確かめる
    Future<void> stager(String uri, String dest) async {
      active++;
      if (active > maxActive) maxActive = active;
      try {
        // 写しの途中で別の1件が始まるよう、すぐ返さず1拍待つ
        await Future<void>.delayed(const Duration(milliseconds: 1));
        await File(dest).writeAsBytes(const [1]);
        copied++;
      } finally {
        active--;
      }
    }

    final q =
        _make(api, ledger, MemKv(), MemLegacyLedger(), tmp, uriStager: stager);
    try {
      await q.restore();
      final sources = <UploadSource>[];
      for (var i = 0; i < n; i++) {
        sources.add(UploadSource(
            name: 'p$i.jpg',
            size: 1,
            mime: 'image/jpeg',
            uri: 'content://picked/p$i'));
        if (i % 500 == 499) {
          await q.enqueueUploads('lib', sources.sublist(i - 499));
        }
      }
      await until(() => q.tasks.every((t) => t.finished),
          what: 'all finished', tries: 9000);
      expect(q.tasks.where((t) => t.status == TransferStatus.error), isEmpty);
      expect(q.tasks.length, n);
      expect(copied, n);
      expect(maxActive, greaterThan(0));
      expect(maxActive, lessThanOrEqualTo(2));
    } finally {
      q.dispose();
      await tmp.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 8)));
}
