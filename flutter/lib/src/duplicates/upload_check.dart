import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/models.dart';
import '../transfer/transfer_queue.dart';
import 'content_hash.dart';

/// Worker の `/objects/check`。テストで差し替えるため関数で受ける。
typedef ObjectChecker = Future<ObjectCheck> Function(
    String lib, List<({int size, String? sha256})> items);

enum UploadCheckStatus {
  /// 全部確かめられた
  done,

  /// 途中で失敗した。見つかった分だけ印を付け、残りは確かめずに上げる
  failed,

  /// 接続先の Worker が照合に対応していない（404）。利用者には何も出さない
  unsupported,
}

/// 選んだ1件が既にある、または同じ選択の中で重なっている印。
class UploadDuplicate {
  /// ライブラリに既にある同じ中身の項目。
  final MediaItem? stored;

  /// 同じ選択の中で先に出てくる同じ中身の位置。
  final int? sameAs;
  const UploadDuplicate({this.stored, this.sameAs});
}

class UploadCheckOutcome {
  final UploadCheckStatus status;
  final Map<int, UploadDuplicate> flags;

  /// 計算できたハッシュ。一括PUTで Worker へ添える。
  final Map<int, String> hashes;

  /// 確かめきれなかった選択の位置（サイズ不明・読めなかった・Worker の計算待ちが終わらなかった）。
  final Set<int> unresolved;
  const UploadCheckOutcome({
    required this.status,
    this.flags = const {},
    this.hashes = const {},
    this.unresolved = const {},
  });
}

/// Worker の照合は1回 1000 件まで。
const checkBatch = 1000;

/// 二段で照合する。まずサイズだけ送り、同じサイズが Worker か選択の中にある物だけ端末でハッシュを取る。
/// 5万枚の選択でも全部を読む必要はなく、ほとんどのファイルは1段目だけで終わる。
Future<UploadCheckOutcome> runUploadCheck({
  required ObjectChecker check,
  required String lib,
  required List<UploadSource> sources,
  UploadHasher hasher = hashUploadSource,
  int maxCalls = 10,
  Duration budget = const Duration(seconds: 20),
  Duration retryDelay = const Duration(seconds: 1),
  bool Function()? cancelled,
}) async {
  bool stop() => cancelled?.call() ?? false;
  final unresolved = <int>{};
  final known = <int>[];
  for (var i = 0; i < sources.length; i++) {
    if (sources[i].size > 0) {
      known.add(i);
    } else {
      // サイズが分からない物は1段目で絞れない。全部読むと重いので確かめずに上げる
      unresolved.add(i);
    }
  }

  // 1段目: サイズだけ
  final sizeMatches = <int, int>{};
  try {
    for (var s = 0; s < known.length; s += checkBatch) {
      final part = known.sublist(
          s, s + checkBatch > known.length ? known.length : s + checkBatch);
      final r = await check(lib, [
        for (final i in part) (size: sources[i].size, sha256: null),
      ]);
      if (stop()) return const UploadCheckOutcome(status: UploadCheckStatus.failed);
      for (var k = 0; k < part.length && k < r.results.length; k++) {
        sizeMatches[part[k]] = r.results[k].sizeMatches;
      }
    }
  } on ApiError catch (e) {
    return UploadCheckOutcome(
        status: e.status == 404
            ? UploadCheckStatus.unsupported
            : UploadCheckStatus.failed);
  }

  final sizeCount = <int, int>{};
  for (final i in known) {
    sizeCount.update(sources[i].size, (n) => n + 1, ifAbsent: () => 1);
  }
  final candidates = [
    for (final i in known)
      if ((sizeMatches[i] ?? 0) > 0 || sizeCount[sources[i].size]! > 1) i,
  ];

  // 2段目: 候補だけ端末で計算する。同時に読むと端末が重くなるので1件ずつ
  final hashes = <int, String>{};
  for (final i in candidates) {
    if (stop()) return const UploadCheckOutcome(status: UploadCheckStatus.failed);
    try {
      hashes[i] = await hasher(sources[i]);
    } on Exception catch (e) {
      debugPrint('upload duplicate hash failed for ${sources[i].name}: $e');
      unresolved.add(i);
    }
  }

  final flags = <int, UploadDuplicate>{};
  final firstOf = <String, int>{};
  for (final i in candidates) {
    final h = hashes[i];
    if (h == null) continue;
    final first = firstOf.putIfAbsent(h, () => i);
    if (first != i) flags[i] = UploadDuplicate(sameAs: first);
  }

  final ask = [
    for (final i in candidates)
      if (hashes[i] != null && (sizeMatches[i] ?? 0) > 0) i,
  ];
  var status = UploadCheckStatus.done;
  final stored = <int, MediaItem>{};
  try {
    for (var s = 0; s < ask.length; s += checkBatch) {
      final part =
          ask.sublist(s, s + checkBatch > ask.length ? ask.length : s + checkBatch);
      final body = [
        for (final i in part) (size: sources[i].size, sha256: hashes[i]),
      ];
      final clock = Stopwatch()..start();
      var pending = 0;
      for (var call = 0; call < maxCalls; call++) {
        if (call > 0) await Future<void>.delayed(retryDelay);
        if (stop()) return const UploadCheckOutcome(status: UploadCheckStatus.failed);
        final r = await check(lib, body);
        if (stop()) return const UploadCheckOutcome(status: UploadCheckStatus.failed);
        for (var k = 0; k < part.length && k < r.results.length; k++) {
          final m = r.results[k].matches;
          if (m.isNotEmpty) stored.putIfAbsent(part[k], () => m.first);
        }
        pending = r.pending;
        // Worker が保存済みの候補を計算しきれていない間だけ呼び直す。待ち続けてアップロードを止めない
        if (pending == 0 || clock.elapsed >= budget) break;
      }
      if (pending > 0) {
        for (final i in part) {
          if (!stored.containsKey(i)) unresolved.add(i);
        }
      }
    }
  } on ApiError catch (e) {
    status = e.status == 404
        ? UploadCheckStatus.unsupported
        : UploadCheckStatus.failed;
    // 照合できなかったライブラリ側は分からないまま。選択の中の重なりは確かなので残す
    for (final i in ask) {
      if (!stored.containsKey(i) && status == UploadCheckStatus.failed) {
        unresolved.add(i);
      }
    }
  }
  for (final e in stored.entries) {
    flags[e.key] = UploadDuplicate(stored: e.value);
  }
  return UploadCheckOutcome(
      status: status, flags: flags, hashes: hashes, unresolved: unresolved);
}

