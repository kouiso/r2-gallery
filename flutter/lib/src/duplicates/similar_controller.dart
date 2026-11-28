import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../state/trash_ops.dart';
import 'signature_backfill.dart';
import 'signature_source.dart';

/// 画面の段階。hashScan → status → (consent) → signing → loading → ready の順に進む
enum SimilarPhase {
  /// 従来の重複（SHA-256）の計算を進めている
  hashScan,

  /// 見た目の照合がどこまで済んだかを聞いている
  status,

  /// 照合が多く通信量がかさむので、始める前に利用者の同意を待っている
  consent,

  /// この端末で署名を作って送っている
  signing,
  loading,
  ready,
  error,

  /// Worker が古く /similar が無い（404）。画面は従来の DuplicatesScreen に切り替える
  unsupported,
}

const similarTabDup = 'dup';
const similarTabSimilar = 'similar';

/// 組の見分け。同じオリジナルが「重複」と「似ている」の両方の組の頭になり得て、どちらも id はそのキーなので段と組にする
typedef SimilarGroupId = ({String tier, String id});

/// relabel で新しいオリジナルとは別物と分かった項目の札。消す対象にも数えない
const similarMatchNone = 'none';

/// Worker の一覧が古いと分かる失敗。端末の組分けをそのまま使い続けると同じ失敗を繰り返すので読み直す。
/// source_not_found は別の端末やビューアで先に消された物、keeper_targeted は残す物を同じ回で消そうとした物
const _staleErrors = {
  'keeper_missing',
  'not_similar',
  'stale_signature',
  'source_not_found',
  'keeper_targeted',
};

/// 画面で持つ1組。オリジナルは利用者が選び直せ、札も付け直すので Worker の応答とは別に持つ
class SimilarGroupView {
  SimilarGroupView._(this.id, this.tier, this.members, this.more, this.keeper);

  factory SimilarGroupView.from(SimilarGroup g) {
    final members = [...g.members];
    final keeper = members.where((m) => m.isKeeper).firstOrNull?.key ?? g.id;
    final v = SimilarGroupView._(g.id, g.tier, members, g.more, keeper);
    // 応答に載らなかった分（more）の容量は手元で数えられないので、Worker の合計との差として持っておく
    v._hiddenReclaim = math.max(0, g.reclaim - v._loadedReclaim);
    return v;
  }

  final String id;
  final String tier;
  final List<SimilarMember> members;

  /// 応答に載らなかった件数
  final int more;
  String keeper;

  /// 今のオリジナルとは別物と分かった項目。選べないようにする
  final Set<String> disabled = {};
  int _hiddenReclaim = 0;

  /// オリジナルの付け直しを Worker に聞いている最中
  bool relabeling = false;

  SimilarGroupId get gid => (tier: tier, id: id);

  bool isKeeper(SimilarMember m) => m.key == keeper;

  SimilarMember? member(String key) =>
      members.where((m) => m.key == key).firstOrNull;

  /// 利用者が1件ずつなら選べるか（反転・差分かもも含む）。オリジナルと別物は選ばせない
  bool canSelect(SimilarMember m) =>
      !isKeeper(m) && !disabled.contains(m.key) && m.match != similarMatchNone;

  /// 組のチェックや「すべての重複」で拾う物。反転・差分かも・似ている物は別の絵のことがあるので、
  /// 重複の段では拾わず1件ずつ選ばせる
  bool bulkEligible(SimilarMember m) {
    if (!canSelect(m)) return false;
    if (tier == similarTabDup) {
      return (m.match == 'identical' || m.match == 'same') && !m.variant;
    }
    return m.match == 'similar';
  }

  /// 空けられる容量。Worker と同じく、重複の段の「反転でも差分かもでもない」物だけを数える
  int get reclaim => _loadedReclaim + _hiddenReclaim;

  int get _loadedReclaim {
    if (tier != similarTabDup) return 0;
    var sum = 0;
    for (final m in members) {
      if ((m.match == 'identical' || m.match == 'same') &&
          !m.variant &&
          canSelect(m)) {
        sum += m.size;
      }
    }
    return sum;
  }
}

/// ゴミ箱へ送るために一覧から外した1件。失敗・中止の時に元の組・元の位置へ戻すために残す
class RemovedSimilar {
  final SimilarGroupId gid;
  final SimilarMember member;
  final String keeper;

  /// 外す前の組の並び（キー）。何件か戻らない物があっても、残った前の項目の直後へ戻せるように
  final List<String> before;

  /// 外す前の段の組の並び（id）。組ごと消えた時に元の位置へ戻すため
  final List<String> groupOrder;
  const RemovedSimilar({
    required this.gid,
    required this.member,
    required this.keeper,
    required this.before,
    required this.groupOrder,
  });
}

/// まとめてゴミ箱へ送った結果
class SimilarCommitResult {
  /// 元に戻せる分。直後の「元に戻す」で [SimilarController.undo] に渡す
  final List<TrashReceipt> receipts;

  /// Worker が確かめ直した種類ごとの件数（identical / same / mirror / similar）
  final Map<String, int> kinds;

  /// 送ったが移せなかった件数。行は元の場所に戻してある
  final int failed;

  /// 移せなかったキーと理由
  final Map<String, String> errors;

  /// 中止して送らなかった件数。行は元の場所に戻してある
  final int unsent;

  /// 移せたが trashKey が返らず戻せない物
  final List<String> unrestorable;

  /// 一覧が古いと分かった。画面は読み直す
  final bool needsReload;

  /// 選んだが、選んだ別の物の残す物になっていたので送らずに残した件数
  final int keptAsKeeper;

  /// 別の削除を送っている最中で、受け付けなかった
  final bool busy;

