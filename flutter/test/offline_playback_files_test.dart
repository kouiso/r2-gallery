import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/offline/offline_playback_files.dart';

void main() {
  late Directory root;
  late OfflinePlaybackFiles files;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('r2g-private-playback-test-');
    files = OfflinePlaybackFiles(root: () async => root);
  });
  tearDown(() => root.delete(recursive: true));

  test('再生用平文は専用セッションにだけ置き、破棄で削除する', () async {
    final lease = await files.create(Uint8List.fromList([1, 2, 3]));
    expect(await lease.file.readAsBytes(), [1, 2, 3]);
    expect(lease.file.parent.parent.path, root.path);
    expect(lease.file.path.endsWith('/play.mp4'), isTrue);
    await lease.dispose();
    await lease.dispose();
    expect(await lease.file.exists(), isFalse);
    expect(root.listSync(), isEmpty);
  });

  test('異常終了した専用セッションだけ掃除し、他のファイルには触れない', () async {
    final stale = Directory('${root.path}/session-old');
    await stale.create();
    await File('${stale.path}/play.mp4').writeAsBytes([9]);
    final other = File('${root.path}/unrelated.txt');
    await other.writeAsString('keep');
    await files.cleanOrphans();
    expect(await stale.exists(), isFalse);
    expect(await other.readAsString(), 'keep');
  });

  test('同じ起動中の別の再生セッションを消さない', () async {
    final a = await files.create(Uint8List.fromList([1]));
    final b = await files.create(Uint8List.fromList([2]));
    await files.cleanOrphans();
    expect(await a.file.readAsBytes(), [1]);
    expect(await b.file.readAsBytes(), [2]);
    await a.dispose();
    expect(await b.file.exists(), isTrue);
    await b.dispose();
  });
}
