import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../api/client.dart';
import '../api/models.dart';
import 'signature_source.dart';

/// 照合の進み具合。[done] は署名か失敗の印を作り終えた件数（送るのに失敗した物は数え直す）
class BackfillProgress {
  final int done;
  final int total;

  /// この端末では作れず残した件数（Web でサムネが無い物）。画面で「この端末では照合できない物」と出す
  final int deferredHere;

  /// 読めない・大きすぎるとして失敗の印を付けた件数
  final int failed;

  /// 通信の失敗などで、この周回では作れなかった件数
  final int errors;
  final int stored;
  final int stale;
  const BackfillProgress({
    this.done = 0,
    this.total = 0,
    this.deferredHere = 0,
    this.failed = 0,
    this.errors = 0,
    this.stored = 0,
    this.stale = 0,
  });
}

enum BackfillEnd {
  /// 全 shard を見終え、この端末で作れる物は作った
  completed,

  /// 止められた。もう一度 [SignatureBackfill.run] を呼べば止めた所から続ける
  cancelled,

  /// 何周しても進まなくなった。同じ物で詰まり続けて画面を回し続けないために打ち切った
  stalled,

  /// Worker の方式が違う（409 alg_mismatch）。アプリの更新が要る
  appUpdateNeeded,

  /// todo が読めなかった（古い Worker の 404 を含む）
  failed,
}

class BackfillResult {
  final BackfillEnd end;
  final BackfillProgress progress;
  final Object? error;
  const BackfillResult(this.end, this.progress, {this.error});
}

/// まだ署名の無い画像を shard 0..31 の順に todo で読み、署名を作って Worker に送る。
/// 画面を離れたら止め、次に開いた時は止めた所から続ける（Worker は送った物を todo に返さないので、
/// 止めたページの頭から読み直しても二重には作らない）。
class SignatureBackfill {
  SignatureBackfill({
    required this.api,
    required this.lib,
    required this.source,
    int? concurrency,
    this.total = 0,
    this.postEvery = 100,
    this.pageLimit = 300,
    this.shards = 32,
    this.postLimit,
    this.onProgress,
  }) : concurrency = concurrency ?? (kIsWeb ? 3 : 6);

  /// Worker が status で伝えた 1 回の上限（SIMILAR_SIG_BATCH）。null なら [maxPostBatch]
  final int? postLimit;

  final ApiClient api;
  final String lib;
  final SignatureSource source;

  /// 同時に作る件数。Web は画素の計算が画面と同じスレッドで回るので少なくする
  final int concurrency;

  /// 見込みの総数（status の pending）。表示にだけ使う
  int total;
  final int postEvery;
  final int pageLimit;
  final int shards;
  final void Function(BackfillProgress progress)? onProgress;

  /// 何周しても数が増えん時に打ち切る回数（DuplicatesController.stallLimit と同じ考え）
  static const stallLimit = 3;

  /// Worker が 1 回に受ける上限（SIMILAR_SIG_BATCH）
  static const maxPostBatch = 200;

  int _shard = 0;
  String? _after;
  int _idle = 0;
  bool _cancelled = false;
  bool _appUpdate = false;
  bool _finished = false;
  Future<BackfillResult>? _running;

  final Set<String> _done = {};
  final Set<String> _deferred = {};
  final Set<String> _failed = {};
  final Set<String> _errors = {};
  int _stored = 0;
  int _stale = 0;
  int _passGain = 0;
  int _passStale = 0;

  final List<SignatureUpload> _buffer = [];
  Future<void> _postChain = Future.value();

  bool get running => _running != null;

  BackfillProgress get progress => BackfillProgress(
    done: _done.length,
    total: total,
    deferredHere: _deferred.length,
    failed: _failed.length,
    errors: _errors.length,
    stored: _stored,
    stale: _stale,
  );

  void _notify() => onProgress?.call(progress);

  /// 進んでいる最中に呼ばれたら、その同じ実行を返す（二重に回さない）
  Future<BackfillResult> run() => _running ??= _run().whenComplete(() {
    _running = null;
  });

  /// 新しい項目には手を付けず、作り終えた分だけ送ってから止まる
  void cancel() => _cancelled = true;

  bool get _stop => _cancelled || _appUpdate;