  /// 移せなかったので元へ戻そうとしたが、それにも失敗してゴミ箱に残った物（put_back_failed）。
  /// 元の場所には無いので一覧へは戻さない。直後の「元に戻す」には入らず、ゴミ箱の画面から戻せる
  final List<String> leftInTrash;
  const SimilarCommitResult({
    this.receipts = const [],
    this.kinds = const {},
    this.failed = 0,
    this.errors = const {},
    this.unsent = 0,
    this.unrestorable = const [],
    this.needsReload = false,
    this.keptAsKeeper = 0,
    this.busy = false,
    this.leftInTrash = const [],
  });

  int get trashed => receipts.length + unrestorable.length;

  /// 既存の「元に戻す」スナックバー（offerOptimisticTrashUndo）に渡す形
  TrashOutcome outcome(String lib) => TrashOutcome(
    receipts,
    trashed,
    failed,
    failedTargets: [for (final k in errors.keys) (lib: lib, key: k)],
    unrestorable: [for (final k in unrestorable) (lib: lib, key: k)],
  );
}

typedef _Target = ({SimilarGroupView group, SimilarMember member});

/// 確かめの画面を開いた時の選択の写し。[SimilarController.commit] に渡すと、送るのはこの中の物だけになる
/// （開いている間に「すべての重複」の読み込みが終わる・オリジナルを付け直す、で選択が増えても送らない）
class SimilarSelection {
  SimilarSelection._(this._targets);
  final List<_Target> _targets;

  int get count => _targets.length;

  /// 種類ごとの件数（identical / same / mirror / similar）
  Map<String, int> get kinds {
    final out = <String, int>{};
    for (final t in _targets) {
      out[t.member.match] = (out[t.member.match] ?? 0) + 1;
    }
    return out;
  }

  /// うち「差分かも」
  int get variants => _targets.where((t) => t.member.variant).length;
}

/// 重複・似ている写真の画面の状態。従来の SHA-256 の計算を進め切り、見た目の署名を補ってから組を読む
class SimilarController extends ChangeNotifier {
  SimilarController({
    required this.api,
    required this.lib,
    this.readOnly = false,
    SignatureSource? source,
    bool? isWeb,
    this.pageSize = 50,
    this.consentThreshold = 300,
    this.signConcurrency,
    this.trashChunk = 40,
    this.inFlight = 2,
    this.undoRetryDelays = const [Duration(seconds: 1), Duration(seconds: 3)],
  }) : isWeb = isWeb ?? kIsWeb,
       _sourceOverride = source;

  final ApiClient api;
  final String lib;

  /// 読み取り専用ライブラリ。選択も削除もさせない（Worker も 403 で弾く）
  final bool readOnly;
  final bool isWeb;
  final int pageSize;

  /// これより多く照合が残っていたら、通信量を見せて同意を取ってから始める
  final int consentThreshold;
  final int? signConcurrency;

  /// Worker が 1 回に受ける件数の上限（SIMILAR_TRASH_BATCH の最大）
  final int trashChunk;

  /// 実際に分ける件数。Worker が env で下げていれば status の値に合わせる（超えると塊ごと 400 になり、
  /// 消すのも「元に戻す」も通らない）
  int get _chunkSize {
    final server = status?.trashBatch;
    return math.max(
      1,
      server == null ? trashChunk : math.min(trashChunk, server),
    );
  }

  /// 同時に送る要求の数。増やすと albums.json の書き込みが取り合いになる
  final int inFlight;

  /// 「元に戻す」でファイルは戻ったのにアルバムを書けなかった物（albums_failed）を、呼び直す前の待ち。
  /// Worker は控えを残しているので、同じ受け取りで呼び直せばアルバムだけが直る。ゴミ箱の画面には
  /// もう出ないので、ここで呼び直さないとアルバムの所属を戻す道が無くなる
  final List<Duration> undoRetryDelays;

  final SignatureSource? _sourceOverride;

  SimilarPhase phase = SimilarPhase.hashScan;
  String? error;

  /// 画像が多すぎて Worker が見た目の照合を断った（status の tooMany か、一覧の 413）。
  /// [phase] は unsupported で、画面は従来の重複の画面に理由を添えて出す
  bool tooManyForSimilar = false;

  // ---- 中身（SHA-256）の計算 ----
  /// 計算待ちの残り。最初の応答が来るまでは null
  int? scanPending;
  int scanSkipped = 0;

  // ---- 見た目の照合 ----
  SimilarStatus? status;
  BackfillProgress? signProgress;
  BackfillEnd? signEnd;

  /// Worker の署名方式が新しく、このアプリでは作れない（409 alg_mismatch）
  bool appUpdateNeeded = false;
  SignatureBackfill? _backfill;

  // ---- 組 ----
  final List<SimilarGroupView> dupGroups = [];
  final List<SimilarGroupView> simGroups = [];
  String? dupCursor;
  String? simCursor;
  SimilarSummary summary = const SimilarSummary();
  final Map<String, bool> loadingMore = {};
  final Map<String, bool> moreFailed = {};

  /// 「すべての重複」の前に残りのページを読んでいる
  bool loadingAll = false;

  /// 選んだ項目のキーと、その項目の組
  final Map<String, SimilarGroupId> selected = {};

  /// 利用者が選び直したオリジナル。読み直した後も同じ組なら選び直しを保つ
  final Map<SimilarGroupId, String> keeperOverride = {};

  /// 一括の削除が古い一覧に基づいていたと分かった。画面は [reload] する
  bool needsReload = false;

  // ---- 削除の進み具合 ----
  bool committing = false;
  int commitDone = 0;
  int commitTotal = 0;
  bool _cancelCommit = false;

