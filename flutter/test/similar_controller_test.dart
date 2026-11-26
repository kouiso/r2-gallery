import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/duplicates/signature_source.dart';
import 'package:r2_gallery/src/duplicates/similar_controller.dart';
import 'package:r2_gallery/src/state/trash_ops.dart';

MediaItem _item(String key) => MediaItem(
  key: key,
  type: 'image',
  url: 'https://w.test/m/a/$key',
  thumbUrl: 'https://w.test/t/a/$key',
  thumbStored: true,
);

SimilarMember _m(
  String key,
  String match, {
  int size = 100,
  bool variant = false,
}) =>
    SimilarMember(item: _item(key), size: size, match: match, variant: variant);

/// Worker と同じ数え方の reclaim（重複の段の、反転でも差分かもでもない物）
SimilarGroup _g(
  String tier,
  List<SimilarMember> members, {
  int? reclaim,
  int more = 0,
}) => SimilarGroup(
  id: members.first.key,
  tier: tier,
  members: members,
  more: more,
  reclaim:
      reclaim ??
      (tier == 'dup'
          ? members
                .where(
                  (m) =>
                      (m.match == 'identical' || m.match == 'same') &&
                      !m.variant,
                )
                .fold(0, (s, m) => s + m.size)
          : 0),
);

SimilarTodoItem _todo(String key) =>
    SimilarTodoItem(item: _item(key), etag: 'e-$key', size: 1000, ext: 'jpg');

/// 一覧・照合・削除の受け口だけを持つ偽の Worker
class _Api extends ApiClient {
  _Api();

  // ---- 中身の計算
  List<DuplicateScan> scans = const [
    DuplicateScan(pending: 0, hashed: 0, skipped: 0),
  ];
  int scanCalls = 0;
  Object? scanError;
  Duration scanDelay = Duration.zero;

  // ---- 状況
  SimilarStatus status = const SimilarStatus();
  Object? statusError;

  // ---- 組。カーソルはページ番号
  Map<String, List<List<SimilarGroup>>> pages = {
    'dup': [const []],
    'similar': [const []],
  };
  SimilarSummary summary = const SimilarSummary();
  final List<({String tab, String? cursor, int? limit})> groupCalls = [];
  Object? groupsError;
  Completer<void>? groupsGate;

  /// 次の「続き」の1回だけを止める（ほかの続きは止めない）
  Completer<void>? holdNextCursor;

  // ---- todo と署名
  Map<int, List<SimilarTodoItem>> todo = {};
  final Set<String> posted = {};
  int todoCalls = 0;
  ApiError? postError;

  // ---- 付け直し
  Map<String, SimilarLabel> labels = {};
  Object? relabelError;
  final List<({String keep, List<String> keys})> relabelCalls = [];

  // ---- 削除
  final List<List<({String key, String keep})>> trashCalls = [];
  Map<String, String> trashErrors = {};
  Object? trashChunkError;
  Duration trashDelay = Duration.zero;
  int trashInFlight = 0;
  int maxTrashInFlight = 0;

  // ---- 取り消し
  final List<List<String>> undoCalls = [];
  Map<String, int> undoFail = {};
  String? undoChunkFailFor;
  int undoInFlight = 0;
  int maxUndoInFlight = 0;

  @override
  Future<DuplicateScan> duplicateScan(String libId) async {
    await Future<void>.delayed(scanDelay);
    final e = scanError;
    if (e != null) throw e;
    final r = scans[scanCalls < scans.length ? scanCalls : scans.length - 1];
    scanCalls++;
    return r;
  }

  @override
  Future<SimilarStatus> similarStatus(String libId) async {
    final e = statusError;
    if (e != null) throw e;
    return status;
  }

  @override
  Future<SimilarPage> similarGroups(
    String libId,
    String tab, {
    String? cursor,
    int? limit,
  }) async {
    groupCalls.add((tab: tab, cursor: cursor, limit: limit));
    final gate = groupsGate;
    if (gate != null && cursor != null) await gate.future;
    final hold = holdNextCursor;
    if (hold != null && cursor != null) {
      holdNextCursor = null;
      await hold.future;
    }
    final e = groupsError;
    if (e != null) throw e;
    final list = pages[tab]!;
    final i = cursor == null ? 0 : int.parse(cursor);
    return SimilarPage(
      groups: list[i],
      cursor: i + 1 < list.length ? '${i + 1}' : null,
      total: list.fold(0, (s, p) => s + p.length),
      summary: summary,
    );
  }

  @override
  Future<SimilarTodoPage> similarTodo(
    String libId,
    int shard, {
    String? after,
    int? limit,
  }) async {
    todoCalls++;
    await Future<void>.delayed(Duration.zero);
    final items = [
      for (final t in todo[shard] ?? const <SimilarTodoItem>[])
        if (!posted.contains(t.key)) t,
    ];
    return SimilarTodoPage(shard: shard, items: items);
  }

  @override
  Future<SignaturePostResult> postSignatures(
    String libId,
    List<SignatureUpload> items, {
    String alg = similarAlg,
  }) async {
    final e = postError;
    if (e != null) throw e;
    posted.addAll(items.map((i) => i.key));
    return SignaturePostResult(stored: items.length);
  }

  @override
  Future<Map<String, SimilarLabel>> similarRelabel(
    String libId,
    String keep,
    List<String> keys,
  ) async {
    relabelCalls.add((keep: keep, keys: keys));
    final e = relabelError;
    if (e != null) throw e;
    return {for (final k in keys) k: labels[k] ?? const SimilarLabel()};
  }

  @override
  Future<List<SimilarTrashItemResult>> similarTrash(
    String libId,
    List<({String key, String keep})> items,
  ) async {
    trashCalls.add(items);
    trashInFlight++;
    if (trashInFlight > maxTrashInFlight) maxTrashInFlight = trashInFlight;
    try {
      await Future<void>.delayed(trashDelay);
      final e = trashChunkError;
      if (e != null) throw e;
      return [
        for (final i in items)
          trashErrors.containsKey(i.key)
              ? SimilarTrashItemResult(
                  key: i.key,
                  ok: false,
                  error: trashErrors[i.key],
                  // 戻せずゴミ箱に残った物は、Worker がゴミ箱の key を添える
                  trashKey: trashErrors[i.key] == 'put_back_failed'
                      ? '.trash/1/${i.key}'
                      : null,
                )
              : SimilarTrashItemResult(
                  key: i.key,
                  ok: true,
                  trashKey: '.trash/1/${i.key}',
                  kind: 'identical',
                ),
      ];
    } finally {
      trashInFlight--;
    }
  }

  /// trashKey ごとに、先頭から何回 albums_failed（ファイルは戻ったがアルバムを書けない）を返すか
  Map<String, int> undoAlbumsFail = {};

  /// 取り消しの n 回目（0 から）の呼び出しで、塊ごと投げる物（5xx・通信の失敗）
  Map<int, Object> undoThrowOn = {};

