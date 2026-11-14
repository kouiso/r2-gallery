import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/offline/offline_store.dart';
import 'package:r2_gallery/src/transfer/transfer_api.dart';
import 'package:r2_gallery/src/transfer/transfer_queue.dart';
import 'transfer_queue_test.dart' show FakeWorker, MemLedger, MemKv, bytesOf;

void main() {
  test('300 uploads (every 10th multipart) + 300 downloads', () async {
    final w = FakeWorker();
    await w.start();
    final api = ApiClient()..setConnection(Connection(w.base, 'tok'));
    final tmp = await Directory.systemTemp.createTemp('bulk-');
    final ledger = MemLedger();
    final offline = OfflineStore(kv: MemKv(), dir: () async => Directory('${tmp.path}/off'));
    final q = TransferQueue(
      api: ApiClientTransferApi(api), offline: offline, ledger: ledger,
      stageDir: () async => Directory('${tmp.path}/stage'), persist: true,
      multipartThreshold: 2048, partSize: 1024, configured: () => true);
    await q.restore();
    final sw = Stopwatch()..start();
    final srcs = <UploadSource>[];
    for (var i = 0; i < 300; i++) {
      final n = i % 10 == 0 ? 5000 : 300;
      final f = File('${tmp.path}/p$i.jpg')..writeAsBytesSync(bytesOf(n, i));
      srcs.add(UploadSource(name: 'IMG_$i.jpg', size: n, mime: 'image/jpeg', path: f.path));
    }
    await q.enqueueUploads('lib', srcs);
    var maxLedger = 0;
    while (q.tasks.any((t) => t.status != TransferStatus.done && t.status != TransferStatus.error)) {
      maxLedger = (ledger.value ?? '').length > maxLedger ? ledger.value!.length : maxLedger;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      if (sw.elapsedMilliseconds > 120000) break;
    }
    final st = <String, int>{};
    for (final t in q.tasks) { st[t.status.name] = (st[t.status.name] ?? 0) + 1; }
    print('UP ${sw.elapsedMilliseconds}ms status=$st objects=${w.objects.length} maxLedgerBytes=$maxLedger errs=${q.tasks.where((t) => t.error != null).map((t) => t.error).toSet()}');

    for (var i = 0; i < 300; i++) { w.media['m$i.jpg'] = bytesOf(400, i); }
    final items = [for (var i = 0; i < 300; i++) MediaItem(key: 'm$i.jpg', type: 'image', url: '${w.base}/m/m$i.jpg', size: 400)];
    sw..reset()..start();
    await q.enqueueDownloads('lib', items);
    while (q.tasks.any((t) => t.kind == 'down' && t.status != TransferStatus.done && t.status != TransferStatus.error)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      if (sw.elapsedMilliseconds > 120000) break;
    }
    final st2 = <String, int>{};
    for (final t in q.tasks.where((t) => t.kind == 'down')) { st2[t.status.name] = (st2[t.status.name] ?? 0) + 1; }
    print('DOWN ${sw.elapsedMilliseconds}ms status=$st2 offlineCount=${await offline.count()} errs=${q.tasks.where((t) => t.kind=='down' && t.error != null).map((t) => t.error).toSet()}');
    q.dispose(); await w.stop();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