  bool _disposed = false;
  int _run = 0;
  int _selectAllRun = 0;

  /// 読み直すたびに増やす。古い一覧に向けた「元の場所へ戻す」を、読み直した新しい一覧に当てないため
  int _generation = 0;
  final Map<SimilarGroupId, SimilarGroupView> _dropped = {};
  final Map<String, int> _groupAdjust = {};
  int _reclaimAdjust = 0;

  /// 何度呼んでも数が減らん時に打ち切る回数（DuplicatesController と同じ）
  static const stallLimit = 3;

  /// サムネ1枚の見込み（Worker の pendingBytesEstimate と同じ 40 KiB）
  static const thumbBytesEstimate = 40960;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  bool _stale(int run) => _disposed || run != _run;

  SignatureSource get _source =>
      _sourceOverride ??
      ApiSignatureSource(api: api, lib: lib, writable: !readOnly, isWeb: isWeb);

  // ---------------------------------------------------------------- 段階

  Future<void> start() async {
    final run = ++_run;
    // やり直しでは新しく回す。Worker は送った物を todo に返さないので、頭から読み直しても二重には作らない
    _backfill?.cancel();
    _backfill = null;
    signProgress = null;
    signEnd = null;
    phase = SimilarPhase.hashScan;
    error = null;
    exactFallback = false;
    tooManyForSimilar = false;
    scanPending = null;
    _notify();
    try {
      var idle = 0;
      for (;;) {
        final r = await api.duplicateScan(lib);
        if (_stale(run)) return;
        scanPending = r.pending;
        scanSkipped = r.skipped;
        _notify();
        if (r.pending == 0) break;
        idle = r.hashed == 0 ? idle + 1 : 0;
        if (idle >= stallLimit) break;
      }
    } on Object catch (e) {
      if (_stale(run)) return;
      _fail(e, '重複の確認を進められませんでした');
      return;
    }

    phase = SimilarPhase.status;
    _notify();
    try {
      status = await api.similarStatus(lib);
    } on Object catch (e) {
      if (_stale(run)) return;
      _fail(e, '見た目の照合の状況を読めませんでした', afterHashScan: true);
      return;
    }
    if (_stale(run)) return;
    if (status?.tooMany ?? false) {
      // 画像が上限を超えると Worker は一覧を 413 で断る。照合（数 GB の通信と数十分）を始める前に
      // 従来の画面へ替え、理由を出す（作り終えてから断られると、使った時間と通信が無駄になる）
      tooManyForSimilar = true;
      phase = SimilarPhase.unsupported;
      _notify();
      return;
    }
    final work = consentCount;
    if (work <= 0) return reload(run: run);
    if (work > consentThreshold) {
      phase = SimilarPhase.consent;
      _notify();
      return;
    }
    await _sign(run);
  }

  void _fail(Object e, String message, {bool afterHashScan = false}) {
    // 古い Worker（404）と、大きすぎて見た目の照合を断るライブラリ（413）は、従来の重複の画面に替える。
    // 同じファイルの組は Worker がそのまま出せるので、この画面が開けないせいで見えなくしない
    if (e is ApiError &&
        (e.status == 404 ||
            (e.status == 413 && e.code == 'too_many_for_similar'))) {
      tooManyForSimilar = e.status == 413;
      phase = SimilarPhase.unsupported;
    } else {
      phase = SimilarPhase.error;
      error = message;
      exactFallback = afterHashScan;
    }
    _notify();
  }

  /// 見た目の照合の口が失敗した時に、従来の重複（SHA-256）の画面を出せるか。
  /// 中身の計算は済んでいるので、その画面なら同じファイルの組は見られる
  bool exactFallback = false;

  /// エラーの画面の「同じファイルだけを探す」。従来の重複の画面に替える
  void useExactScreen() {
    if (phase != SimilarPhase.error || !exactFallback) return;
    _run++;
    _backfill?.cancel();
    phase = SimilarPhase.unsupported;
    _notify();
  }

  /// この端末で照合する件数。Web は原本からサムネを作れないので、サムネのある物だけを数える
  int get consentCount {
    final s = status;
    if (s == null) return 0;
    return isWeb ? s.pendingWithThumb : s.pending;
  }

  /// 照合にかかる通信量の見込み（バイト）
  int get consentBytes {
    final s = status;
    if (s == null) return 0;
    return isWeb
        ? s.pendingWithThumb * thumbBytesEstimate
        : s.pendingBytesEstimate;
  }

  /// この端末では照合できず残した件数（Web でサムネの無い物）
  int get deferredHere {
    final p = signProgress;
    if (p != null) return p.deferredHere;
    return isWeb ? (status?.pendingNoThumb ?? 0) : 0;
  }

  /// 同意の画面で「この端末で照合する」
  Future<void> startSigning() async {
    if (phase != SimilarPhase.consent) return;
    await _sign(_run);
  }

  /// 同意の画面で「あとで（今の結果を見る）」
  Future<void> skipSigning() async {
    if (phase != SimilarPhase.consent) return;
    await reload(run: _run);
  }

  /// 「途中の結果を見る」。作り終えた分を送ってから止まり、そのまま一覧を読む
  void stopSigning() => _backfill?.cancel();

  Future<void> _sign(int run) async {
    phase = SimilarPhase.signing;
    appUpdateNeeded = false;
    _notify();
    final b = _backfill ??= SignatureBackfill(
      api: api,
      lib: lib,
      source: _source,
      concurrency: signConcurrency,
      postLimit: status?.sigBatch,
      onProgress: (p) {
        signProgress = p;
        _notify();
      },
    );
    b.total = consentCount;
    final r = await b.run();
    if (_stale(run)) return;
    signProgress = r.progress;
    signEnd = r.end;
    appUpdateNeeded = r.end == BackfillEnd.appUpdateNeeded;
    // 照合が途中で止まっても、それまでの結果と従来の重複は見せる
    await reload(run: run);
  }

