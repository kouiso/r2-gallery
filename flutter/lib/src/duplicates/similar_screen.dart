import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../api/models.dart';
import '../grid/day_label.dart';
import '../grid/state_views.dart';
import '../state/app_state.dart';
import '../state/trash_state.dart';
import '../state/write_guard.dart';
import '../ui/media_tile.dart';
import '../ui/theme.dart';
import '../ui/trash_undo.dart';
import '../ui/viewer_screen.dart';
import '../ui/write_guard_notice.dart';
import '../viewer/screen_awake.dart';
import '../viewer/viewer_format.dart';
import 'duplicates_screen.dart';
import 'signature_source.dart';
import 'similar_controller.dart';

/// 3桁ごとの区切り。照合や削除は数千件になるので、桁を読み違えないようにする
String formatCount(int n) {
  final s = n.abs().toString();
  final b = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

/// タイルに出す札。「差分かも」は「ほぼ同じ」より先に出す（同じ大きさ・形式で細部が違うかもしれない注意だから）
String similarMatchLabel(SimilarMember m) {
  if (m.match == similarMatchNone) return 'オリジナルと別物';
  if (m.isKeeper) return 'オリジナル';
  if (m.variant) return '差分かも';
  return switch (m.match) {
    'identical' => '同じファイル',
    'same' => 'ほぼ同じ',
    'mirror' => '反転',
    _ => '似ている',
  };
}

/// 中身が同じ物と、見た目が同じ・似ている物の組を出し、まとめてゴミ箱へ送る画面。
/// 自動では何も消さない。消した物はゴミ箱へ行き、直後の「元に戻す」でアルバムまで元の形に戻る
class SimilarScreen extends StatefulWidget {
  final AppState app;
  final String lib;

  /// テストで時刻を固定するための口
  final DateTime Function() clock;

  /// テストで署名の作り方を差し替える口。既定は保存済みサムネ／原本から作る
  @visibleForTesting
  final SignatureSource? source;

  /// テストで Web の振る舞い（原本からは照合しない）を真似る口
  @visibleForTesting
  final bool? isWeb;

  /// 照合中に画面を消さないための保持。OfflineViewer と同じく、既定はアプリ共通の物を使う
  @visibleForTesting
  final ScreenAwakeCoordinator? screenAwake;

  /// テストでビューアの画像をネットから読ませないための口
  @visibleForTesting
  final BaseCacheManager? imageCacheManager;

  const SimilarScreen({
    super.key,
    required this.app,
    required this.lib,
    this.clock = DateTime.now,
    this.source,
    this.isWeb,
    this.screenAwake,
    this.imageCacheManager,
  });

  @override
  State<SimilarScreen> createState() => _SimilarScreenState();
}

class _SimilarScreenState extends State<SimilarScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  // 書き込めない理由（読み取り専用・未接続）がある間は選ばせない。Worker も 403 で断る
  late final bool _readOnly =
      widget.app.writeBlock(widget.lib, WriteAction.trash) != null;
  late final SimilarController _c = SimilarController(
    api: widget.app.api,
    lib: widget.lib,
    readOnly: _readOnly,
    source: widget.source,
    isWeb: widget.isWeb,
  );
  // 読み直し（取り消しの後など）で一覧を組み直しても、見ていたタブに留まるよう画面が持つ
  late final TabController _tabs;
  late final ScreenAwakeLease _lease;
  bool _foreground = true;

  /// まとめて送っている間だけ進み具合を出す。長押しの1件は一瞬で終わるので出さない
  bool _showProgress = false;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _lease = (widget.screenAwake ?? ScreenAwakeCoordinator.shared).lease();
    final life = WidgetsBinding.instance.lifecycleState;
    _foreground = life == null || life == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _c.addListener(_syncLease);
    widget.app.addListener(_syncLease);
    unawaited(_c.start());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.app.removeListener(_syncLease);
    _c.removeListener(_syncLease);
    _lease.dispose();
    _tabs.dispose();
    // 照合・計算の呼び出しは次の区切りで止まる。画面を離れることが中断になり、次は続きから
    _c.dispose();
    super.dispose();
  }

  /// 照合は数十分かかることがあり、途中で画面が消えると止まってしまう。照合している間だけ保持する
  void _syncLease() {
    _lease.setEnabled(
      _foreground && !widget.app.locked && _c.phase == SimilarPhase.signing,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) _lease.release();
    _syncLease();
  }

  // ---------------------------------------------------------------- 操作

  Future<void> _toggleAllDup() async {
    final on = _c.allDupState != true;
    final ok = await _c.selectAllDup(on);
    if (!on || !mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('全件を読み込めませんでした。もう一度お試しください')),
      );
    } else if (_c.allDupState == false) {
      // 読み切ったが、どの組にも同じファイル・ほぼ同じの物が無かった。黙っていると押せていないように見える
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('まとめて選べる重複はありません')));
    }
  }

  /// まとめて送っている間に戻ろうとした。黙って戻ると、まだ送っていない分が知らないうちに止まる
  Future<void> _confirmLeaveWhileCommitting() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移動を中止して戻りますか？'),
        content: const Text('送り終えた分はゴミ箱に移ります。まだ送っていない分は移しません。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('続ける'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('中止して戻る'),
          ),
        ],
      ),
    );
    if (leave != true || !mounted) return;
    _c.cancelCommit();
    Navigator.of(context).pop();
  }

  Future<void> _commitSelected() async {
    final app = widget.app;
    if (!ensureWritable(context, app, widget.lib, WriteAction.trash)) return;
    if (_c.selectedCount == 0 || _c.committing || _c.loadingAll) return;
    // 確かめで見せた物だけを送る。開いている間に選択が増えても（読み込みの続き・オリジナルの
    // 付け直し）、確かめていない物は送らない
    final picked = _c.selection();
    final ok = await _confirm(picked);
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _showProgress = true);
    final r = await _c.commit(picked);
    if (mounted) setState(() => _showProgress = false);
    _afterCommit(messenger, r);
  }

  Future<void> _trashOne(SimilarGroupView g, SimilarMember m) async {
    final app = widget.app;
    if (!ensureWritable(context, app, widget.lib, WriteAction.trash)) return;
    final messenger = ScaffoldMessenger.of(context);
    final r = await _c.trashOne(g, m);
    if (r.busy) {
      // まとめての移動が終わる前に押された。黙って捨てると押したのに何も起きないように見える
      messenger.showSnackBar(
        const SnackBar(content: Text('ほかの物をゴミ箱へ移動中です。終わってからもう一度お試しください')),
      );
      return;
    }
    _afterCommit(messenger, r);
  }

  void _afterCommit(ScaffoldMessengerState messenger, SimilarCommitResult r) {
    final app = widget.app;
    final lib = widget.lib;
    // 戻せずゴミ箱に残った物（put_back_failed）や、塊ごと答えが返らず動いたか分からない物も、
    // 元の場所からは無くなっているかもしれない。ギャラリーとゴミ箱の画面にも読み直させる
    if (r.trashed > 0 || r.leftInTrash.isNotEmpty || r.needsReload) {
      app.markContentChanged(lib);
    }
    if (r.trashed > 0) {
      // 送り終えてから出す。数千件だと送る間に6秒の期限が切れてしまうため
      unawaited(
        offerOptimisticTrashUndo(
          messenger,
          count: r.trashed,
          done: Future.value(r.outcome(lib)),
          onUndo: () async {
            final o = await _c.undo(r.receipts);
            app.markContentChanged(lib);
            return o;
          },
        ),
      );
    }
    final notes = [
      if (r.failed > 0)
        r.needsReload
            ? '${formatCount(r.failed)}件を移せませんでした。一覧を読み直します'
            : '${formatCount(r.failed)}件を移せませんでした',
      if (r.leftInTrash.isNotEmpty)
        '${formatCount(r.leftInTrash.length)}件は元の場所へ戻せず、ゴミ箱に残りました。ゴミ箱から戻せます',
      if (r.unsent > 0) '${formatCount(r.unsent)}件は移さずに止めました',
      if (r.keptAsKeeper > 0)
        '${formatCount(r.keptAsKeeper)}件はほかの物のオリジナルなので残しました',
    ];
    // 「元に戻す」の後ろに並べる。先に出すと取り消せる時間が削られる
    if (notes.isNotEmpty && messenger.mounted) {
      messenger.showSnackBar(SnackBar(content: Text(notes.join('。'))));
    }
    if (r.needsReload && mounted) unawaited(_c.reload());
  }

  Future<bool?> _confirm(SimilarSelection picked) {
    final n = picked.count;
    final kinds = picked.kinds;
    final variants = picked.variants;
    final identical = kinds['identical'] ?? 0;
    final same = kinds['same'] ?? 0;
    final mirror = kinds['mirror'] ?? 0;
    final similar = kinds['similar'] ?? 0;
    // 0件の種類まで並べると読む量が増えるだけなので、選んだ種類だけを出す
    final parts = [
      if (identical > 0) '完全に同じ ${formatCount(identical)}件',
      if (same > 0)
        variants > 0 && variants <= same
            ? 'ほぼ同じ ${formatCount(same)}件（うち差分かも ${formatCount(variants)}件）'
            : 'ほぼ同じ ${formatCount(same)}件',
      if (mirror > 0) '反転 ${formatCount(mirror)}件',
      if (similar > 0) '似ている ${formatCount(similar)}件',
    ];
    final body =
        '${parts.isEmpty ? '' : '${parts.join('・')}。'}'
        'オリジナルは残します。アルバムに入っていた物はオリジナルに置き換えます。'
        'ゴミ箱から$kTrashRetentionDaysFallback日間は元に戻せます。';
    final warn = similar > 0 || variants > 0;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${formatCount(n)}件をゴミ箱に移動しますか？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(body),
            if (warn) ...[
              const SizedBox(height: 12),
              Text(
                '『似ている』『差分かも』は別の絵のこともあります。',
                style: AppText.body.copyWith(color: AppColors.danger),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('ゴミ箱に移動'),
          ),
        ],
      ),
    );
  }

  Future<void> _open(SimilarGroupView g, int index) => openViewer(
    context,
    app: widget.app,
    lib: widget.lib,
    items: [for (final m in g.members) m.item],
    index: index,
    // ビューアからゴミ箱へ送ると組の形が変わるので読み直す
    onChanged: () => unawaited(_c.reload()),
    // テスト用の口をそのまま渡すだけ。本番では null で、ビューアは既定のキャッシュを使う
    // ignore: invalid_use_of_visible_for_testing_member
    imageCacheManager: widget.imageCacheManager,
  );

  Future<void> _sheet(SimilarGroupView g, SimilarMember m, int index) async {
    final keeper = g.isKeeper(m);
    // まとめて移している間は組の形が変わっていく。オリジナルの付け替えや1件の移動は終わってから。
    // オリジナルを付け替えている途中の組も同じ（付け替える先を消すと、付け替えが空振りする）
    final busy = _c.committing || g.relabeling;
    final canKeep = !_readOnly && !busy && !keeper && g.canSelect(m);
    final canTrash = !_readOnly && !busy && g.canSelect(m);
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                m.item.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(similarMatchLabel(m)),
            ),
            if (canKeep)
              ListTile(
                leading: const Icon(
                  Icons.star_outline,
                  color: AppColors.accent,
                ),
                title: const Text('オリジナルにする'),
                onTap: () => Navigator.of(ctx).pop('keep'),
              ),
            ListTile(
              leading: const Icon(Icons.open_in_full),
              title: const Text('開く'),
              onTap: () => Navigator.of(ctx).pop('open'),
            ),
            if (canTrash)
              ListTile(
                leading: const Icon(
                  Icons.delete_outline,
                  color: AppColors.danger,
                ),
                title: const Text(
                  'この1件だけゴミ箱へ',
                  style: TextStyle(color: AppColors.danger),
                ),
                onTap: () => Navigator.of(ctx).pop('trash'),
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'keep':
        final err = await _c.setKeeper(g, m.key);
        if (err != null && mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(err)));
        }
      case 'open':
        await _open(g, index);
      case 'trash':
        await _trashOne(g, m);
    }
  }

  // ---------------------------------------------------------------- 画面

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        if (_c.phase == SimilarPhase.unsupported) {
          // 古い Worker には見た目の照合が無い。従来の画面をそのまま出し、できていた事を失わない
          return DuplicatesScreen(
            app: widget.app,
            lib: widget.lib,
            clock: widget.clock,
          );
        }
        final listing = _c.phase == SimilarPhase.ready && !_empty;
        // 進み具合の覆いは本文の上だけで、AppBar の戻るや Android の戻る操作は止めない。
        // まとめて送っている間に画面を閉じると残りの塊が黙って止まるので、戻る前に確かめる
        return PopScope(
          canPop: !_c.committing,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && _c.committing) {
              unawaited(_confirmLeaveWhileCommitting());
            }
          },
          child: _scaffold(listing),
        );
      },
    );
  }

  Widget _scaffold(bool listing) => Scaffold(
    appBar: AppBar(
      title: const Text('重複・似ている写真'),
      bottom: listing
          ? TabBar(
              controller: _tabs,
              tabs: [
                Tab(text: '重複 (${formatCount(_c.groupCount(similarTabDup))}組)'),
                Tab(
                  text:
                      '似ている (${formatCount(_c.groupCount(similarTabSimilar))}組)',
                ),
              ],
            )
          : null,
    ),
    body: Stack(
      children: [
        Positioned.fill(
          child: listing
              ? TabBarView(
                  controller: _tabs,
                  children: [
                    _tierList(similarTabDup),
                    _tierList(similarTabSimilar),
                  ],
                )
              : _stateBody(),
        ),
        if (_showProgress && _c.committing) _progress(),
      ],
    ),
    bottomNavigationBar: listing && !_readOnly ? _bottomBar() : null,
  );

  bool get _empty =>
      _c.dupGroups.isEmpty &&
      _c.simGroups.isEmpty &&
      _c.dupCursor == null &&
      _c.simCursor == null;

  Widget _stateBody() {
    switch (_c.phase) {
      case SimilarPhase.hashScan:
        final n = _c.scanPending;
        return StateView(
          icon: Icons.content_copy_outlined,
          title: n == null || n == 0
              ? '中身を確認中…'
              : '中身を確認中… あと ${formatCount(n)} 件',
          body: '中身が同じ物を探しています。画面を離れると止まり、次は続きから',
          actions: const [
            SizedBox(width: 160, child: LinearProgressIndicator()),
          ],
        );
      case SimilarPhase.consent:
        final lines = [
          'PC の tools/similar-signatures.mjs でも進められます',
          if (_c.isWeb) 'Web では時間がかかります。Android か PC がおすすめです',
        ];
        return StateView(
          icon: Icons.image_search_outlined,
          title:
              '見た目の照合が済んでいない写真 ${formatCount(_c.consentCount)} 枚'
              '（通信 約 ${formatBytes(_c.consentBytes)}）',
          body: lines.join('\n'),
          actions: [
            StatePrimaryButton('この端末で照合する', () => unawaited(_c.startSigning())),
            const SizedBox(height: 8),
            StateTextButton('あとで（今の結果を見る）', () => unawaited(_c.skipSigning())),
          ],
        );
      case SimilarPhase.signing:
        final p = _c.signProgress;
        final done = p?.done ?? 0;
        final total = math.max(p?.total ?? _c.consentCount, done);
        return StateView(
          icon: Icons.image_search_outlined,
          title: '見た目を照合中 ${formatCount(done)} / ${formatCount(total)}',
          body: '画面を離れると止まり、次は続きから',
          actions: [
            SizedBox(
              width: 240,
              child: LinearProgressIndicator(
                value: total > 0 ? done / total : null,
              ),
            ),
            const SizedBox(height: 16),
            StateTextButton('途中の結果を見る', _c.stopSigning),
          ],
        );
      case SimilarPhase.status:
      case SimilarPhase.loading:
        return const Center(child: CircularProgressIndicator());
      case SimilarPhase.error:
        return StateView(
          icon: Icons.error_outline,
          iconColor: AppColors.danger,
          title: _c.error ?? '読み込めませんでした',
          body: _c.exactFallback ? '同じファイルの組だけなら、従来の画面で見られます' : null,
          actions: [
            StatePrimaryButton('再試行', () => unawaited(_c.start())),
            // 見た目の照合の口だけが失敗した時でも、同じファイル（SHA-256）の組は従来の画面で出せる
            if (_c.exactFallback) ...[
              const SizedBox(height: 8),
              StateTextButton('同じファイルだけを探す', _c.useExactScreen),
            ],
          ],
        );
      case SimilarPhase.ready:
      case SimilarPhase.unsupported:
        final lines = _coverageLines();
        return StateView(
          icon: Icons.check_circle_outline,
          title: '重複も似ている写真も見つかりませんでした',
          body: lines.isEmpty ? null : lines.join('\n'),
          actions: [
            if (_canResumeSigning)
              StateTextButton('照合を続ける', () => unawaited(_c.start())),
          ],
        );
    }
  }

  /// 見つからなかった理由の内訳。数え漏れを「重複が無い」と読み違えないよう、0件でない物だけ出す
  List<String> _coverageLines() {
    final s = _c.summary;
    final cov = s.coverage;
    final deferred = _c.deferredHere;
    final pending = math.max(0, cov.pending - deferred);
    return [
      if (pending > 0) '照合が済んでいない物: ${formatCount(pending)} 件',
      if (cov.failed > 0) '確認できなかった物: ${formatCount(cov.failed)} 件',
      if (cov.flat > 0) '単色に近く比べなかった物: ${formatCount(cov.flat)} 件',
      if (s.hashSkipped > 0)
        '大きすぎて中身を確認できなかった物: ${formatCount(s.hashSkipped)} 件',
      if (s.hashPending > 0) 'まだ中身を確認できていない物: ${formatCount(s.hashPending)} 件',
      if (deferred > 0)
        'この端末では照合できない物: ${formatCount(deferred)} 件（Android か PC で照合できます）',
      if (_c.appUpdateNeeded) 'アプリを更新すると見た目の照合を続けられます',
    ];
  }

  /// 「あとで」で飛ばした照合を、画面を開き直さずに続けられるようにする
  bool get _canResumeSigning {
    final pending = _c.summary.coverage.pending - _c.deferredHere;
    return pending > 0 && !_c.appUpdateNeeded && !_c.committing;
  }

  Widget _tierList(String tier) {
    final groups = _c.groupsOf(tier);
    final more = _c.cursorOf(tier) != null;
    return ListView.builder(
      key: PageStorageKey('similar-$tier'),
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: groups.length + 2,
      itemBuilder: (context, i) {
        if (i == 0) {
          return tier == similarTabDup ? _dupHeader() : _similarHeader();
        }
        if (i == groups.length + 1) {
          if (groups.isEmpty && !more) {
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: Text(
                  tier == similarTabDup ? '重複は見つかりませんでした' : '似ている写真は見つかりませんでした',
                  style: AppText.body.copyWith(color: AppColors.textDim),
                ),
              ),
            );
          }
          return _footer(tier);
        }
        final g = groups[i - 1];
        return _GroupCard(
          key: ValueKey('${g.tier}:${g.id}'),
          controller: _c,
          group: g,
          readOnly: _readOnly,
          now: widget.clock(),
          onOpen: (index) => unawaited(_open(g, index)),
          onMenu: (m, index) => unawaited(_sheet(g, m, index)),
        );
      },
    );
  }

  Widget _readOnlyNotice() => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Text(
      widget.app.writeBlock(widget.lib, WriteAction.trash) ??
          'このライブラリは読み取り専用です',
      style: AppText.caption.copyWith(color: AppColors.danger),
    ),
  );

  Widget _dupHeader() {
    final dim = AppText.caption.copyWith(color: AppColors.textDim);
    final hasGroups = _c.dupGroups.isNotEmpty || _c.dupCursor != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${formatCount(_c.groupCount(similarTabDup))}組 · '
            '${formatBytes(_c.dupReclaimable)} 空けられます',
            style: AppText.heading,
          ),
          const SizedBox(height: 4),
          Text('同じファイルと、見た目がほぼ同じ物の組です。「オリジナル」を残して、ほかをゴミ箱へ移せます', style: dim),
          for (final l in _coverageLines()) Text(l, style: dim),
          if (_canResumeSigning)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => unawaited(_c.start()),
                child: const Text('照合を続ける'),
              ),
            ),
          if (_readOnly) _readOnlyNotice(),
          if (!_readOnly && hasGroups)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              tristate: true,
              value: _c.allDupState,
              // 読み切っていて選べる物が1件も無ければ押せなくする（押しても何も変わらない）
              onChanged: _c.loadingAll || _c.committing || !_c.dupSelectable
                  ? null
                  : (_) => unawaited(_toggleAllDup()),
              title: const Text('すべての重複'),
              subtitle: Text(
                _c.loadingAll
                    ? '全件を読み込んでいます…'
                    : [
                        '同じファイルとほぼ同じ物を選びます。反転・差分かも・似ている物は選びません',
                        // 大きな組の載らなかった分は「空けられます」には入るが、ここでは選べない
                        if (_c.dupHidden > 0)
                          'ほか ${formatCount(_c.dupHidden)} 件は、消した後に読み直すと選べます',
                      ].join('\n'),
                style: dim,
              ),
            ),
        ],
      ),
    );
  }

  Widget _similarHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${formatCount(_c.groupCount(similarTabSimilar))}組',
            style: AppText.heading,
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.surfaceHigh,
              borderRadius: BorderRadius.circular(AppRadius.small),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.info_outline,
                  size: 18,
                  color: AppColors.accent,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '見た目が近いだけで別の絵のこともあります。確かめてから選んでください',
                    style: AppText.caption,
                  ),
                ),
              ],
            ),
          ),
          if (_readOnly) _readOnlyNotice(),
        ],
      ),
    );
  }

  Widget _footer(String tier) {
    if (_c.cursorOf(tier) == null) return const SizedBox.shrink();
    if (_c.moreFailed[tier] == true) {
      return Center(
        child: StateTextButton('続きを読み込む', () => unawaited(_c.loadMore(tier))),
      );
    }
    // 末尾が見えたら続きを読む。描画中に状態を変えないよう、描き終えてから頼む
    if (_c.loadingMore[tier] != true && !_c.loadingAll) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => mounted ? unawaited(_c.loadMore(tier)) : null,
      );
    }
    return const Padding(
      padding: EdgeInsets.all(16),
      child: Center(child: CircularProgressIndicator()),
    );
  }

  Widget _bottomBar() {
    final n = _c.selectedCount;
    final bytes = _c.selectedBytes;
    return Material(
      color: AppColors.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton(
              // 「すべての重複」が残りを読んでいる間は押せない。読み終えると選択が増え、確かめで
              // 見せた件数より多くを送ってしまう
              onPressed: n == 0 || _c.committing || _c.loadingAll
                  ? null
                  : () => unawaited(_commitSelected()),
              child: Text('ゴミ箱に移動（${formatCount(n)}件 · ${formatBytes(bytes)}）'),
            ),
          ),
        ),
      ),
    );
  }

  Widget _progress() {
    final total = _c.commitTotal;
    final done = math.min(_c.commitDone, total);
    return Positioned.fill(
      child: Stack(
        children: [
          const ModalBarrier(dismissible: false, color: AppColors.scrimBar),
          Center(
            child: AlertDialog(
              title: Text(
                'ゴミ箱へ移動中 ${formatCount(done)} / ${formatCount(total)}',
              ),
              content: LinearProgressIndicator(
                value: total > 0 ? done / total : null,
              ),
              actions: [
                TextButton(onPressed: _c.cancelCommit, child: const Text('中止')),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  final SimilarController controller;
  final SimilarGroupView group;
  final bool readOnly;
  final DateTime now;
  final ValueChanged<int> onOpen;
  final void Function(SimilarMember m, int index) onMenu;
  const _GroupCard({
    super.key,
    required this.controller,
    required this.group,
    required this.readOnly,
    required this.now,
    required this.onOpen,
    required this.onMenu,
  });

  static String _dir(String key) {
    final i = key.lastIndexOf('/');
    return i < 0 ? '' : key.substring(0, i);
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final g = group;
    final members = g.members;
    final keeperSize = g.member(g.keeper)?.size ?? members.first.size;
    final canGroup = !readOnly && members.any(g.bulkEligible);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${formatCount(members.length + g.more)}件 · 1件 ${formatBytes(keeperSize)}',
                    style: AppText.caption.copyWith(color: AppColors.textDim),
                  ),
                ),
                // 組のチェックは段の決まりで拾える物（重複は同じ・ほぼ同じ、似ているは似ている）だけを選ぶ
                if (canGroup)
                  Checkbox(
                    key: ValueKey('group:${g.tier}:${g.id}'),
                    tristate: true,
                    value: c.groupState(g),
                    semanticLabel: 'この組をまとめて選ぶ',
                    onChanged: c.committing || g.relabeling
                        ? null
                        : (_) => c.setGroupSelected(g, c.groupState(g) != true),
                  )
                else
                  const SizedBox(height: 40),
              ],
            ),
            if (g.relabeling)
              const Padding(
                padding: EdgeInsets.only(right: 8, bottom: 8),
                child: LinearProgressIndicator(),
              ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: LayoutBuilder(
                builder: (context, box) {
                  const gap = 8.0;
                  final w = ((box.maxWidth - gap * 2) / 3).floorToDouble();
                  return Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: [
                      for (var i = 0; i < members.length; i++)
                        SizedBox(
                          width: w,
                          child: _Tile(
                            member: members[i],
                            keeper: g.isKeeper(members[i]),
                            disabled:
                                !g.isKeeper(members[i]) &&
                                !g.canSelect(members[i]),
                            selected: c.isSelected(members[i].key),
                            showCheck: !readOnly && g.canSelect(members[i]),
                            dir: _dir(members[i].key),
                            now: now,
                            onTap: () => onOpen(i),
                            onLongPress: () => onMenu(members[i], i),
                            onToggle: c.committing || g.relabeling
                                ? null
                                : (on) => c.toggle(g, members[i], on),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
            if (g.more > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'ほか ${formatCount(g.more)} 件はここに出していません',
                  style: AppText.caption.copyWith(color: AppColors.textDim),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  final SimilarMember member;
  final bool keeper;
  final bool disabled;
  final bool selected;
  final bool showCheck;
  final String dir;
  final DateTime now;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final ValueChanged<bool?>? onToggle;
  const _Tile({
    required this.member,
    required this.keeper,
    required this.disabled,
    required this.selected,
    required this.showCheck,
    required this.dir,
    required this.now,
    required this.onTap,
    required this.onLongPress,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final item = member.item;
    final dim = AppText.caption.copyWith(color: AppColors.textDim);
    final thumb = item.thumbUrl;
    final created = item.createdAt;
    final label = keeper ? 'オリジナル' : similarMatchLabel(member);
    // 名前や日付の所を押しても開けるよう、タイル全体で受ける（丸いチェックは自分で押下を取る）
    return Semantics(
      label: item.name,
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onLongPress: onLongPress,
        child: Opacity(
          opacity: disabled ? 0.5 : 1,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: 1,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.small),
                  child: ColoredBox(
                    color: AppColors.surfaceHigh,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // 動画でサムネが無い時に原本URLを渡すと動画を丸ごと落とすので、一覧と同じく枠だけ出す
                        thumb == null
                            ? const ThumbFallback()
                            : ThumbImage(url: thumb, stored: item.thumbStored),
                        if (selected)
                          DecoratedBox(
                            decoration: BoxDecoration(
                              color: AppColors.accentSoft,
                              border: Border.all(
                                color: AppColors.accent,
                                width: 3,
                              ),
                              borderRadius: BorderRadius.circular(
                                AppRadius.small,
                              ),
                            ),
                          ),
                        // 動画の印は左上。右上は丸いチェック、下は札が幅いっぱいに使う
                        if (item.isVideo)
                          const Positioned(
                            left: 4,
                            top: 4,
                            child: Icon(
                              Icons.play_arrow,
                              color: Colors.white,
                              semanticLabel: '動画',
                            ),
                          ),
                        // 札は下に幅いっぱい。上の 36 px（丸いチェックと動画の印の段）には伸ばさない。
                        // 電話の幅（1枚 100 px ほど）や大きな文字では折り返し、それでも高さが足りない分だけ縮める
                        Positioned(
                          left: 4,
                          right: 4,
                          top: 36,
                          bottom: 4,
                          child: Align(
                            alignment: Alignment.bottomLeft,
                            child: _Badge(
                              label,
                              key: ValueKey('badge:${member.key}'),
                              strong: keeper,
                            ),
                          ),
                        ),
                        if (showCheck)
                          Positioned(
                            right: 0,
                            top: 0,
                            child: Checkbox(
                              key: ValueKey('select:${member.key}'),
                              // 既定の 48 px の押せる枠だと狭いタイルの上を広く覆う。32 px に詰める
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              visualDensity: VisualDensity.compact,
                              shape: const CircleBorder(),
                              value: selected,
                              semanticLabel: '${item.name}を選ぶ',
                              side: const BorderSide(
                                color: Colors.white,
                                width: 2,
                              ),
                              onChanged: onToggle,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                item.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.caption,
              ),
              Text(
                dir.isEmpty ? '（一番上）' : dir,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: dim,
              ),
              Text(
                [
                  formatBytes(member.size),
                  if (created != null) formatShortDate(created, now),
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: dim,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String text;

  /// オリジナルの札。残す物が一目で分かるよう、ほかの札と色を変える
  final bool strong;
  const _Badge(this.text, {super.key, this.strong = false});

  // 1 行に収まらなければ幅で折り返す。1 行のまま縮めると、電話の幅の札は 7 px ほどまで小さくなり、
  // 文字を大きくする設定も打ち消してしまう。折り返しても高さが足りない時（文字 2 倍など）だけ縮める
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.bottomLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: box.maxWidth),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: strong ? AppColors.accent : AppColors.scrimPanel,
            borderRadius: BorderRadius.circular(AppRadius.small),
          ),
          child: Text(
            text,
            style: AppText.caption.copyWith(
              color: strong ? AppColors.onAccent : AppColors.onScrimText,
              fontWeight: strong ? FontWeight.w700 : null,
            ),
          ),
        ),
      ),
    ),
  );
}