  Future<BackfillResult> _run() async {
    if (_finished) _reset();
    _cancelled = false;
    _appUpdate = false;
    for (;;) {
      while (_shard < shards) {
        final SimilarTodoPage page;
        try {
          page = await api.similarTodo(
            lib,
            _shard,
            after: _after,
            limit: pageLimit,
          );
        } on Object catch (e) {
          return BackfillResult(BackfillEnd.failed, progress, error: e);
        }
        if (_stop) break;
        await _processPage(page.items);
        _enqueuePost(force: true);
        await _postChain;
        if (_stop) break;
        // 止めた時は進めない: 次はこのページの頭から読み直す
        if (page.next == null) {
          _shard++;
          _after = null;
        } else {
          _after = page.next;
        }
      }
      if (_appUpdate) {
        return BackfillResult(BackfillEnd.appUpdateNeeded, progress);
      }
      if (_cancelled) return BackfillResult(BackfillEnd.cancelled, progress);
      // 通信の失敗と、送る間に中身が入れ替わった物は todo に残るので、もう一周して拾い直す
      final retry = _errors.isNotEmpty || _passStale > 0;
      if (!retry) {
        _finished = true;
        return BackfillResult(BackfillEnd.completed, progress);
      }
      _idle = _passGain == 0 ? _idle + 1 : 0;
      if (_idle >= stallLimit) {
        _finished = true;
        return BackfillResult(BackfillEnd.stalled, progress);
      }
      _shard = 0;
      _after = null;
      _passGain = 0;
      _passStale = 0;
      _errors.clear();
      _notify();
    }
  }

  void _reset() {
    _finished = false;
    _shard = 0;
    _after = null;
    _idle = 0;
    _passGain = 0;
    _passStale = 0;
    _stored = 0;
    _stale = 0;
    _done.clear();
    _deferred.clear();
    _failed.clear();
    _errors.clear();
  }

  Future<void> _processPage(List<SimilarTodoItem> items) async {
    var next = 0;
    Future<void> worker() async {
      while (!_stop && next < items.length) {
        final t = items[next++];
        SignatureOutcome out;
        try {
          out = await source.sign(t);
        } on Object catch (e) {
          out = SignatureOutcome.error(e);
        }
        _record(t, out);
      }
    }

    await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);
  }

  void _record(SimilarTodoItem t, SignatureOutcome out) {
    switch (out.kind) {
      case SignatureOutcomeKind.signed:
      case SignatureOutcomeKind.failed:
        if (out.kind == SignatureOutcomeKind.failed) _failed.add(t.key);
        _errors.remove(t.key);
        _done.add(t.key);
        _buffer.add(out.upload!);
        _enqueuePost();
      case SignatureOutcomeKind.deferred:
        _deferred.add(t.key);
      case SignatureOutcomeKind.error:
        _errors.add(t.key);
        debugPrint('signature failed: ${t.key}: ${out.error}');
    }
    _notify();
  }

  /// 送るのは常に 1 本だけ。重ねると同じ shard の書き込みが Worker 側で取り合いになる
  void _enqueuePost({bool force = false}) {
    if (!_due(force)) return;
    _postChain = _postChain.then((_) => _drain(force));
  }

  /// 1 回に送る上限。Worker が env で下げていればそれに合わせる（超えると 400 で全部断られる）
  int get _postCap {
    final limit = postLimit;
    return limit == null || limit >= maxPostBatch ? maxPostBatch : math.max(1, limit);
  }

  int get _every => postEvery < _postCap ? postEvery : _postCap;

  bool _due(bool force) =>
      _buffer.length >= _every || (force && _buffer.isNotEmpty);

  Future<void> _drain(bool force) async {
    while (_due(force)) {
      if (_appUpdate) {
        _buffer.clear();
        return;
      }
      // 途中は 100 件ちょうどで切り、ページの終わりだけ残りをまとめて送る（Worker の上限 200 まで）
      final cap = force ? _postCap : _every;
      final n = _buffer.length < cap ? _buffer.length : cap;
      final batch = _buffer.sublist(0, n);
      _buffer.removeRange(0, n);
      try {
        final r = await api.postSignatures(lib, batch);
        _stored += r.stored;
        _stale += r.stale;
        _passStale += r.stale;
        _passGain += r.stored + r.failRecorded;
      } on ApiError catch (e) {
        if (e.status == 409 && e.code == 'alg_mismatch') {
          _appUpdate = true;
          for (final u in [...batch, ..._buffer]) {
            _done.remove(u.key);
          }
          _buffer.clear();
          _notify();
          return;
        }
        _unsent(batch, e);
      } on Object catch (e) {
        _unsent(batch, e);
      }
      _notify();
    }
  }

  /// 送れなかった分は作っていない扱いに戻し、次の周回で作り直す（Worker には届いていないので）
  void _unsent(List<SignatureUpload> batch, Object e) {
    debugPrint('signature post failed (${batch.length}): $e');
    for (final u in batch) {
      _done.remove(u.key);
      _failed.remove(u.key);
      _errors.add(u.key);
    }
  }
}