  // ---------------------------------------------------------------- 一覧

  /// 両方の段を先頭のページから読み直す。選択は組が変わり得るので捨てる
  Future<void> reload({int? run}) async {
    final r = run ?? ++_run;
    if (run == null) _backfill?.cancel();
    phase = SimilarPhase.loading;
    _notify();
    final List<SimilarPage> pages;
    try {
      pages = await Future.wait([
        api.similarGroups(lib, similarTabDup, limit: pageSize),
        api.similarGroups(lib, similarTabSimilar, limit: pageSize),
      ]);
    } on Object catch (e) {
      if (_stale(r)) return;
      _fail(e, '重複・似ている写真の一覧を読めませんでした', afterHashScan: true);
      return;
    }
    if (_stale(r)) return;
    _generation++;
    _selectAllRun++;
    loadingAll = false;
    dupGroups.clear();
    simGroups.clear();
    _dropped.clear();
    _groupAdjust.clear();
    _reclaimAdjust = 0;
    selected.clear();
    needsReload = false;
    loadingMore.clear();
    moreFailed.clear();
    dupGroups.addAll(_views(pages[0].groups, dupGroups));
    simGroups.addAll(_views(pages[1].groups, simGroups));
    dupCursor = pages[0].cursor;
    simCursor = pages[1].cursor;
    summary = pages[0].summary;
    phase = SimilarPhase.ready;
    error = null;
    _notify();
    await _reapplyKeepers();
  }

  List<SimilarGroupView> groupsOf(String tier) =>
      tier == similarTabDup ? dupGroups : simGroups;

  String? cursorOf(String tier) =>
      tier == similarTabDup ? dupCursor : simCursor;

  void _setCursor(String tier, String? c) {
    if (tier == similarTabDup) {
      dupCursor = c;
    } else {
      simCursor = c;
    }
  }

  List<SimilarGroupView> _views(
    List<SimilarGroup> page,
    List<SimilarGroupView> existing,
  ) {
    final out = <SimilarGroupView>[];
    for (final g in page) {
      // 削除でページの境目がずれても、同じ組を二度出さない
      if (g.members.length < 2 ||
          existing.any((v) => v.id == g.id) ||
          out.any((v) => v.id == g.id)) {
        continue;
      }
      out.add(SimilarGroupView.from(g));
    }
    return out;
  }

  Future<void> loadMore(String tier) async {
    final c = cursorOf(tier);
    if (c == null ||
        loadingMore[tier] == true ||
        loadingAll ||
        phase != SimilarPhase.ready) {
      return;
    }
    final gen = _generation;
    loadingMore[tier] = true;
    moreFailed[tier] = false;
    _notify();
    try {
      final page = await api.similarGroups(
        lib,
        tier,
        cursor: c,
        limit: pageSize,
      );
      if (_disposed || gen != _generation) return;
      // 待つ間に「すべての重複」が残りを読み切っていたら、このページは古い。続きの位置を
      // 書き戻すと、読み切ったのに「まだある」になり、選択も一部扱いに戻ってしまう
      if (cursorOf(tier) == c) {
        final list = groupsOf(tier);
        list.addAll(_views(page.groups, list));
        _setCursor(tier, page.cursor);
      }
    } on Object {
      if (_disposed || gen != _generation) return;
      moreFailed[tier] = true;
    } finally {
      if (gen == _generation) loadingMore[tier] = false;
    }
    _notify();
    // 後のページで読んだ組にも、前に選び直したオリジナルを当てる（読み直しで先頭のページに居なかった組）
    if (gen == _generation) await _reapplyKeepers();
  }

  /// 組の数（ページに依らない全体）。削除して消えた組を差し引く
  int groupCount(String tier) {
    final base = tier == similarTabDup
        ? summary.dup.groups
        : summary.similar.groups;
    return math.max(0, base + (_groupAdjust[tier] ?? 0));
  }

  /// 重複の段で空けられる容量（全体）。手元で消した分・オリジナルを替えた分を足し引きする
  int get dupReclaimable =>
      math.max(0, summary.dup.reclaimable + _reclaimAdjust);

  /// 読み込んだ重複の組のうち、応答に載らず選べない件数。「空けられます」の合計には入っているので、
  /// 「すべての重複」の合計がそれより小さい理由として見せる
  int get dupHidden => dupGroups.fold(0, (s, g) => s + g.more);

  SimilarGroupView? _find(SimilarGroupId gid) =>
      groupsOf(gid.tier).where((g) => g.id == gid.id).firstOrNull;

  /// 組の容量の変化を全体の合計に映す
  void _tracked(SimilarGroupView g, void Function() change) {
    final before = g.reclaim;
    change();
    if (g.tier == similarTabDup) _reclaimAdjust += g.reclaim - before;
  }

  // ---------------------------------------------------------------- 選択

  bool isSelected(String key) => selected.containsKey(key);

  /// 1件ずつの選択。オリジナルと、オリジナルと別物と分かった物は選べない
  void toggle(SimilarGroupView g, SimilarMember m, [bool? on]) {
    if (readOnly ||
        g.relabeling ||
        !g.canSelect(m) ||
        g.member(m.key) == null) {
      return;
    }
    final next = on ?? !selected.containsKey(m.key);
    if (next) {
      selected[m.key] = g.gid;
    } else {
      selected.remove(m.key);
    }
    _notify();
  }

