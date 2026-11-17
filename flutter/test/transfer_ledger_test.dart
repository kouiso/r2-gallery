import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/transfer/transfer_ledger.dart';

void main() {
  late Directory tmp;

  setUp(() async => tmp = await Directory.systemTemp.createTemp('r2g-ledger-'));
  tearDown(() => tmp.delete(recursive: true));

  test('行ごとに書き、読み戻せる', () async {
    final l = FileTransferLedger(dir: () async => tmp);
    await l.writeRow('u1', '{"id":"u1","name":"a.jpg"}');
    await l.writeRow('u2', '{"id":"u2","name":"b.jpg"}');
    await l.writeRow('u1', '{"id":"u1","name":"a2.jpg"}');
    await l.deleteRow('u2');
    final rows = await l.readRows();
    expect(rows, hasLength(1));
    expect(rows.single['name'], 'a2.jpg');
    // 1行1ファイル。消した行はファイルも無い
    expect(File('${tmp.path}/u2.json').existsSync(), isFalse);
  });

  test('壊れた行だけ消して飛ばし、書き途中の .tmp も消す', () async {
    File('${tmp.path}/u1.json').writeAsStringSync('{"id":"u1"}');
    File('${tmp.path}/u2.json').writeAsStringSync('{broken');
    File('${tmp.path}/u3.json.tmp').writeAsStringSync('{"id":"u3"');
    File('${tmp.path}/note.txt').writeAsStringSync('x');
    final rows = await FileTransferLedger(dir: () async => tmp).readRows();
    expect(rows.single['id'], 'u1');
    expect(File('${tmp.path}/u2.json').existsSync(), isFalse);
    expect(File('${tmp.path}/u3.json.tmp').existsSync(), isFalse);
    // json 以外は触らない
    expect(File('${tmp.path}/note.txt').existsSync(), isTrue);
  });

  test('落ちても古い中身か新しい中身のどちらかが残る（.tmp 経由）', () async {
    final l = FileTransferLedger(dir: () async => tmp);
    await l.writeRow('u1', '{"id":"u1","v":1}');
    // 書き途中で止まった状態を作る（.tmp が残り、本体は前のまま）
    File('${tmp.path}/u1.json.tmp').writeAsStringSync('{"id":"u1","v":2');
    final rows = await l.readRows();
    expect(rows.single['v'], 1);
  });
}