  @override
  Future<List<SimilarUndoItemResult>> similarUndo(
    String libId,
    List<String> trashKeys,
  ) async {
    undoCalls.add(trashKeys);
    undoInFlight++;
    if (undoInFlight > maxUndoInFlight) maxUndoInFlight = undoInFlight;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 2));
      if (undoChunkFailFor != null && trashKeys.contains(undoChunkFailFor)) {
        throw const ApiError(403, 'read only', code: 'read_only_library');
      }
      final thrown = undoThrowOn[undoCalls.length - 1];
      if (thrown != null) throw thrown;
      SimilarUndoItemResult one(String tk) {
        final left = undoAlbumsFail[tk] ?? 0;
        if (left > 0) {
          undoAlbumsFail[tk] = left - 1;
          return SimilarUndoItemResult(
            trashKey: tk,
            ok: false,
            error: 'albums_failed',
            status: 503,
          );
        }
        return undoFail.containsKey(tk)
            ? SimilarUndoItemResult(
                trashKey: tk,
                ok: false,
                error: 'x',
                status: undoFail[tk],
              )
            : SimilarUndoItemResult(trashKey: tk, ok: true, key: tk);
      }

      return [for (final tk in trashKeys) one(tk)];
    } finally {
      undoInFlight--;
    }
  }
}

/// 付け直しの答えを [gate] が開くまで返さない
class _GatedRelabelApi extends _Api {
  final Completer<void> gate = Completer<void>();

  @override
  Future<Map<String, SimilarLabel>> similarRelabel(
    String libId,
    String keep,
    List<String> keys,
  ) async {
    await gate.future;
    return super.similarRelabel(libId, keep, keys);
  }
}

class _Source implements SignatureSource {
  Duration delay = Duration.zero;
  int calls = 0;

  @override
  Future<SignatureOutcome> sign(SimilarTodoItem item) async {
    calls++;
    await Future<void>.delayed(delay);
    return SignatureOutcome.signed(item, 't', Uint8List(297));
  }
}

SimilarController _ctl(
  _Api api, {
  _Source? source,
  bool isWeb = false,
  bool readOnly = false,
  int pageSize = 50,
  List<Duration> undoRetryDelays = const [Duration.zero, Duration.zero],
}) => SimilarController(
  api: api,
  lib: 'a',
  source: source ?? _Source(),
  isWeb: isWeb,
  readOnly: readOnly,
  pageSize: pageSize,
  signConcurrency: 2,
  undoRetryDelays: undoRetryDelays,
);

List<SimilarPhase> _phases(SimilarController c) {
  final out = <SimilarPhase>[];
  c.addListener(() {
    if (out.isEmpty || out.last != c.phase) out.add(c.phase);
  });
  return out;
}

List<String> _keys(SimilarGroupView g) => [for (final m in g.members) m.key];

/// オリジナル1件と identical [each] 件の組を [groups] 個、1ページに並べる
List<List<SimilarGroup>> manyGroups(int groups, int each) => [
  [
    for (var g = 0; g < groups; g++)
      _g('dup', [
        _m('k$g', 'keeper'),
        for (var i = 0; i < each; i++) _m('g$g-$i', 'identical', size: 10),
      ]),
  ],
];