  /// 組のチェックの状態。全部 true・一つも無し false・一部 null
  bool? groupState(SimilarGroupView g) {
    final eligible = g.members.where(g.bulkEligible).toList();
    final any = g.members.any((m) => selected.containsKey(m.key));
    if (!any) return false;
    if (eligible.isNotEmpty &&
        eligible.every((m) => selected.containsKey(m.key))) {
      return true;
    }
    return null;
  }

  /// 組のチェック。入れる時は段の決まりで拾える物だけ、外す時は1件ずつ選んだ物も含めて外す
  void setGroupSelected(SimilarGroupView g, bool on) {
    if (readOnly || g.relabeling) return;
    if (on) {
      for (final m in g.members) {
        if (g.bulkEligible(m)) selected[m.key] = g.gid;
      }
    } else {
      for (final m in g.members) {
        selected.remove(m.key);
      }
    }
    _notify();
  }

  List<String> get _dupEligible => [
    for (final g in dupGroups)
      for (final m in g.members)
        if (g.bulkEligible(m)) m.key,
  ];

  /// 「すべての重複」で選べる物が読み込んだ中に1件でもあるか。読み切っていて1件も無ければ、押しても
  /// 何も選ばれないので、画面は押せなくする
  bool get dupSelectable => dupCursor != null || _dupEligible.isNotEmpty;

  /// 「すべての重複」の状態。数えるのは「すべての重複」が選ぶ物（同じファイル・ほぼ同じ）だけ。
  /// 1件ずつ選んだ反転・差分かもまで数えると、押しても全部にも空にもならない一部のまま止まる。
  /// ページを読み切っていない時は全部とは言わない
  bool? get allDupState {
    final eligible = _dupEligible;
    // 選んだ段も見る。オリジナルを選び直すと前のオリジナルが両方の段に出て、似ているの段で選んだ物まで
    // 数えると、外す時（重複の段の選択だけを外す）に外れず、全部のまま止まる
    final picked = eligible
        .where((k) => selected[k]?.tier == similarTabDup)
        .length;
    if (picked == 0) return false;
    if (dupCursor == null && picked == eligible.length) return true;
    return null;
  }

  /// 「すべての重複」。下のボタンが本当の合計を出せるよう、先に残りのページを全部読んでから選ぶ。
  /// 読み切れなければ何も選ばず false を返す（一部だけ選んで合計を小さく見せない）
  Future<bool> selectAllDup(bool on) async {
    if (readOnly) return false;
    final run = ++_selectAllRun;
    if (!on) {
      loadingAll = false;
      selected.removeWhere((_, v) => v.tier == similarTabDup);
      _notify();
      return true;
    }
    final gen = _generation;
    loadingAll = true;
    _notify();
    try {
      while (dupCursor != null) {
        final page = await api.similarGroups(
          lib,
          similarTabDup,
          cursor: dupCursor,
          limit: 100,
        );
        if (_disposed || run != _selectAllRun || gen != _generation) {
          return false;
        }
        dupGroups.addAll(_views(page.groups, dupGroups));
        dupCursor = page.cursor;
        _notify();
      }
    } on Object {
      if (_disposed || run != _selectAllRun || gen != _generation) {
        return false;
      }
      loadingAll = false;
      _notify();
      return false;
    }
    // 読んだ組に、前に選び直したオリジナルを当ててから選ぶ。当てないと、選び直したオリジナルが
    // Worker の付けた残す物の「ほぼ同じ」のままで、残すと決めた物を選んでしまう
    await _reapplyKeepers();
    if (_disposed || run != _selectAllRun || gen != _generation) return false;
    loadingAll = false;
    for (final g in dupGroups) {
      // 付け直しに失敗した組でも、選び直したオリジナルは選ばない
      final chosen = keeperOverride[g.gid];
      for (final m in g.members) {
        if (g.bulkEligible(m) && m.key != chosen) selected[m.key] = g.gid;
      }
    }
    _notify();
    return true;
  }

  Iterable<_Target> get _selectedTargets sync* {
    for (final e in selected.entries) {
      final g = _find(e.value);
      final m = g?.member(e.key);
      // オリジナルを付け替えている途中の組は送らない。付け替える先を消す物として送ると、
      // 付け替えの答えが返った時には居ない物をオリジナルにしてしまう
      if (g == null || m == null || !g.canSelect(m) || g.relabeling) continue;
      yield (group: g, member: m);
    }
  }

  int get selectedCount => _selectedTargets.length;

  int get selectedBytes =>
      _selectedTargets.fold(0, (s, t) => s + t.member.size);

  /// 確かめの文に出す種類ごとの件数（identical / same / mirror / similar）
  Map<String, int> get selectedKinds {
    final out = <String, int>{};
    for (final t in _selectedTargets) {
      out[t.member.match] = (out[t.member.match] ?? 0) + 1;
    }
    return out;
  }

  /// 選んだ中の「差分かも」。確かめの文に注意書きを足すため
  int get selectedVariants =>
      _selectedTargets.where((t) => t.member.variant).length;

  // ---------------------------------------------------------------- オリジナルの選び直し