/// 確認シートを開いている間の照合と、1件ごとの「スキップ／それでも上げる」を持つ。
class UploadCheckController extends ChangeNotifier {
  UploadCheckController(this.sources, this._run);

  final List<UploadSource> sources;
  final Future<UploadCheckOutcome> Function(bool Function() cancelled) _run;

  UploadCheckOutcome? outcome;

  /// 「それでも上げる」を選んだ位置。既定は全部スキップ。
  final Set<int> forced = {};
  bool _disposed = false;

  bool get checking => outcome == null;

  void start() {
    unawaited(_start());
  }

  Future<void> _start() async {
    UploadCheckOutcome r;
    try {
      r = await _run(() => _disposed);
    } on Exception catch (e) {
      // 照合はアップロードの前置きにすぎない。何が起きても止めずに上げる
      debugPrint('upload duplicate check failed: $e');
      r = const UploadCheckOutcome(status: UploadCheckStatus.failed);
    }
    if (_disposed) return;
    outcome = r;
    notifyListeners();
  }

  void setForced(int index, bool upload) {
    if (upload) {
      forced.add(index);
    } else {
      forced.remove(index);
    }
    notifyListeners();
  }

  /// 印が付いてスキップのままの位置。
  Iterable<int> get skipped =>
      (outcome?.flags.keys ?? const <int>[]).where((i) => !forced.contains(i));

  /// 積む物。スキップを外し、計算済みのハッシュを添える。照合が終わっていなければ全部そのまま。
  List<UploadSource> toUpload() {
    final o = outcome;
    if (o == null) return sources;
    final skip = skipped.toSet();
    return [
      for (var i = 0; i < sources.length; i++)
        if (!skip.contains(i)) sources[i].withSha256(o.hashes[i]),
    ];
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