void main() {
  group('段階', () {
    test('計算 → 状況 → 照合 → 読み込み → ready の順に進み、計算は残りが 0 になるまで回す', () async {
      final api = _Api()
        ..scans = const [
          DuplicateScan(pending: 5, hashed: 3, skipped: 1),
          DuplicateScan(pending: 2, hashed: 3, skipped: 1),
          DuplicateScan(pending: 0, hashed: 2, skipped: 1),
        ]
        ..status = const SimilarStatus(pending: 2, pendingWithThumb: 2)
        ..todo = {
          0: [_todo('x1'), _todo('x2')],
        };
      final c = _ctl(api);
      final phases = _phases(c);
      await c.start();
      expect(api.scanCalls, 3);
      expect(c.scanSkipped, 1);
      expect(phases, [
        SimilarPhase.hashScan,
        SimilarPhase.status,
        SimilarPhase.signing,
        SimilarPhase.loading,
        SimilarPhase.ready,
      ]);
      expect(api.posted, {'x1', 'x2'});
      expect(c.signProgress!.done, 2);
    });

    test('照合が残っていなければ照合を飛ばして読む', () async {
      final api = _Api();
      final c = _ctl(api);
      final phases = _phases(c);
      await c.start();
      expect(phases, [
        SimilarPhase.hashScan,
        SimilarPhase.status,
        SimilarPhase.loading,
        SimilarPhase.ready,
      ]);
      expect(api.todoCalls, 0);
    });

    test('計算が進まなくなったら打ち切って先へ進む', () async {
      final api = _Api()
        ..scans = const [DuplicateScan(pending: 4, hashed: 0, skipped: 4)];
      final c = _ctl(api);
      await c.start();
      expect(api.scanCalls, SimilarController.stallLimit);
      expect(c.phase, SimilarPhase.ready);
    });

    test('300 件を超えたら同意を待ち、照合を始めない', () async {
      final api = _Api()
        ..status = const SimilarStatus(
          pending: 301,
          pendingWithThumb: 301,
          pendingBytesEstimate: 301 * 40960,
        )
        ..todo = {
          3: [_todo('y1')],
        };
      final c = _ctl(api);
      await c.start();
      expect(c.phase, SimilarPhase.consent);
      expect(c.consentCount, 301);
      expect(c.consentBytes, 301 * 40960);
      expect(api.todoCalls, 0);
      await c.startSigning();
      expect(api.posted, {'y1'});
      expect(c.phase, SimilarPhase.ready);
    });

    test('同意の画面で「あとで」なら照合せずに今の結果を読む', () async {
      final api = _Api()..status = const SimilarStatus(pending: 5000);
      final c = _ctl(api);
      await c.start();
      expect(c.phase, SimilarPhase.consent);
      await c.skipSigning();
      expect(c.phase, SimilarPhase.ready);
      expect(api.todoCalls, 0);
    });

    test('ちょうど 300 件なら同意を待たずに照合する', () async {
      final api = _Api()..status = const SimilarStatus(pending: 300);
      final c = _ctl(api);
      final phases = _phases(c);
      await c.start();
      expect(phases, isNot(contains(SimilarPhase.consent)));
      expect(phases, contains(SimilarPhase.signing));
      expect(api.todoCalls, 32);
    });

    test('Web はサムネのある物だけを数え、無い物はこの端末では照合できない物にする', () async {
      final api = _Api()
        ..status = const SimilarStatus(
          pending: 1000,
          pendingWithThumb: 0,
          pendingNoThumb: 1000,
          pendingBytesEstimate: 999999999,
        );
      final c = _ctl(api, isWeb: true);
      await c.start();
      // サムネが1枚も無いので Web では照合する物が無く、同意も取らない
      expect(c.phase, SimilarPhase.ready);
      expect(api.todoCalls, 0);
      expect(c.deferredHere, 1000);

      final api2 = _Api()
        ..status = const SimilarStatus(
          pending: 1000,
          pendingWithThumb: 400,
          pendingNoThumb: 600,
        );
      final c2 = _ctl(api2, isWeb: true);
      await c2.start();
      expect(c2.phase, SimilarPhase.consent);
      expect(c2.consentCount, 400);
      expect(c2.consentBytes, 400 * SimilarController.thumbBytesEstimate);
    });

    test('status の 404 は unsupported（従来の画面に戻す）', () async {
      final api = _Api()..statusError = const ApiError(404, 'not found');
      final c = _ctl(api);
      await c.start();
      expect(c.phase, SimilarPhase.unsupported);
      expect(api.groupCalls, isEmpty);
    });

    test('status のそれ以外の失敗は error で、start でやり直せる', () async {
      final api = _Api()..statusError = const ApiError(500, 'boom');
      final c = _ctl(api);
      await c.start();
      expect(c.phase, SimilarPhase.error);
      expect(c.error, isNotNull);
      api.statusError = null;
      await c.start();
      expect(c.phase, SimilarPhase.ready);
    });

    test('計算の 404 も unsupported', () async {
      final api = _Api()..scanError = const ApiError(404, 'not found');
      final c = _ctl(api);
      await c.start();
      expect(c.phase, SimilarPhase.unsupported);
    });

    test('署名の方式違い（409 alg_mismatch）はアプリ更新が要る印を立て、結果は見せる', () async {
      final api = _Api()
        ..status = const SimilarStatus(pending: 1)
        ..todo = {
          0: [_todo('z')],
        }
        ..postError = const ApiError(409, 'alg', code: 'alg_mismatch');
      final c = _ctl(api);
      await c.start();
      expect(c.appUpdateNeeded, isTrue);
      expect(c.phase, SimilarPhase.ready);
    });

    test('「途中の結果を見る」で照合を止めて一覧を読む', () async {
      final source = _Source()..delay = const Duration(milliseconds: 5);
      final api = _Api()
        ..status = const SimilarStatus(pending: 100)
        ..todo = {
          for (var s = 0; s < 32; s++) s: [_todo('s$s-1'), _todo('s$s-2')],
        };
      final c = _ctl(api, source: source);
      final done = c.start();
      while (c.phase != SimilarPhase.signing) {
        await Future<void>.delayed(Duration.zero);
      }
      await Future<void>.delayed(const Duration(milliseconds: 12));
      c.stopSigning();
      await done;
      expect(c.phase, SimilarPhase.ready);
      expect(api.posted.length, lessThan(64));
    });
  });

  group('選択', () {
    late _Api api;
    late SimilarController c;

    setUp(() async {
      api = _Api()
        ..pages = {
          'dup': [
            [
              _g('dup', [
                _m('k1', 'keeper', size: 1000),
                _m('a1', 'identical', size: 100),
                _m('a2', 'same', size: 200),
                _m('a3', 'mirror', size: 300),
                _m('a4', 'same', size: 400, variant: true),
              ]),
            ],
            [
              _g('dup', [_m('k2', 'keeper'), _m('b1', 'identical', size: 10)]),
            ],
            [
              _g('dup', [_m('k3', 'keeper'), _m('c1', 'same', size: 20)]),
            ],
          ],
          'similar': [
            [
              _g('similar', [_m('k1', 'keeper'), _m('s1', 'similar', size: 7)]),
            ],
          ],
        };
      c = _ctl(api, pageSize: 1);
      await c.start();
    });

    test('すべての重複は先に全ページを読み、identical/same の差分かもでない物だけを選ぶ', () async {
      expect(c.dupGroups, hasLength(1));
      api.groupsGate = Completer<void>();
      final f = c.selectAllDup(true);
      await Future<void>.delayed(Duration.zero);
      expect(c.loadingAll, isTrue);
      expect(c.selected, isEmpty);
      api.groupsGate!.complete();
      expect(await f, isTrue);
      expect(c.loadingAll, isFalse);
      final more = api.groupCalls.where((g) => g.cursor != null).toList();
      expect(more.map((g) => (g.tab, g.cursor, g.limit)), [
        ('dup', '1', 100),
        ('dup', '2', 100),
      ]);
      expect(c.dupGroups, hasLength(3));
      expect(c.selected.keys.toSet(), {'a1', 'a2', 'b1', 'c1'});
      // 反転・差分かも・オリジナル・似ている物は選ばない
      for (final k in ['a3', 'a4', 'k1', 'k2', 'k3', 's1']) {
        expect(c.isSelected(k), isFalse, reason: k);
      }
      expect(c.selectedCount, 4);
      expect(c.selectedBytes, 100 + 200 + 10 + 20);
      expect(c.allDupState, isTrue);
      expect(c.selectedKinds, {'identical': 2, 'same': 2});
      expect(c.selectedVariants, 0);
    });

    test('すべての重複を外すと重複の段の選択だけが消える', () async {
      final sim = c.simGroups.single;
      c.toggle(sim, sim.member('s1')!);
      await c.selectAllDup(true);
      expect(c.selectedCount, 5);
      await c.selectAllDup(false);
      expect(c.selected.keys, ['s1']);
      expect(c.allDupState, isFalse);
    });

    test('ページを読み切れなければ何も選ばない', () async {
      api.groupsError = const ApiError(500, 'boom');
      expect(await c.selectAllDup(true), isFalse);
      expect(c.selected, isEmpty);
      expect(c.loadingAll, isFalse);
    });

    test('組のチェックは重複の段なら identical/same、似ている段なら similar だけ', () {
      final g = c.dupGroups.single;
      c.setGroupSelected(g, true);
      expect(c.selected.keys.toSet(), {'a1', 'a2'});
      expect(c.groupState(g), isTrue);
      final sim = c.simGroups.single;
      c.setGroupSelected(sim, true);
      expect(c.isSelected('s1'), isTrue);
      expect(c.isSelected('k1'), isFalse);
      c.setGroupSelected(g, false);
      expect(c.selected.keys, ['s1']);
      expect(c.groupState(g), isFalse);
    });

    test('1件ずつなら反転・差分かもも選べるが、オリジナルは選べない', () {
      final g = c.dupGroups.single;
      c.toggle(g, g.member('a3')!);
      c.toggle(g, g.member('a4')!);
      c.toggle(g, g.member('k1')!);
      expect(c.selected.keys.toSet(), {'a3', 'a4'});
      expect(c.groupState(g), isNull);
      expect(c.selectedKinds, {'mirror': 1, 'same': 1});
      expect(c.selectedVariants, 1);
      c.toggle(g, g.member('a3')!);
      expect(c.isSelected('a3'), isFalse);
    });

    test('読み取り専用では選べない', () async {
      final ro = _ctl(api, readOnly: true);
      await ro.start();
      final g = ro.dupGroups.single;
      ro.toggle(g, g.member('a1')!);
      ro.setGroupSelected(g, true);
      expect(await ro.selectAllDup(true), isFalse);
      expect(ro.selected, isEmpty);
      expect((await ro.commit()).trashed, 0);
      expect(api.trashCalls, isEmpty);
    });
  });

  group('オリジナルの選び直し', () {
    test('relabel の札に入れ替え、別物と返った物は選べなくする', () async {
      final api = _Api()
        ..pages = {
          'dup': [
            [
              _g('dup', [
                _m('k', 'keeper', size: 50),
                _m('a', 'identical', size: 50),
                _m('b', 'same', size: 60),
                _m('c', 'mirror', size: 70),
              ]),
            ],
          ],
          'similar': [const []],
        }
        ..labels = {
          'k': const SimilarLabel(match: 'identical', ph: 0, dh: 0),
          'c': const SimilarLabel(match: 'similar', ph: 8, dh: 9),
        };
      final c = _ctl(api);
      await c.start();
      final g = c.dupGroups.single;
      c.setGroupSelected(g, true);
      expect(c.selected.keys.toSet(), {'a', 'b'});

      expect(await c.setKeeper(g, 'a'), isNull);
      expect(api.relabelCalls.single.keep, 'a');
      expect(api.relabelCalls.single.keys, ['k', 'b', 'c']);
      expect(g.keeper, 'a');
      expect(g.member('a')!.match, 'keeper');
      expect(g.member('k')!.match, 'identical');
      expect(g.member('c')!.match, 'similar');
      expect(g.member('c')!.ph, 8);
      // b は新しいオリジナルとは別物: 選択から外れ、もう選べない
      expect(g.disabled, {'b'});
      expect(c.isSelected('a'), isFalse);
      expect(c.isSelected('b'), isFalse);
      expect(c.isSelected('k'), isFalse);
      c.toggle(g, g.member('b')!);
      expect(c.isSelected('b'), isFalse);
      expect(c.keeperOverride[(tier: 'dup', id: 'k')], 'a');
      // 前のオリジナルは同じ中身なので、組のチェックで拾える
      c.setGroupSelected(g, true);
      expect(c.selected.keys, ['k']);
      expect(g.reclaim, 50);

      await c.commit();
      expect(api.trashCalls.single, [(key: 'k', keep: 'a')]);
    });

    test('relabel に失敗したら何も変えない', () async {
      final api = _Api()
        ..pages = {
          'dup': [
            [
              _g('dup', [_m('k', 'keeper'), _m('a', 'identical')]),
            ],
          ],
          'similar': [const []],
        }
        ..relabelError = const ApiError(500, 'boom');
      final c = _ctl(api);
      await c.start();
      final g = c.dupGroups.single;
      expect(await c.setKeeper(g, 'a'), isNotNull);
      expect(g.keeper, 'k');
      expect(g.member('a')!.match, 'identical');
      expect(g.relabeling, isFalse);
      expect(c.keeperOverride, isEmpty);
    });

    test('読み直した後も同じ組なら選び直したオリジナルを保つ', () async {
      final api = _Api()
        ..pages = {
          'dup': [
            [
              _g('dup', [_m('k', 'keeper'), _m('a', 'identical')]),
            ],
          ],
          'similar': [const []],
        }
        ..labels = {'k': const SimilarLabel(match: 'identical')};
      final c = _ctl(api);
      await c.start();
      await c.setKeeper(c.dupGroups.single, 'a');
      await c.reload();
      expect(c.dupGroups.single.keeper, 'a');
      expect(api.relabelCalls, hasLength(2));
    });

    test('先頭のページに無い組の選び直しも、読み直して続きを読んだ時に当て直し、すべての重複で選ばない', () async {
      final api = _Api()
        ..pages = {
          'dup': [
            [
              _g('dup', [_m('p', 'keeper'), _m('q', 'identical')]),
            ],
            [
              _g('dup', [_m('k', 'keeper'), _m('a', 'same'), _m('b', 'same')]),
            ],
          ],
          'similar': [const []],
        }
        ..labels = {
          'k': const SimilarLabel(match: 'same'),
          'b': const SimilarLabel(match: 'same'),
        };
      final c = _ctl(api);
      await c.start();
      await c.loadMore('dup');
      final g2 = c.dupGroups.firstWhere((g) => g.id == 'k');
      expect(await c.setKeeper(g2, 'a'), isNull);
      // 取り消しの後などで読み直す。2 ページ目の組はまだ読んでいないが、選び直しは捨てない
      await c.reload();
      expect(c.keeperOverride[(tier: 'dup', id: 'k')], 'a');
      await c.loadMore('dup');
      final again = c.dupGroups.firstWhere((g) => g.id == 'k');
      expect(again.keeper, 'a');
      await c.reload();
      // 続きを読まずに「すべての重複」を押しても、読んだ組に当て直してから選ぶ
      expect(await c.selectAllDup(true), isTrue);
      expect(c.dupGroups.firstWhere((g) => g.id == 'k').keeper, 'a');
      expect(c.isSelected('a'), isFalse);
      expect(c.selected.keys.toSet(), {'q', 'k', 'b'});
    });

    test('段を読み切っても組が無ければ、選び直しを捨てる', () async {
      final api = _Api()
        ..pages = {
          'dup': [
            [
              _g('dup', [_m('k', 'keeper'), _m('a', 'identical')]),
            ],
          ],
          'similar': [const []],
        }
        ..labels = {'k': const SimilarLabel(match: 'identical')};
      final c = _ctl(api);
      await c.start();
      await c.setKeeper(c.dupGroups.single, 'a');
      api.pages = {
        'dup': [const []],
        'similar': [const []],
      };
      await c.reload();
      expect(c.keeperOverride, isEmpty);
    });

    test('付け直しの途中で付け替える先が組から外れても落ちず、居ない物をオリジナルにしない', () async {
      final api = _GatedRelabelApi()
        ..pages = {
          'dup': [
            [
              _g('dup', [_m('k', 'keeper'), _m('a', 'same'), _m('b', 'same')]),
            ],
          ],
          'similar': [const []],
        }
        ..labels = {
          'k': const SimilarLabel(match: 'same'),
          'b': const SimilarLabel(match: 'same'),
        };
      final c = _ctl(api);
      await c.start();
      final g = c.dupGroups.single;
      c.toggle(g, g.member('b')!);
      final keeping = c.setKeeper(g, 'a');
      expect(g.relabeling, isTrue);
      // 付け直しの間は、その組の物を1件だけ送る・選ぶ・まとめて送ることもしない
      final one = await c.trashOne(g, g.member('a')!);
      expect(one.trashed, 0);
      c.toggle(g, g.member('a')!);
      expect(c.isSelected('a'), isFalse);
      expect(c.selectedCount, 0);
      expect(api.trashCalls, isEmpty);
      // ビューアなど別の口で消えた
      g.members.removeWhere((m) => m.key == 'a');
      api.gate.complete();
      expect(await keeping, isNotNull);
      expect(g.keeper, 'k');
      expect(g.relabeling, isFalse);
      expect(c.keeperOverride, isEmpty);
      expect(c.selectedCount, 1);
    });
  });

  group('確かめの後に送る物', () {
    test('確かめを開いた時の選択だけを送り、開いている間に増えた分は送らない', () async {
      final api = _Api()
        ..pages = {
          'dup': [
            [
              _g('dup', [_m('k0', 'keeper'), _m('a0', 'identical')]),
            ],
            [
              for (var g = 1; g <= 30; g++)
                _g('dup', [_m('k$g', 'keeper'), _m('a$g', 'identical')]),
            ],
          ],
          'similar': [const []],
        };
      final c = _ctl(api);
      await c.start();
      c.toggle(c.dupGroups.single, c.dupGroups.single.member('a0')!);
      final hold = Completer<void>();
      api.holdNextCursor = hold;
      final all = c.selectAllDup(true);
      await Future<void>.delayed(Duration.zero);
      expect(c.loadingAll, isTrue);
      final picked = c.selection();
      expect(picked.count, 1);
      expect(picked.kinds, {'identical': 1});
      hold.complete();
      await all;
      expect(c.selectedCount, 31);
      await c.commit(picked);
      expect(api.trashCalls.expand((ch) => ch).toList(), [
        (key: 'a0', keep: 'k0'),
      ]);
      // 送らなかった分は選んだまま残る
      expect(c.selectedCount, 30);
    });

    test('確かめの間に選択から外れた物は、写しにあっても送らない', () async {
      final api = _Api()
        ..pages = {
          'dup': [
            [
              _g('dup', [
                _m('k', 'keeper'),
                _m('a', 'identical'),
                _m('b', 'identical'),
              ]),
            ],
          ],
          'similar': [const []],
        };
      final c = _ctl(api);
      await c.start();
      final g = c.dupGroups.single;
      c.setGroupSelected(g, true);
      final picked = c.selection();
      expect(picked.count, 2);
      c.toggle(g, g.member('b')!, false);
      await c.commit(picked);
      expect(api.trashCalls.single, [(key: 'a', keep: 'k')]);
    });
  });

  group('削除', () {
    test('40 件ずつ、同時に 2 本までで送り、進み具合を出す', () async {
      final api = _Api()
        ..pages = {
          'dup': manyGroups(5, 20),
          'similar': [const []],
        }
        ..trashDelay = const Duration(milliseconds: 5);
      final c = _ctl(api);
      await c.start();
      await c.selectAllDup(true);
      expect(c.selectedCount, 100);
      final progress = <int>[];
      c.addListener(() {
        if (c.committing) progress.add(c.commitDone);
      });
      final r = await c.commit();
      expect(api.trashCalls.map((c) => c.length), [40, 40, 20]);
      expect(api.maxTrashInFlight, 2);
      for (final call in api.trashCalls) {
        for (final it in call) {
          expect(it.keep, 'k${it.key.substring(1).split('-').first}');
        }
      }
      // 塊が返るたびに進み、減ることはない
      expect(progress.toSet().containsAll({0, 40, 80, 100}), isTrue);
      for (var i = 1; i < progress.length; i++) {
        expect(progress[i], greaterThanOrEqualTo(progress[i - 1]));
      }
      expect(c.commitTotal, 100);
      expect(c.commitDone, 100);
      expect(c.committing, isFalse);
      expect(r.receipts, hasLength(100));
      expect(r.kinds, {'identical': 100});
      expect(r.failed, 0);
      // オリジナルだけ残った組は畳む
      expect(c.dupGroups, isEmpty);
      expect(c.groupCount('dup'), 0);
      expect(c.selected, isEmpty);
      expect(r.outcome('a').trashed, 100);
    });

    test('一部が移せなければその行を元の組の元の位置へ戻し、件数を返し、読み直しの印を立てる', () async {
      final api = _Api()
        ..pages = {
          'dup': [
            [
              _g('dup', [_m('k0', 'keeper'), _m('x0', 'identical')]),
              _g('dup', [
                _m('k1', 'keeper'),
                _m('a', 'identical', size: 10),
                _m('b', 'same', size: 20),
                _m('c', 'same', size: 30),
              ]),
              _g('dup', [_m('k2', 'keeper'), _m('x2', 'identical')]),
            ],
          ],
          'similar': [const []],
        }
        ..summary = const SimilarSummary(
          dup: SimilarTierSummary(groups: 3, items: 8, reclaimable: 260),
        )
        ..trashErrors = {'b': 'not_similar'};
      final c = _ctl(api);
      await c.start();
      final g1 = c.dupGroups[1];
      c.setGroupSelected(g1, true);
      final r = await c.commit();
      expect(r.failed, 1);
      expect(r.errors, {'b': 'not_similar'});
      expect(r.receipts.map((t) => t.key), ['a', 'c']);
      expect(r.needsReload, isTrue);
      expect(c.needsReload, isTrue);
      // 組は畳まれた後、元の 2 番目に戻る
      expect([for (final g in c.dupGroups) g.id], ['k0', 'k1', 'k2']);
      expect(_keys(c.dupGroups[1]), ['k1', 'b']);
      expect(c.groupCount('dup'), 3);
      expect(c.dupReclaimable, 260 - 10 - 30);
      final o = r.outcome('a');
      expect(o.failed, 1);
      expect(o.failedTargets, [(lib: 'a', key: 'b')]);
    });

    test('塊ごと失敗したら全部を元の並びに戻す', () async {
      final api = _Api()
        ..pages = {
          'dup': [
            [
              _g('dup', [
                _m('k', 'keeper'),
                _m('a', 'identical'),
                _m('b', 'mirror'),
                _m('c', 'same'),
              ]),
            ],
          ],
          'similar': [const []],
        }
        ..trashChunkError = const ApiError(
          403,
          'ro',
          code: 'read_only_library',
        );
      final c = _ctl(api);
      await c.start();
      final g = c.dupGroups.single;
      c.toggle(g, g.member('c')!);
      c.toggle(g, g.member('a')!);
      final r = await c.commit();
      expect(r.failed, 2);
      expect(r.needsReload, isFalse);
      expect(_keys(c.dupGroups.single), ['k', 'a', 'b', 'c']);
    });

    test('中止したらまだ送っていない塊は送らずに戻す', () async {
      final api = _Api()
        ..pages = {
          'dup': manyGroups(1, 120),
          'similar': [const []],
        }
        ..trashDelay = const Duration(milliseconds: 5);
      final c = _ctl(api);
      await c.start();
      await c.selectAllDup(true);
      final f = c.commit();
      await Future<void>.delayed(Duration.zero);
      c.cancelCommit();
      final r = await f;
      expect(api.trashCalls, hasLength(2));
      expect(r.trashed, 80);
      expect(r.unsent, 40);
      final g = c.dupGroups.single;
      expect(_keys(g), ['k0', for (var i = 80; i < 120; i++) 'g0-$i']);
    });

    test('長押しの1件だけゴミ箱は他の選択に触らない', () async {
      final api = _Api()
        ..pages = {
          'dup': [
            [
              _g('dup', [
                _m('k', 'keeper'),
                _m('a', 'identical'),
                _m('b', 'same'),
              ]),
            ],
          ],
          'similar': [const []],
        };
      final c = _ctl(api);
      await c.start();
      final g = c.dupGroups.single;
      c.toggle(g, g.member('b')!);
      final r = await c.trashOne(g, g.member('a')!);
      expect(api.trashCalls.single, [(key: 'a', keep: 'k')]);
      expect(r.receipts.single.trashKey, '.trash/1/a');
      expect(c.selected.keys, ['b']);
      expect(_keys(g), ['k', 'b']);
      // オリジナルは1件だけでも消させない
      expect((await c.trashOne(g, g.member('k')!)).trashed, 0);
      expect(api.trashCalls, hasLength(1));
    });

    test('空けられる容量の足し引き', () async {
      final api = _Api()
        ..pages = {
          'dup': [
            [
              _g(
                'dup',
                [
                  _m('k', 'keeper', size: 500),
                  _m('a', 'identical', size: 100),
                  _m('b', 'same', size: 200),
                  _m('c', 'same', size: 300, variant: true),
                  _m('d', 'mirror', size: 400),
                ],
                // 応答に載らなかった 3 件ぶん（700）を含む Worker の合計
                reclaim: 1000,
                more: 3,
              ),
            ],
          ],
          'similar': [const []],
        }
        ..summary = const SimilarSummary(
          dup: SimilarTierSummary(groups: 1, items: 8, reclaimable: 5000),
        )
        ..labels = {
          'k': const SimilarLabel(match: 'identical'),
          'b': const SimilarLabel(match: 'same'),
          'c': const SimilarLabel(match: 'same', variant: true),
          'd': const SimilarLabel(match: 'mirror'),
        };
      final c = _ctl(api);
      await c.start();
      final g = c.dupGroups.single;
      expect(g.reclaim, 1000);
      expect(c.dupReclaimable, 5000);
      c.toggle(g, g.member('a')!);
      c.toggle(g, g.member('d')!);
      expect(c.selectedBytes, 500);

      api.trashErrors = {'d': 'not_similar'};
      await c.commit();
      // a（100）だけが減り、反転の d は戻っても容量に数えない
      expect(g.reclaim, 900);
      expect(c.dupReclaimable, 4900);

      // オリジナルを b に替えると、k（500）が数えられ、載らなかった分は数えない
      await c.setKeeper(g, 'b');
      expect(g.reclaim, 500);
      expect(c.dupReclaimable, 4900 - 900 + 500);
    });

    test('取り消しは 40 件ずつ 2 本までで送り、RestoreOutcome にまとめ、両方の段を読み直す', () async {
      final api = _Api()
        ..undoFail = {'t3': 409, 't4': 404}
        ..undoChunkFailFor = 't44';
      final c = _ctl(api);
      await c.start();
      final before = api.groupCalls.length;
      final receipts = [
        for (var i = 0; i < 45; i++) TrashReceipt('a', 't$i', key: 'k$i'),
        const TrashReceipt('a', '', key: 'old'),
      ];
      final o = await c.undo(receipts);
      expect(api.undoCalls.map((c) => c.length), [40, 5]);
      expect(api.maxUndoInFlight, 2);
      expect(o.total, 45);
      expect(o.restored, 38);
      expect(o.conflict, 1);
      expect(o.notFound, 1);
      expect(o.readOnly, 5);
      expect(o.failures['t3'], 409);
      expect(o.failures['t44'], 403);
      expect(restoreSummaryMessage(o), isNotNull);
      final reloaded = api.groupCalls.skip(before).map((g) => g.tab).toSet();
      expect(reloaded, {'dup', 'similar'});
      expect(c.phase, SimilarPhase.ready);
    });

    test('取り消しでアルバムだけ書けなかった物（albums_failed）は、同じ受け取りで呼び直す', () async {
      // t1 は 1 回だけ失敗して 2 回目で戻る。t2 はずっと失敗する
      final api = _Api()..undoAlbumsFail = {'t1': 1, 't2': 99};
      final c = _ctl(api);
      await c.start();
      final o = await c.undo([
        for (var i = 0; i < 3; i++) TrashReceipt('a', 't$i', key: 'k$i'),
      ]);
      expect(api.undoCalls, [
        ['t0', 't1', 't2'],
        ['t1', 't2'],
        ['t2'],
      ]);
      expect(o.total, 3);
      // t2 もファイルは戻っている。戻せなかったとは言わず、アルバムへ戻せなかったと別に知らせる
      expect(o.restored, 3);
      expect(o.failures, isEmpty);
      expect(o.other, 0);
      expect(o.albumsFailed, 1);
      expect(restoreSummaryMessage(o), '1件は戻しましたが、アルバムには戻せませんでした');
    });

    test(
      '取り消しの塊ごと 5xx が返ったら、同じ受け取りで呼び直し、前の呼び出しが戻し終えていた物（404）も戻したと数える',
      () async {
        final api = _Api()
          ..undoThrowOn = {0: const ApiError(502, 'bad gateway')}
          // 1 回目の呼び出しは Worker の中で t1 を戻し終えてから落ちた
          ..undoFail = {'t1': 404};
        final c = _ctl(api);
        await c.start();
        final o = await c.undo([
          for (var i = 0; i < 3; i++) TrashReceipt('a', 't$i', key: 'k$i'),
        ]);
        expect(api.undoCalls, [
          ['t0', 't1', 't2'],
          ['t0', 't1', 't2'],
        ]);
        expect(o.restored, 3);
        expect(o.failures, isEmpty);
        expect(restoreSummaryMessage(o), isNull);
      },
    );

    test('取り消しの通信が続けて落ちたら待ちの回数だけ呼び直し、それでも駄目なら戻せなかったと返す', () async {
      final api = _Api()
        ..undoThrowOn = {for (var i = 0; i < 3; i++) i: Exception('offline')};
      final c = _ctl(api);
      await c.start();
      final o = await c.undo([const TrashReceipt('a', 't0', key: 'k0')]);
      expect(api.undoCalls, [
        ['t0'],
        ['t0'],
        ['t0'],
      ]);
      expect(o.restored, 0);
      expect(o.failures, {'t0': 0});
      expect(o.other, 1);
    });

    test('アルバムだけ書けなかった物の呼び直しが通信で落ちても、ファイルは戻ったまま数える', () async {
      // 1 回目は albums_failed、ただ 1 回の呼び直しは 503 で落ちる
      final api = _Api()
        ..undoAlbumsFail = {'t0': 1}
        ..undoThrowOn = {1: const ApiError(503, 'unavailable')};
      final c = _ctl(api, undoRetryDelays: const [Duration.zero]);
      await c.start();
      final o = await c.undo([const TrashReceipt('a', 't0', key: 'k0')]);
      expect(api.undoCalls, [
        ['t0'],
        ['t0'],
      ]);
      expect(o.restored, 1);
      expect(o.failures, isEmpty);
      expect(o.albumsFailed, 1);
      expect(restoreSummaryMessage(o), '1件は戻しましたが、アルバムには戻せませんでした');
    });

    test('戻すのにも失敗してゴミ箱に残った物（put_back_failed）は一覧へ戻さず、ゴミ箱に残ったと返す', () async {
      final api = _Api()
        ..pages = {
          'dup': [
            [
              _g('dup', [
                _m('k', 'keeper'),
                _m('a', 'identical'),
                _m('b', 'identical'),
              ]),
            ],
          ],
          'similar': [const []],
        }
        ..trashErrors = {'b': 'put_back_failed'};
      final c = _ctl(api);
      await c.start();
      c.setGroupSelected(c.dupGroups.single, true);
      final r = await c.commit();
      expect(r.receipts.map((t) => t.key), ['a']);
      expect(r.leftInTrash, ['b']);
      // 「移せませんでした」には数えない（ゴミ箱には移っている）
      expect(r.failed, 0);
      expect(r.errors, isEmpty);
      expect(r.needsReload, isTrue);
      // 元の場所に無い物を一覧に戻さない
      expect(c.dupGroups, isEmpty);
    });
  });

  group('すべての重複で選べる物が無い', () {
    test('反転と差分かもしか無ければ押せず、1件ずつ選んでも一部のままにならない', () async {
      final api = _Api()
        ..pages = {
          'dup': [
            [
              _g('dup', [
                _m('k', 'keeper'),
                _m('m', 'mirror'),
                _m('v', 'same', variant: true),
              ]),
            ],
          ],
          'similar': [const []],
        };
      final c = _ctl(api);
      await c.start();
      expect(c.dupSelectable, isFalse);
      expect(c.allDupState, isFalse);
      final g = c.dupGroups.single;
      c.toggle(g, g.member('m')!);
      expect(c.isSelected('m'), isTrue);
      // 1件ずつ選んだ反転は「すべての重複」の一部に数えない
      expect(c.allDupState, isFalse);
      expect(await c.selectAllDup(true), isTrue);
      expect(c.selected.keys, ['m']);
      expect(c.allDupState, isFalse);
    });

    test('1件ずつ選んだ反転があっても、押せば全部になり、もう一度で全部外れる', () async {
      final api = _Api()
        ..pages = {
          'dup': [
            [
              _g('dup', [
                _m('k', 'keeper'),
                _m('a', 'identical'),
                _m('m', 'mirror'),
              ]),
            ],
          ],
          'similar': [const []],
        };
      final c = _ctl(api);
      await c.start();
      final g = c.dupGroups.single;
      c.toggle(g, g.member('m')!);
      expect(c.allDupState, isFalse);
      await c.selectAllDup(c.allDupState != true);
      expect(c.allDupState, isTrue);
      expect(c.selected.keys.toSet(), {'a', 'm'});
      await c.selectAllDup(c.allDupState != true);
      expect(c.allDupState, isFalse);
      expect(c.selected, isEmpty);
    });
  });

  group('dispose', () {
    test('計算の繰り返しを止める', () async {
      final api = _Api()
        ..scans = const [DuplicateScan(pending: 9, hashed: 1, skipped: 0)]
        ..scanDelay = const Duration(milliseconds: 2);
      final c = _ctl(api);
      unawaited(c.start());
      await Future<void>.delayed(const Duration(milliseconds: 10));
      c.dispose();
      final calls = api.scanCalls;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(api.scanCalls, lessThanOrEqualTo(calls + 1));
    });

    test('照合を止める', () async {
      final source = _Source()..delay = const Duration(milliseconds: 5);
      final api = _Api()
        ..status = const SimilarStatus(pending: 100)
        ..todo = {
          for (var s = 0; s < 32; s++) s: [_todo('s$s')],
        };
      final c = _ctl(api, source: source);
      unawaited(c.start());
      while (c.phase != SimilarPhase.signing) {
        await Future<void>.delayed(Duration.zero);
      }
      await Future<void>.delayed(const Duration(milliseconds: 8));
      c.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final todo = api.todoCalls;
      final signed = source.calls;
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(api.todoCalls, todo);
      expect(source.calls, signed);
      expect(todo, lessThan(32));
      expect(api.groupCalls, isEmpty);
    });

    test('削除の新しい塊を送らない', () async {
      final api = _Api()
        ..pages = {
          'dup': manyGroups(1, 200),
          'similar': [const []],
        }
        ..trashDelay = const Duration(milliseconds: 5);
      final c = _ctl(api);
      await c.start();
      await c.selectAllDup(true);
      final f = c.commit();
      await Future<void>.delayed(Duration.zero);
      c.dispose();
      final r = await f;
      expect(api.trashCalls, hasLength(2));
      expect(r.unsent, 120);
    });
  });

  group('見直しで見つかった穴', () {
    test('一覧の 413 too_many_for_similar は従来の画面に替える（同じファイルの組を失わない）', () async {
      final api = _Api()
        ..groupsError = const ApiError(
          413,
          'too many',
          code: 'too_many_for_similar',
        );
      final c = _ctl(api);
      await c.start();
      expect(c.phase, SimilarPhase.unsupported);
      // 黙って替えず、断られた理由を画面に出せるようにする
      expect(c.tooManyForSimilar, isTrue);
    });

    test('status が上限を超えると言えば、照合を始めず（同意も取らず）従来の画面に替える', () async {
      final api = _Api()
        ..status = const SimilarStatus(
          images: 52000,
          pending: 52000,
          pendingNoThumb: 52000,
          pendingBytesEstimate: 52000 * 40960,
          maxNodes: 40000,
          tooMany: true,
        )
        ..todo = {
          0: [_todo('z')],
        };
      final c = _ctl(api);
      await c.start();
      expect(c.phase, SimilarPhase.unsupported);
      expect(c.tooManyForSimilar, isTrue);
      expect(api.todoCalls, 0);
      expect(api.posted, isEmpty);
      expect(api.groupCalls, isEmpty);

      // 上限の内に収まれば（写真を減らした後のやり直し）、いつもどおり進む
      api.status = const SimilarStatus(maxNodes: 40000);
      await c.start();
      expect(c.phase, SimilarPhase.ready);
      expect(c.tooManyForSimilar, isFalse);
    });

    test('一覧の 5xx は error だが、同じファイルだけの従来の画面へ移れる', () async {
      final api = _Api()..groupsError = const ApiError(503, 'cpu');
      final c = _ctl(api);
      await c.start();
      expect(c.phase, SimilarPhase.error);
      expect(c.exactFallback, isTrue);
      c.useExactScreen();
      expect(c.phase, SimilarPhase.unsupported);
    });

    test('計算そのものの失敗では従来の画面を勧めない（そちらも同じ計算を使う）', () async {
      final api = _Api()..scanError = const ApiError(500, 'boom');
      final c = _ctl(api);
      await c.start();
      expect(c.phase, SimilarPhase.error);
      expect(c.exactFallback, isFalse);
    });

    test('オリジナルを替えるともう一方の段の同じ組も替わり、前のオリジナルを残す物にして送らない', () async {
      final api = _Api()
        ..pages = {
          'dup': [
            [
              _g('dup', [_m('K', 'keeper'), _m('N', 'same')]),
            ],
          ],
          'similar': [
            [
              _g('similar', [_m('K', 'keeper'), _m('S', 'similar')]),
            ],
          ],
        }
        ..labels = {
          'K': const SimilarLabel(match: 'same', ph: 1, dh: 1),
          'S': const SimilarLabel(match: 'similar', ph: 8, dh: 9),
        };
      final c = _ctl(api);
      await c.start();
      expect(await c.setKeeper(c.dupGroups.single, 'N'), isNull);
      final sim = c.simGroups.single;
      expect(sim.keeper, 'N');
      expect(sim.member('N')!.isKeeper, isTrue);
      expect(sim.member('K')!.match, 'same');
      c.setGroupSelected(c.dupGroups.single, true);
      c.setGroupSelected(sim, true);
      expect(c.selected.keys.toSet(), {'K', 'S'});
      final r = await c.commit();
      final sent = api.trashCalls.expand((x) => x).toList();
      expect(sent.map((i) => (i.key, i.keep)).toSet(), {('K', 'N'), ('S', 'N')});
      expect(r.keptAsKeeper, 0);
    });

    test('オリジナルを替えた後、前のオリジナルを似ているの段で選んでも、「すべての重複」は全部のまま止まらない', () async {
      final api = _Api()
        ..pages = {
          'dup': [
            [
              _g('dup', [_m('K', 'keeper'), _m('N', 'same')]),
            ],
          ],
          'similar': [
            [
              _g('similar', [_m('K', 'keeper'), _m('S', 'similar')]),
            ],
          ],
        }
        ..labels = {
          'K': const SimilarLabel(match: 'same', ph: 1, dh: 1),
          'S': const SimilarLabel(match: 'similar', ph: 8, dh: 9),
        };
      final c = _ctl(api);
      await c.start();
      expect(await c.setKeeper(c.dupGroups.single, 'N'), isNull);
      final sim = c.simGroups.single;
      c.toggle(sim, sim.member('K')!, true);
      // 似ているの段で選んだ物は「すべての重複」に数えない
      expect(c.allDupState, isFalse);
      expect(await c.selectAllDup(c.allDupState != true), isTrue);
      expect(c.allDupState, isTrue);
      expect(await c.selectAllDup(c.allDupState != true), isTrue);
      expect(c.allDupState, isFalse);
      expect(c.selected, isEmpty);
    });

    test('選んだ物が選んだ別の物のオリジナルなら、それは送らずに残して数を返す', () async {
      final api = _Api()
        ..pages = {
          'dup': [
            [
              _g('dup', [_m('A', 'keeper'), _m('B', 'same')]),
            ],
          ],
          'similar': [
            [
              _g('similar', [_m('B', 'keeper'), _m('C', 'similar')]),
            ],
          ],
        };
      final c = _ctl(api);
      await c.start();
      c.setGroupSelected(c.dupGroups.single, true);
      c.setGroupSelected(c.simGroups.single, true);
      final r = await c.commit();
      expect(api.trashCalls.expand((x) => x).map((i) => (i.key, i.keep)), [
        ('C', 'B'),
      ]);
      expect(r.keptAsKeeper, 1);
      expect(c.dupGroups.single.member('B'), isNotNull);
      expect(c.isSelected('B'), isFalse);
    });

    test('「すべての重複」の後に届いた古い続きのページは、読み切った位置を書き戻さない', () async {
      final api = _Api()
        ..pages = {
          'dup': [
            [
              _g('dup', [_m('A', 'keeper'), _m('a', 'same')]),
            ],
            [
              _g('dup', [_m('B', 'keeper'), _m('b', 'same')]),
            ],
            [
              _g('dup', [_m('C', 'keeper'), _m('c', 'same')]),
            ],
          ],
          'similar': [const []],
        };
      final c = _ctl(api, pageSize: 1);
      await c.start();
      final hold = Completer<void>();
      api.holdNextCursor = hold;
      final more = c.loadMore('dup');
      await Future<void>.delayed(Duration.zero);
      expect(await c.selectAllDup(true), isTrue);
      expect(c.dupCursor, isNull);
      expect(c.allDupState, isTrue);
      hold.complete();
      await more;
      expect(c.dupCursor, isNull);
      expect(c.allDupState, isTrue);
      expect(c.dupGroups.map((g) => g.id), ['A', 'B', 'C']);
    });

    test('先に消されていた物（source_not_found）や塊ごとの通信の失敗では一覧を読み直す', () async {
      final api = _Api()
        ..pages = {
          'dup': [
            [
              _g('dup', [_m('K', 'keeper'), _m('x', 'same'), _m('y', 'same')]),
            ],
          ],
          'similar': [const []],
        }
        ..trashErrors = {'x': 'source_not_found'};
      final c = _ctl(api);
      await c.start();
      c.toggle(c.dupGroups.single, c.dupGroups.single.member('x')!);
      final r = await c.commit();
      expect(r.needsReload, isTrue);

      await c.reload();
      api.trashErrors = {};
      api.trashChunkError = const ApiError(0, 'timeout');
      c.toggle(c.dupGroups.single, c.dupGroups.single.member('y')!);
      final r2 = await c.commit();
      expect(r2.failed, 1);
      expect(r2.needsReload, isTrue);
    });

    test('Worker が下げた件数（status の trashBatch）で分けて送り、取り消しも同じ件数で送る', () async {
      final api = _Api()
        ..status = const SimilarStatus(trashBatch: 10)
        ..pages = {
          'dup': manyGroups(1, 25),
          'similar': [const []],
        };
      final c = _ctl(api);
      await c.start();
      await c.selectAllDup(true);
      final r = await c.commit();
      expect(api.trashCalls.map((x) => x.length), [10, 10, 5]);
      await c.undo(r.receipts);
      expect(api.undoCalls.map((x) => x.length), [10, 10, 5]);
    });

    test('まとめて送っている間の1件だけゴミ箱は受け付けず、その事を返す', () async {
      final api = _Api()
        ..pages = {
          'dup': [
            [
              _g('dup', [_m('K', 'keeper'), _m('x', 'same'), _m('y', 'same')]),
            ],
          ],
          'similar': [const []],
        }
        ..trashDelay = const Duration(milliseconds: 5);
      final c = _ctl(api);
      await c.start();
      final g = c.dupGroups.single;
      c.toggle(g, g.member('x')!);
      final f = c.commit();
      final one = await c.trashOne(g, g.member('y')!);
      expect(one.busy, isTrue);
      await f;
      expect(api.trashCalls.expand((x) => x).map((i) => i.key), ['x']);
    });

    test('載らなかった分（more）のある組は、畳まれなくても消した後に読み直す', () async {
      final api = _Api()
        ..pages = {
          'dup': [
            [
              _g('dup', [
                _m('K', 'keeper'),
                _m('x', 'identical'),
                _m('m', 'mirror'),
              ], more: 5),
            ],
          ],
          'similar': [const []],
        };
      final c = _ctl(api);
      await c.start();
      expect(c.dupHidden, 5);
      c.setGroupSelected(c.dupGroups.single, true);
      final r = await c.commit();
      expect(c.dupGroups.single.members.map((m) => m.key), ['K', 'm']);
      expect(r.needsReload, isTrue);
    });
  });
}