  /// [key] をこの組のオリジナルにする。Worker に札を付け直させ、別物と分かった物は選べなくする。
  /// 失敗した時は何も変えずに理由を返す
  Future<String?> setKeeper(SimilarGroupView g, String key) async {
    if (g.keeper == key) return null;
    final target = g.member(key);
    if (target == null || g.disabled.contains(key)) {
      return 'この項目はオリジナルにできません';
    }
    if (g.relabeling) return null;
    // 同じオリジナルが頭の、もう一方の段の組。片方だけ替えると、前のオリジナルが一方では消す対象に、
    // もう一方では残す物のままになり、同じ回で両方を選ぶと残す物ごと消えかねない
    final twin = _find((
      tier: g.tier == similarTabDup ? similarTabSimilar : similarTabDup,
      id: g.id,
    ));
    final gen = _generation;
    g.relabeling = true;
    if (twin != null) twin.relabeling = true;
    _notify();
    Map<String, SimilarLabel> labels;
    Map<String, SimilarLabel>? twinLabels;
    try {
      labels = await _relabel(key, g.members);
      if (twin != null && twin.keeper != key) {
        twinLabels = await _relabel(key, twin.members);
      }
    } on Object catch (e) {
      g.relabeling = false;
      if (twin != null) twin.relabeling = false;
      _notify();
      if (e is ApiError && e.status == 403) return 'このライブラリは読み取り専用です';
      return 'オリジナルを変えられませんでした';
    }
    g.relabeling = false;
    if (twin != null) twin.relabeling = false;
    if (_disposed || gen != _generation) return null;
    // 聞いている間に、付け替える先が組から外れた（1件だけゴミ箱へ送った・ビューアで消した）。
    // 居ない物をオリジナルにはしない
    final now = g.member(key);
    if (now == null) {
      _notify();
      return 'この項目はオリジナルにできません';
    }
    final keeperMember = _relabeled(now, 'keeper');
    _applyKeeper(g, key, labels, keeperMember);
    if (twin != null && twinLabels != null) {
      _applyKeeper(twin, key, twinLabels, keeperMember);
    }
    _notify();
    return null;
  }

  /// [key] 以外の一員を [key] と比べ直す。Worker は1回 60 件まで受ける
  Future<Map<String, SimilarLabel>> _relabel(
    String key,
    List<SimilarMember> members,
  ) async {
    final labels = <String, SimilarLabel>{};
    final others = [
      for (final m in members)
        if (m.key != key) m.key,
    ];
    for (var i = 0; i < others.length; i += 60) {
      labels.addAll(
        await api.similarRelabel(
          lib,
          key,
          others.sublist(i, math.min(i + 60, others.length)),
        ),
      );
    }
    return labels;
  }

  void _applyKeeper(
    SimilarGroupView g,
    String key,
    Map<String, SimilarLabel> labels,
    SimilarMember keeperMember,
  ) {
    _tracked(g, () {
      g.disabled.clear();
      // もう一方の段の組には新しいオリジナルが載っていないことがある。頭に足して、残す物として見せる
      if (g.member(key) == null) g.members.insert(0, keeperMember);
      for (var i = 0; i < g.members.length; i++) {
        final m = g.members[i];
        if (m.key == key) {
          g.members[i] = _relabeled(m, 'keeper');
          continue;
        }
        final l = labels[m.key];
        final match = l?.match;
        if (match == null) {
          g.disabled.add(m.key);
          g.members[i] = _relabeled(m, similarMatchNone);
        } else {
          g.members[i] = _relabeled(
            m,
            match,
            ph: l!.ph,
            dh: l.dh,
            variant: l.variant,
          );
        }
      }
      g.keeper = key;
      // 応答に載らなかった分は新しいオリジナルとの関係が分からないので、空けられる容量に数えない
      g._hiddenReclaim = 0;
    });
    keeperOverride[g.gid] = key;
    selected.remove(key);
    for (final k in g.disabled) {
      selected.remove(k);
    }
  }

  SimilarMember _relabeled(
    SimilarMember m,
    String match, {
    int? ph,
    int? dh,
    bool variant = false,
  }) => SimilarMember(
    item: m.item,
    size: m.size,
    match: match,
    ph: ph,
    dh: dh,
    variant: variant,
    ow: m.ow,
    oh: m.oh,
  );

  /// 選び直したオリジナルを、読み込んだ組に当て直す。読み直した後・続きのページを読んだ後に呼ぶ。
  /// まだ読んでいないページの組の選び直しは捨てない（後で読んだ時に当てる）。捨てるのは、その段を
  /// 読み切っても組が無い時と、組にその物が居ない時だけ
  Future<void> _reapplyKeepers() async {
    final gen = _generation;
    for (final e in [...keeperOverride.entries]) {
      if (_disposed || gen != _generation) return;
      final g = _find(e.key);
      if (g == null) {
        if (cursorOf(e.key.tier) == null) keeperOverride.remove(e.key);
        continue;
      }
      if (g.member(e.value) == null) {
        keeperOverride.remove(e.key);
        continue;
      }
      if (g.keeper != e.value) await setKeeper(g, e.value);
    }
  }

  // ---------------------------------------------------------------- 削除

  /// 今の選択の写し。確かめの画面に件数を出し、同じ物を [commit] に渡す
  SimilarSelection selection() => SimilarSelection._(_selectedTargets.toList());

  /// 選んだ物をまとめてゴミ箱へ送る。一覧からはすぐ外し、移せなかった物は元の場所へ戻す。
  /// [only] を渡すと、その写しのうち今も選んでいて送れる物だけを送る（写しより多くは送らない）
  Future<SimilarCommitResult> commit([SimilarSelection? only]) {
    final now = _selectedTargets.toList();
    if (only == null) return _send(now);
    final still = {for (final t in now) t.member.key: t};
    final targets = <_Target>[
      for (final t in only._targets)
        if (still[t.member.key] case final cur?
            when identical(cur.group, t.group))
          cur,
    ];
    return _send(targets);
  }

  /// 長押しの「この1件だけゴミ箱へ」。他の選択には触らない
  Future<SimilarCommitResult> trashOne(SimilarGroupView g, SimilarMember m) {
    final cur = g.member(m.key);
    if (cur == null || !g.canSelect(cur) || g.relabeling) {
      return Future.value(const SimilarCommitResult());
    }
    return _send([(group: g, member: cur)]);
  }

  /// 送り始めた物は止めず、まだ送っていない塊だけを送らずに戻す
  void cancelCommit() => _cancelCommit = true;

