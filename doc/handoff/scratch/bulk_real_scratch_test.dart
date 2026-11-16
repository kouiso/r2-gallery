import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/offline/offline_store.dart';
import 'package:r2_gallery/src/transfer/transfer_api.dart';
import 'package:r2_gallery/src/transfer/transfer_queue.dart';
import 'package:r2_gallery/src/viewer/device_export.dart';
import 'transfer_queue_test.dart' show MemLedger, MemKv;

class FakeStore implements MediaStoreBridge {
  int saved = 0;
  @override bool get supported => true;
  @override Future<void> save(String p, String n, String m) async { saved++; }
}

void main() {
  test('real worker 300', () async {
    final api = ApiClient()..setConnection(Connection('http://127.0.0.1:8791', 'live-token'));
    final tmp = await Directory.systemTemp.createTemp('bulkreal-');
    final ledger = MemLedger();
    final offline = OfflineStore(kv: MemKv(), dir: () async => Directory('${tmp.path}/off'));
    final q = TransferQueue(api: ApiClientTransferApi(api), offline: offline, ledger: ledger,
      stageDir: () async => Directory('${tmp.path}/stage'), persist: true);
    await q.restore();
    final run = DateTime.now().millisecondsSinceEpoch;
    final dir = Directory('/home/user/notes/work115/photos');
    final srcs = <UploadSource>[];
    for (final f in dir.listSync().whereType<File>()) {
      final n = f.path.split('/').last;
      srcs.add(UploadSource(name: 'r$run-$n', size: f.lengthSync(), mime: 'image/jpeg', path: f.path));
    }
    final sw = Stopwatch()..start();
    await q.enqueueUploads('a', srcs);
    var maxLedger = 0;
    while (q.tasks.any((t) => t.status != TransferStatus.done && t.status != TransferStatus.error)) {
      final l = ledger.value?.length ?? 0; if (l > maxLedger) maxLedger = l;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (sw.elapsedMilliseconds > 280000) break;
    }
    final st = <String, int>{};
    for (final t in q.tasks) { st[t.status.name] = (st[t.status.name] ?? 0) + 1; }
    print('UP ${sw.elapsedMilliseconds}ms $st maxLedger=$maxLedger errs=${q.tasks.where((t) => t.error != null).map((t) => '${t.name}: ${t.error}').take(5).toList()}');

    // list all
    final items = <MediaItem>[];
    String? cursor;
    do { final p = await api.folder('a', cursor: cursor); items.addAll(p.items.where((i) => i.key.startsWith('r$run-'))); cursor = p.cursor; } while (cursor != null);
    print('LISTED ${items.length}');

    sw..reset()..start();
    await q.enqueueDownloads('a', items);
    while (q.tasks.any((t) => t.kind == 'down' && t.status != TransferStatus.done && t.status != TransferStatus.error)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (sw.elapsedMilliseconds > 280000) break;
    }
    final st2 = <String, int>{};
    for (final t in q.tasks.where((t) => t.kind == 'down')) { st2[t.status.name] = (st2[t.status.name] ?? 0) + 1; }
    print('DOWN ${sw.elapsedMilliseconds}ms $st2 offline=${await offline.count()} errs=${q.tasks.where((t) => t.kind=='down' && t.error != null).map((t) => '${t.name}: ${t.error}').take(5).toList()}');

    final store = FakeStore();
    final ex = DeviceExporter(api: api, store: store, tempDir: () => Directory.systemTemp.createTemp('ex-'));
    sw..reset()..start();
    var fails = <String>[];
    for (final it in items) { try { await ex.export(it, 'a'); } catch (e) { fails.add('${it.key}: $e'); } }
    print('EXPORT ${sw.elapsedMilliseconds}ms saved=${store.saved} fails=${fails.length} ${fails.take(3)}');
    q.dispose();
  }, timeout: const Timeout(Duration(minutes: 8)));
}
