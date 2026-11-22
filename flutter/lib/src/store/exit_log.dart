import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 前回までの終了理由の1件。Android の ApplicationExitInfo と同じ欄を持つ。
/// ANR とネイティブの異常終了の時だけ trace にスタックの先頭が入る。
/// 低メモリの終了にはスタックが無い（#1 作業1）
class ExitRecord {
  final int reason;
  final String reasonName;
  final String? description;
  final int timestamp; // ミリ秒
  final int pssKb;
  final int rssKb;
  final int importance;
  final int status;
  final String? trace;

  const ExitRecord({
    required this.reason,
    required this.reasonName,
    this.description,
    required this.timestamp,
    required this.pssKb,
    required this.rssKb,
    required this.importance,
    required this.status,
    this.trace,
  });

  Map<String, Object?> toJson() => {
        'reason': reason,
        'reasonName': reasonName,
        'description': ?description,
        'timestamp': timestamp,
        'pss': pssKb,
        'rss': rssKb,
        'importance': importance,
        'status': status,
        'trace': ?trace,
      };

  factory ExitRecord.fromJson(Map<String, Object?> j) => ExitRecord(
        reason: (j['reason'] as num?)?.toInt() ?? 0,
        reasonName: (j['reasonName'] as String?) ?? 'UNKNOWN',
        description: j['description'] as String?,
        timestamp: (j['timestamp'] as num?)?.toInt() ?? 0,
        pssKb: (j['pss'] as num?)?.toInt() ?? 0,
        rssKb: (j['rss'] as num?)?.toInt() ?? 0,
        importance: (j['importance'] as num?)?.toInt() ?? 0,
        status: (j['status'] as num?)?.toInt() ?? 0,
        trace: j['trace'] as String?,
      );
}

/// 起動のたびに前回までの終了理由を Android から読み、端末のファイルに残す。
/// 落ちた理由をアプリが記録しないと原因が決められないので、実装者が adb の
/// logcat（r2g.exit の行）と dumpsys activity exit-info から読める形にする（#1 作業1）。
/// 記録は画面に出さない
class ExitLog {
  static final ExitLog instance = ExitLog(_channelReader);

  /// [read] は試験で終了理由を差し替える口。実機では Android の
  /// `app.r2gallery/diag` チャンネルを呼ぶ（SDK 30 未満は空を返す）
  ExitLog(this._read, {Future<Directory> Function()? dir})
      : _dir = dir ?? _defaultDir;

  final Future<List<Map<String, Object?>>> Function() _read;
  final Future<Directory> Function() _dir;

  /// 残す件数。読むのは最新 5 件、残すのは最新 20 件
  static const _keep = 20;

  static Future<Directory> _defaultDir() async =>
      Directory('${(await getApplicationSupportDirectory()).path}/diag');

  static Future<List<Map<String, Object?>>> _channelReader() async {
    const ch = MethodChannel('app.r2gallery/diag');
    final list = await ch.invokeMethod<List<Object?>>('exitReasons');
    return [
      for (final e in list ?? const <Object?>[])
        if (e is Map) e.cast<String, Object?>(),
    ];
  }

  Future<File> _file() async => File('${(await _dir()).path}/exits.json');

  /// 残っている記録。新しい順。読めない・壊れている時は空
  Future<List<ExitRecord>> records() async {
    try {
      final raw = jsonDecode(await (await _file()).readAsString());
      if (raw is! List) return const [];
      final out = [
        for (final e in raw)
          if (e is Map) ExitRecord.fromJson(e.cast<String, Object?>()),
      ]..sort((a, b) => b.timestamp.compareTo(a.timestamp));
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// 読んで重ならない分だけ足し、20 件に切って書く。足した物は 1 件ずつ
  /// `r2g.exit {…}`（trace を除く）の 1 行で logcat に出す。
  /// 失敗（チャンネルが無い・ファイルが壊れている・書けない）しても起動は止めない
  Future<void> collect() async {
    // Android 10 以下と Web では終了理由が取れないので何もしない（ファイルも作らない）
    if (kIsWeb) return;
    try {
      final fresh = await _read();
      if (fresh.isEmpty) return;
      final byTimestamp = {for (final r in await records()) r.timestamp: r};
      final added = <ExitRecord>[];
      for (final raw in fresh) {
        final rec = ExitRecord.fromJson(raw);
        // timestamp が同じ物は重ねない。次の起動で同じ終了理由をもう一度読んでも増えない
        if (!byTimestamp.containsKey(rec.timestamp)) {
          byTimestamp[rec.timestamp] = rec;
          added.add(rec);
        }
      }
      if (added.isEmpty) return;
      final all = byTimestamp.values.toList()
        ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
      final keep = all.take(_keep).toList();
      final file = await _file();
      await file.parent.create(recursive: true);
      // 途中で落ちても古い中身か新しい中身のどちらかが残るよう、
      // 一時ファイルに書いてから rename する（転送の台帳と同じやり方）
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(keep));
      await tmp.rename(file.path);
      // releases 版の私的な領域は adb から読めないので、行は logcat にも出す
      for (final r in added) {
        final line = r.toJson()..remove('trace');
        debugPrint('r2g.exit ${jsonEncode(line)}');
      }
    } catch (e) {
      debugPrint('exit log: $e');
    }
  }
}