  Future<SimilarCommitResult> _send(List<_Target> all) async {
    if (committing && all.isNotEmpty) {
      return const SimilarCommitResult(busy: true);
    }
    if (readOnly || all.isEmpty) return const SimilarCommitResult();
    // 選んだ物のどれかの残す物になっている物は送らない。Worker は同じ回の中でしか見張れず、
    // 2 本並べて送ると、消す物とその残す物が両方ゴミ箱へ行きかねない（段をまたいで選んだ時など）
    final keeps = {for (final t in all) t.group.keeper};
    final kept = [
      for (final t in all)
        if (keeps.contains(t.member.key)) t.member.key,
    ];
    final targets = [
      for (final t in all)
        if (!keeps.contains(t.member.key)) t,
    ];
    for (final k in kept) {
      selected.remove(k);
    }
    if (targets.isEmpty) {
      _notify();
      return SimilarCommitResult(keptAsKeeper: kept.length);
    }
    committing = true;
    _cancelCommit = false;
    commitDone = 0;
    commitTotal = targets.length;
    final gen = _generation;
    final removed = _removeOptimistic(targets);

    final items = [
      for (final t in targets) (key: t.member.key, keep: t.group.keeper),
    ];
    final size = _chunkSize;
    final chunks = [
      for (var i = 0; i < items.length; i += size)
        items.sublist(i, math.min(i + size, items.length)),
    ];
    final receipts = <TrashReceipt>[];
    final unrestorable = <String>[];
    final leftInTrash = <String>[];
    final kinds = <String, int>{};
    final errors = <String, String>{};
    var reloadNeeded = false;

    void putBack(String key) {
      final r = removed[key];
      if (r != null && gen == _generation) _putBack(r);
    }

    var next = 0;
    Future<void> worker() async {
      while (!_cancelCommit && !_disposed && next < chunks.length) {
        final chunk = chunks[next++];
        final byKey = <String, SimilarTrashItemResult>{};
        String? whole;
        try {
          for (final r in await api.similarTrash(lib, chunk)) {
            byKey[r.key] = r;
          }
        } on ApiError catch (e) {
          whole = e.code ?? 'http_${e.status}';
          // 答えが届かない・Worker が途中で落ちた: 動いたかどうか分からないので一覧を読み直して合わせる
          if (e.status == 0 || e.status >= 500) reloadNeeded = true;
        } on Object {
          whole = 'network';
          reloadNeeded = true;
        }
        for (final it in chunk) {
          final r = byKey[it.key];
          if (whole == null && r != null && r.ok) {
            final tk = r.trashKey ?? '';
            if (tk.isEmpty) {
              unrestorable.add(it.key);
            } else {
              receipts.add(TrashReceipt(lib, tk, key: it.key));
            }
            final kind = r.kind ?? removed[it.key]?.member.match ?? 'unknown';
            kinds[kind] = (kinds[kind] ?? 0) + 1;
            continue;
          }
          if (whole == null && r != null && r.error == 'put_back_failed') {
            // 元の key には無く、ゴミ箱に控えごと残っている。一覧へ戻すと、無い物を在るように見せて
            // 気づかないまま保存期間で消えるので戻さない。一覧は読み直して合わせる
            leftInTrash.add(it.key);
            reloadNeeded = true;
            continue;
          }
          final code = whole ?? r?.error ?? 'missing_result';
          errors[it.key] = code;
          if (_staleErrors.contains(code)) reloadNeeded = true;
          putBack(it.key);
        }
        commitDone += chunk.length;
        _notify();
      }
    }

    await Future.wait([
      for (var i = 0; i < math.min(inFlight, chunks.length); i++) worker(),
    ]);
    var unsent = 0;
    for (final chunk in chunks.skip(next)) {
      for (final it in chunk) {
        unsent++;
        putBack(it.key);
      }
    }
    committing = false;
    if (reloadNeeded && gen == _generation) needsReload = true;
    _notify();
    return SimilarCommitResult(
      receipts: receipts,
      kinds: kinds,
      failed: errors.length,
      errors: errors,
      unsent: unsent,
      unrestorable: unrestorable,
      needsReload: reloadNeeded || needsReload,
      keptAsKeeper: kept.length,
      leftInTrash: leftInTrash,
    );
  }

  Map<String, RemovedSimilar> _removeOptimistic(List<_Target> targets) {
    final before = <SimilarGroupId, List<String>>{};
    final order = <String, List<String>>{};
    for (final t in targets) {
      final g = t.group;
      before.putIfAbsent(g.gid, () => [for (final m in g.members) m.key]);
      order.putIfAbsent(g.tier, () => [for (final x in groupsOf(g.tier)) x.id]);
    }
    final out = <String, RemovedSimilar>{};
    final touched = <SimilarGroupView>{};
    for (final t in targets) {
      final g = t.group;
      out[t.member.key] = RemovedSimilar(
        gid: g.gid,
        member: t.member,
        keeper: g.keeper,
        before: before[g.gid]!,
        groupOrder: order[g.tier]!,
      );
      _tracked(g, () => g.members.removeWhere((m) => m.key == t.member.key));
      selected.remove(t.member.key);
      touched.add(g);
    }
    for (final g in touched) {
      // 応答に載らなかった物がまだ組に残っている。空いた分は読み直さないと出てこない
      // （反転などが残って組が畳まれなくても、隠れた重複を選べないままにしない）
      if (g.more > 0) needsReload = true;
      if (g.members.length >= 2) continue;
      // オリジナルだけ残った組は畳む。戻す時に、後から消した物まで生き返らないよう今の姿を残しておく
      if (groupsOf(g.tier).remove(g)) {
        _dropped[g.gid] = g;
        _groupAdjust[g.tier] = (_groupAdjust[g.tier] ?? 0) - 1;
      }
    }
    _notify();
    return out;
  }

