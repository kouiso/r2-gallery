import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/store/exit_log.dart';

Map<String, Object?> _raw(int ts, {String name = 'CRASH'}) => {
      'reason': 1,
      'reasonName': name,
      'timestamp': ts,
      'pss': 1000 + ts,
      'rss': 2000 + ts,
      'importance': 100,
      'status': 0,
      'trace': 'trace-$ts',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('exit_log_test');
  });
  tearDown(() async {
    await dir.delete(recursive: true);
  });

  ExitLog log(Future<List<Map<String, Object?>>> Function() read) =>
      ExitLog(read, dir: () async => dir);

  test('前回までの終了理由を重ねずに残し、20件に切る', () async {
    final l = log(() async => [for (var i = 1; i <= 25; i++) _raw(i)]);
    await l.collect();
    // 同じ記録をもう一度読んでも増えない
    await l.collect();

    final records = await l.records();
    expect(records.length, 20);
    expect(records.first.timestamp, 25);
    expect(records.last.timestamp, 6);
  });

  test('壊れたファイルは捨てて作り直す', () async {
    await dir.create(recursive: true);
    await File('${dir.path}/exits.json').writeAsString('{');
    final l = log(() async => [_raw(1), _raw(2)]);
    await l.collect();

    final records = await l.records();
    expect(records.map((r) => r.timestamp), [2, 1]);
  });

  test('読み手が失敗しても起動を止めない', () async {
    final l = log(() async =>
        throw PlatformException(code: 'diag', message: 'no channel'));
    await l.collect();
    expect(await l.records(), isEmpty);
  });

  test('新しく足した記録だけを r2g.exit の行で出す', () async {
    final lines = <String>[];
    final prevPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) lines.add(message);
    };
    try {
      var extra = false;
      final l = log(() async => [
            for (var i = 1; i <= 3; i++) _raw(i),
            if (extra) _raw(4),
          ]);
      await l.collect();
      expect(lines.where((l) => l.startsWith('r2g.exit ')).length, 3);
      extra = true;
      await l.collect();
      final exits = lines.where((l) => l.startsWith('r2g.exit ')).toList();
      expect(exits.length, 4);
      for (final line in exits) {
        expect(line, isNot(contains('trace')));
        final j = jsonDecode(line.substring('r2g.exit '.length));
        expect(j.containsKey('trace'), isFalse);
        expect(j['reasonName'], 'CRASH');
      }
    } finally {
      debugPrint = prevPrint;
    }
  });
}
