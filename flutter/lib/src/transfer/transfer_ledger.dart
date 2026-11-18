import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 転送の行を1行1ファイルで残す置き場。1回に書く量を1行ぶんにする。
/// （全行の書き直しは件数の2乗で重くなり、数千件の一括積みで転送が止まる原因だった）
abstract class TransferLedger {
  /// 残っている全行。順不同。読めない行のファイルは消して飛ばす
  Future<List<Map<String, Object?>>> readRows();

  /// 1行を置き換える。途中で落ちても古い中身か新しい中身のどちらかが残る
  Future<void> writeRow(String id, String json);

  Future<void> deleteRow(String id);
}

class FileTransferLedger implements TransferLedger {
  FileTransferLedger({Future<Directory> Function()? dir}) : _dirFn = dir ?? defaultDir;

  final Future<Directory> Function() _dirFn;
  Directory? _dir;

  /// `getApplicationSupportDirectory()` の `transfer_ledger`
  static Future<Directory> defaultDir() async {
    final d = await getApplicationSupportDirectory();
    return Directory('${d.path}/transfer_ledger');
  }

  Future<Directory> _d() async {
    final d = _dir ??= await _dirFn();
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  @override
  Future<List<Map<String, Object?>>> readRows() async {
    final rows = <Map<String, Object?>>[];
    Directory dir;
    try {
      dir = await _d();
    } on Exception catch (e) {
      debugPrint('transfer ledger dir unavailable: $e');
      return rows;
    }
    await for (final f in dir.list()) {
      if (f is! File) continue;
      final name = f.uri.pathSegments.last;
      // 書き途中で残った .tmp は読まずに消す
      if (name.endsWith('.tmp')) {
        try {
          await f.delete();
        } on Exception catch (e) {
          debugPrint('transfer ledger tmp not removed: $e');
        }
        continue;
      }
      if (!name.endsWith('.json')) continue;
      try {
        final decoded = jsonDecode(await f.readAsString());
        if (decoded is Map) {
          rows.add(Map<String, Object?>.from(decoded));
        } else {
          throw const FormatException('not a row object');
        }
      } on Exception catch (e) {
        // 壊れた行のファイルは戻せないので消して飛ばす
        debugPrint('transfer ledger row unreadable: $e');
        try {
          await f.delete();
        } on Exception catch (e2) {
          debugPrint('transfer ledger broken row not removed: $e2');
        }
      }
    }
    return rows;
  }

  @override
  Future<void> writeRow(String id, String json) async {
    final dir = await _d();
    final tmp = File('${dir.path}/$id.json.tmp');
    await tmp.writeAsString(json, flush: true);
    await tmp.rename('${dir.path}/$id.json');
  }

  @override
  Future<void> deleteRow(String id) async {
    final dir = await _d();
    final f = File('${dir.path}/$id.json');
    if (await f.exists()) await f.delete();
  }
}