  void _putBack(RemovedSimilar r) {
    final list = groupsOf(r.gid.tier);
    var g = _find(r.gid);
    if (g == null) {
      g = _dropped.remove(r.gid);
      if (g == null) return;
      list.insert(
        _slot(r.groupOrder, r.gid.id, [for (final x in list) x.id]),
        g,
      );
      _groupAdjust[g.tier] = (_groupAdjust[g.tier] ?? 0) + 1;
    }
    if (g.member(r.member.key) != null) return;
    final at = _slot(r.before, r.member.key, [
      for (final m in g.members) m.key,
    ]);
    final view = g;
    _tracked(view, () => view.members.insert(at, r.member));
  }

  /// [order] の中で [key] より前にあり今も [now] に残る一番近い物の直後。何件かしか戻らなくても元の並びを崩さない
  static int _slot(List<String> order, String key, List<String> now) {
    final idx = order.indexOf(key);
    for (var i = idx - 1; i >= 0; i--) {
      final p = now.indexOf(order[i]);
      if (p >= 0) return p + 1;
    }
    return 0;
  }

  /// 直後の「元に戻す」。40 件ずつ 2 本まで並べて Worker に戻させ、アルバムも削除前の形に戻る。
  /// 画面を閉じた後でも戻すことはやめない（読み直しだけ飛ばす）。
  /// ファイルは戻ったのにアルバムを書けなかった物は、[undoRetryDelays] の間を空けて呼び直す
  Future<RestoreOutcome> undo(List<TrashReceipt> receipts) async {
    final keys = [
      for (final r in receipts)
        if (r.trashKey.isNotEmpty) r.trashKey,
    ];
    final size = _chunkSize;
    var restored = 0;
    // 最後に返った失敗の状態（試し直して通った物は消す）
    final failures = <String, int>{};
    // 最後までアルバムを書けなかった物（albums_failed）。ファイルは戻っている
    final albumsFailed = <String>{};
    // 塊ごと答えが返らなかった物。Worker が途中まで戻したかもしれないので呼び直す。呼び直しで
    // 404（もうゴミ箱に無い）なら、前の呼び出しが戻し終えていた物として数える
    final uncertain = <String>{};

    Future<List<String>> round(List<String> list) async {
      final chunks = [
        for (var i = 0; i < list.length; i += size)
          list.sublist(i, math.min(i + size, list.length)),
      ];
      final again = <String>[];
      var next = 0;
      Future<void> worker() async {
        while (next < chunks.length) {
          final chunk = chunks[next++];
          try {
            final byTk = {
              for (final r in await api.similarUndo(lib, chunk)) r.trashKey: r,
            };
            for (final tk in chunk) {
              final r = byTk[tk];
              final settled =
                  (r != null && r.ok) ||
                  (r?.status == 404 && uncertain.contains(tk));
              if (settled) {
                restored++;
                failures.remove(tk);
                albumsFailed.remove(tk);
              } else if (r?.error == 'albums_failed') {
                failures.remove(tk);
                albumsFailed.add(tk);
                again.add(tk);
              } else {
                failures[tk] = r?.status ?? 0;
                albumsFailed.remove(tk);
              }
            }
          } on ApiError catch (e) {
            // 答えが届かない・Worker が途中で落ちた（5xx）時は、ファイルだけ戻ってアルバムが戻って
            // いないことがある。ゴミ箱の画面にはもう出ないので、ここで呼び直さないと直す道が無い。
            // Worker の戻し方は何度呼んでも同じ形になる
            final retry = e.status == 0 || e.status >= 500;
            for (final tk in chunk) {
              if (albumsFailed.contains(tk)) {
                // 前の回でファイルは戻っている。分かっている状態のまま、もう一度だけ試す
                if (retry) again.add(tk);
                continue;
              }
              failures[tk] = e.status;
              if (retry) {
                uncertain.add(tk);
                again.add(tk);
              }
            }
          } on Object {
            for (final tk in chunk) {
              again.add(tk);
              if (albumsFailed.contains(tk)) continue;
              failures[tk] = 0;
              uncertain.add(tk);
            }
          }
        }
      }

      await Future.wait([
        for (var i = 0; i < math.min(inFlight, chunks.length); i++) worker(),
      ]);
      return again;
    }

    var pending = await round(keys);
    // ファイルは戻ったのにアルバムを書けなかった物と、塊ごと答えが返らなかった物だけ、
    // 少し待って同じ受け取りで呼び直す
    for (final wait in undoRetryDelays) {
      if (pending.isEmpty) break;
      await Future<void>.delayed(wait);
      pending = await round(pending);
    }
    var conflict = 0, readOnlyN = 0, notFound = 0, other = 0;
    for (final status in failures.values) {
      switch (status) {
        case 409:
          conflict++;
        case 403:
          readOnlyN++;
        case 404:
          notFound++;
        default:
          other++;
      }
    }
    // 最後までアルバムを書けなかった物も、ファイルは戻っているので戻した数に入れ、別に知らせる
    final outcome = RestoreOutcome(
      total: keys.length,
      restored: restored + albumsFailed.length,
      conflict: conflict,
      readOnly: readOnlyN,
      notFound: notFound,
      other: other,
      failures: failures,
      albumsFailed: albumsFailed.length,
    );
    if (!_disposed) await reload();
    return outcome;
  }

  @override
  void dispose() {
    _disposed = true;
    _run++;
    _selectAllRun++;
    _cancelCommit = true;
    _backfill?.cancel();
    super.dispose();
  }
}
