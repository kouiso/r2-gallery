// 手元の worker（wrangler dev --local, worker/wrangler.test.toml）に、tools/similar-fixture-seed.mjs が
// 合成画像だけを種まきした状態で流す確認。fake API のテストでは届かない
// 「Dart の vs1 で作った署名を本物の Worker が受け、期待どおりの組に束ね、まとめて消して戻せるか」を見る。
// PC ツール（sharp）の署名を流し込む偽物は Dart では作れないので、本物の取得経路と vs1FromEncoded を通す。
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/duplicates/signature_backfill.dart';
import 'package:r2_gallery/src/duplicates/signature_source.dart';
import 'package:r2_gallery/src/duplicates/similar_controller.dart';

const _endpoint = String.fromEnvironment(
  'LIVE_ENDPOINT',
  defaultValue: 'http://127.0.0.1:8787',
);
// worker/wrangler.test.toml の仮のトークン（本番の値ではない）
const _token = String.fromEnvironment(
  'LIVE_TOKEN',
  defaultValue: 'test-access-token',
);
// flutter test は flutter/ で動くので、種まきの既定の出力先はリポジトリのルートの .work/ を指す
const _expectedPath = String.fromEnvironment(
  'LIVE_EXPECTED',
  defaultValue: '../.work/similar-e2e/expected.json',
);
const _lib = 'a';
const _readOnlyLib = 'b';

// 原本 337 枚の取得・縮小・署名を手元で回すので、既定の 30 秒では終わらない
const _long = Timeout(Duration(minutes: 15));

// flutter_test は HttpClient を差し替えて外へ出さない。Dio だけ素の HttpClient を使わせる
class _Real extends HttpOverrides {}

ApiClient _liveApi() {
  final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 10)))
    ..httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () => _Real().createHttpClient(null),
    );
  return ApiClient(dio: dio)..conn = const Connection(_endpoint, _token);
}

/// 本番の Worker に向けて流すと、本物の写真をゴミ箱へ動かしてしまう。手元以外は通信前に断る
void _assertLocal() {
  final host = Uri.parse(_endpoint).host;
  if (host != '127.0.0.1' && host != 'localhost') {
    fail('LIVE_ENDPOINT は手元の wrangler dev（127.0.0.1 / localhost）だけを受ける: $host');
  }
}

/// 一覧の残りを最後まで読む。期待との突き合わせは全組が要るため
Future<List<SimilarGroup>> _allGroups(ApiClient api, String tab) async {
  final out = <SimilarGroup>[];
  String? cursor;
  do {
    final p = await api.similarGroups(_lib, tab, cursor: cursor, limit: 100);
    out.addAll(p.groups);
    cursor = p.cursor;
  } while (cursor != null);
  return out;
}

Future<List<TrashItem>> _allTrash(ApiClient api) async {
  final out = <TrashItem>[];
  String? cursor;
  do {
    final p = await api.trashList(_lib, cursor: cursor);
    out.addAll(p.items);
    cursor = p.cursor;
  } while (cursor != null);
  return out;
}

Future<List<MediaItem>> _allObjects(ApiClient api, String prefix) async {
  final out = <MediaItem>[];
  String? cursor;
  do {
    final p = await api.folder(
      _lib,
      prefix: prefix,
      cursor: cursor,
      recursive: true,
      fresh: true,
    );
    out.addAll(p.items);
    cursor = p.cursor;
  } while (cursor != null);
  return out;
}

/// アルバムの中身を、署名 URL のような毎回変わる物を除いた形で並べる。「元に戻す」が完全な逆かを比べるため
Future<List<String>> _albumShape(ApiClient api, String albumId) async {
  final items = await api.albumAll(_lib, albumId);
  return [
    for (final i in items)
      jsonEncode([i.lib ?? _lib, i.key, i.note, i.createdAt]),
  ];
}

List<String> _albumKeys(List<String> shape) => [
  for (final s in shape) (jsonDecode(s) as List)[1] as String,
];

/// tools/similar-signatures.mjs の outcomeOf と同じ読み替え（差分かもは same の一種として届く）
String _outcome(SimilarMember m) =>
    m.match == 'same' && m.variant ? 'variant' : m.match;

/// tools/similar-signatures.mjs の checkExpected と同じ突き合わせ。外れた物の説明を返す（空なら合格）
List<String> _checkExpected(
  Map<String, dynamic> expected,
  List<SimilarGroup> groups,
  SimilarStatus status,
) {
  final problems = <String>[];
  if (status.pending != 0) {
    problems.add('status.pending が 0 でない (${status.pending})');
  }
  final flatAtLeast = expected['flatAtLeast'];
  if (flatAtLeast is int && status.flat < flatAtLeast) {
    problems.add('status.flat ${status.flat} < $flatAtLeast');
  }
  for (final c in (expected['checks'] as List).cast<Map<String, dynamic>>()) {
    final key = c['key'] as String;
    final within = c['with'] as String?;
    final want = (c['expect'] as List).cast<String>();
    final scope = within == null
        ? groups
        : groups.where((g) => g.members.any((m) => m.key == within));
    final found = <String>{
      for (final g in scope)
        for (final m in g.members)
          if (m.key == key) _outcome(m),
    };
    final got = found.isEmpty ? const {'none'} : found;
    if (!got.any(want.contains)) {
      problems.add(
        '$key${within == null ? '' : ' (with $within)'}: '
        '期待 ${want.join('|')} / 実際 ${got.join('|')} '
        '[thumb=${c['thumb']}]',
      );
    }
  }
  return problems;
}

/// 組の姿（段・オリジナル・各項目の札）。消して戻した後に元と同じ組へ戻ったかを比べるため
Set<String> _groupShape(List<SimilarGroup> dup, List<SimilarGroup> sim) => {
  for (final g in [...dup, ...sim])
    '${g.tier} ${g.id}: ${([for (final m in g.members) '${m.key}=${_outcome(m)}']..sort()).join(', ')}',
};

/// ゴミ箱へ送った後のアルバムの姿を、送る前から組み立てる。消した物の場所にはオリジナルが入り、
/// オリジナルが既にアルバムにある（か、先の場所に入った）時は消した物の場所は詰める
List<String> _albumAfterTrash(
  List<String> before,
  Map<String, String> keeperOf,
) {
  final kept = {
    for (final k in before)
      if (!keeperOf.containsKey(k)) k,
  };
  final out = <String>[];
  for (final k in before) {
    final keeper = keeperOf[k];
    if (keeper == null) {
      out.add(k);
    } else if (!kept.contains(keeper) && !out.contains(keeper)) {
      out.add(keeper);
    }
  }
  return out;
}

/// 原本の取得・縮小・署名の本物の経路。一覧の置き場（thumbCache）はテストでは空なので読まない
ApiSignatureSource _source(ApiClient api) => ApiSignatureSource(
  api: api,
  lib: _lib,
  writable: true,
  isWeb: false,
  readCache: (_) async => null,
);

void main() {
  late ApiClient api;
  late Map<String, dynamic> expected;

  setUpAll(() {
    _assertLocal();
    api = _liveApi();
    final f = File(_expectedPath);
    if (!f.existsSync()) {
      fail(
        '$_expectedPath が無い。test_live/README.md の手順で tools/similar-fixture-seed.mjs を先に流す',
      );
    }
    expected = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    expect(expected['version'], 1);
    expect(expected['lib'], _lib);
  });

  test(
    '書けるライブラリ: 署名を補い、期待どおりの組になり、すべての重複をまとめて消すとアルバムはオリジナルへ置き換わり、元に戻すで完全に戻る',
    () async {
      final albumId = (expected['album'] as Map)['id'] as String?;
      if (albumId == null) fail('expected.json に album.id が無い');
      final root = expected['root'] as String;

      // 前の実行が途中で落ちていると、組もアルバムも種まき直後の形ではなくなる。種まきし直しを求める
      final leftover = await _allTrash(api);
      expect(leftover, isEmpty, reason: 'ゴミ箱に前の実行の残りがある。Worker の保存先を消して種まきし直す');

      // 1. 中身（SHA-256）を数え切る。同じファイルの組はここで決まる
      for (var i = 0; ; i++) {
        final r = await api.duplicateScan(_lib);
        if (r.pending == 0) break;
        expect(r.hashed, greaterThan(0), reason: 'duplicates/scan が進まない');
        expect(i, lessThan(200));
      }

      // 2. 見た目の署名を補う。サムネのある物は保存済みサムネを取って、無い物は原本から
      //    makeImageThumb で 512px JPEG を作って置き直してから、どちらも vs1FromEncoded で数える（Android の経路）
      final before = await api.similarStatus(_lib);
      debugPrint(
        'LIVE status before: images=${before.images} signed=${before.signed} '
        'pending=${before.pending} withThumb=${before.pendingWithThumb} '
        'noThumb=${before.pendingNoThumb}',
      );
      final counts = expected['counts'] as Map<String, dynamic>;
      expect(before.images, counts['images']);
      final sw = Stopwatch()..start();
      final backfill = SignatureBackfill(
        api: api,
        lib: _lib,
        source: _source(api),
        total: before.pending,
      );
      final run = await backfill.run();
      sw.stop();
      final p = run.progress;
      debugPrint(
        'LIVE backfill: end=${run.end} done=${p.done} stored=${p.stored} '
        'failed=${p.failed} errors=${p.errors} stale=${p.stale} '
        'deferred=${p.deferredHere} in ${sw.elapsedMilliseconds} ms',
      );
      expect(run.end, BackfillEnd.completed, reason: '${run.error}');
      expect(p.errors, 0);
      expect(p.deferredHere, 0);
      final status = await api.similarStatus(_lib);
      debugPrint(
        'LIVE status after: signed=${status.signed} failed=${status.failed} '
        'flat=${status.flat} pending=${status.pending}',
      );
      expect(status.pending, 0);

      // サムネの無かった物は、照合のついでにサムネが置かれる（次からはどの端末も同じバイト列を数える）
      final listed = await _allObjects(api, root);
      final noThumb = {
        for (final it
            in (expected['items'] as List).cast<Map<String, dynamic>>())
          if (it['thumb'] == null && !(it['key'] as String).endsWith('.mp4'))
            it['key'] as String,
      };
      final stillMissing = [
        for (final it in listed)
          if (noThumb.contains(it.key) && !it.thumbStored) it.key,
      ];
      expect(noThumb, isNotEmpty);
      expect(stillMissing, isEmpty, reason: 'サムネが置かれていない: $stillMissing');

      // 3. 組が expected.json の期待どおりか
      final dup = await _allGroups(api, similarTabDup);
      final sim = await _allGroups(api, similarTabSimilar);
      debugPrint('LIVE groups: dup=${dup.length} similar=${sim.length}');
      final problems = _checkExpected(expected, [...dup, ...sim], status);
      for (final x in problems) {
        debugPrint('LIVE NG $x');
      }
      expect(problems, isEmpty);

      // 従来の重複（SHA-256）の組は、どれも重複の段に「同じファイル」として入る
      final exactGroups = <DuplicateGroup>[];
      String? dcur;
      do {
        final page = await api.duplicates(_lib, cursor: dcur);
        exactGroups.addAll(page.groups);
        dcur = page.cursor;
      } while (dcur != null);
      expect(exactGroups, isNotEmpty);
      for (final g in exactGroups) {
        final keys = [for (final i in g.items) i.key];
        final host = dup.where(
          (d) => d.members.any((m) => m.key == keys.first),
        );
        expect(host, hasLength(1), reason: '${g.sha256} が重複の段に無い');
        final labels = {for (final m in host.single.members) m.key: m.match};
        for (final k in keys) {
          expect(
            labels[k],
            anyOf('keeper', 'identical'),
            reason: '$k (sha ${g.sha256})',
          );
        }
      }

      // 4. すべての重複 → まとめてゴミ箱へ（画面と同じ controller を通す）
      final albumBefore = await _albumShape(api, albumId);
      final albumKeysBefore = _albumKeys(albumBefore);
      debugPrint('LIVE album before: $albumKeysBefore');
      final shapeBefore = _groupShape(dup, sim);
      final c = SimilarController(
        api: api,
        lib: _lib,
        isWeb: false,
        source: _source(api),
        pageSize: 20,
      );
      addTearDown(c.dispose);
      await c.start();
      expect(c.phase, SimilarPhase.ready, reason: c.error);
      expect(await c.selectAllDup(true), isTrue);
      expect(c.dupCursor, isNull, reason: '全ページを読んでから選ぶ');

      final keeperOf = <String, String>{};
      for (final g in c.dupGroups) {
        for (final m in g.members) {
          if (!c.isSelected(m.key)) continue;
          // 選ばれるのは同じファイルとほぼ同じ（差分かもではない）物だけで、オリジナルは選ばれない
          expect(m.match, anyOf('identical', 'same'), reason: m.key);
          expect(m.variant, isFalse, reason: m.key);
          expect(g.isKeeper(m), isFalse, reason: m.key);
          keeperOf[m.key] = g.keeper;
        }
        for (final m in g.members) {
          if (g.bulkEligible(m)) {
            expect(c.isSelected(m.key), isTrue, reason: '${m.key} が拾われていない');
          }
        }
      }
      for (final g in c.simGroups) {
        for (final m in g.members) {
          expect(c.isSelected(m.key), isFalse, reason: '似ている段の ${m.key} が選ばれた');
        }
      }
      expect(keeperOf, isNotEmpty);
      expect(c.selectedCount, keeperOf.length);
      final selectedBytes = c.selectedBytes;
      debugPrint(
        'LIVE selected ${c.selectedCount} (${c.selectedKinds}) '
        '$selectedBytes bytes / dup reclaimable ${c.dupReclaimable}',
      );

      final result = await c.commit();
      debugPrint(
        'LIVE commit: trashed=${result.trashed} kinds=${result.kinds} '
        'failed=${result.failed} errors=${result.errors}',
      );
      expect(result.failed, 0, reason: '${result.errors}');
      expect(result.unsent, 0);
      expect(result.unrestorable, isEmpty);
      expect(result.receipts.length, keeperOf.length);
      expect(
        (result.kinds.keys.toSet()..removeAll({'identical', 'same'})),
        isEmpty,
        reason: 'Worker が確かめ直した種類: ${result.kinds}',
      );

      // ゴミ箱には選んだ物がちょうど入る
      final trashed = await _allTrash(api);
      expect({for (final t in trashed) t.key}, keeperOf.keys.toSet());
      // アルバムでは、消した物の場所にオリジナルが入る
      final albumAfter = _albumKeys(await _albumShape(api, albumId));
      debugPrint('LIVE album after trash: $albumAfter');
      expect(albumAfter, _albumAfterTrash(albumKeysBefore, keeperOf));
      expect(
        albumKeysBefore.where(keeperOf.containsKey),
        isNotEmpty,
        reason: 'アルバムに消す物が入っていないと、置き換えを確かめられない',
      );
      // 重複の段には、一括で拾う物はもう残らない（反転・差分かもは 1 件ずつ選ぶ物なので残る）
      final dupAfter = await _allGroups(api, similarTabDup);
      for (final g in dupAfter) {
        for (final m in g.members) {
          if (m.isKeeper) continue;
          expect(
            (m.match == 'identical' || m.match == 'same') && !m.variant,
            isFalse,
            reason: '消した後も重複の段に ${m.key}=${m.match}',
          );
        }
      }

      // 5. 直後の「元に戻す」。項目は元のキーへ、アルバムは消す前と同じ並びへ（入れたオリジナルも外れる）
      final undo = await c.undo(result.receipts);
      debugPrint(
        'LIVE undo: restored=${undo.restored}/${undo.total} '
        'failures=${undo.failures}',
      );
      expect(undo.total, keeperOf.length);
      expect(undo.restored, keeperOf.length, reason: '${undo.failures}');
      expect(await _allTrash(api), isEmpty);
      final back = {for (final it in await _allObjects(api, root)) it.key};
      expect(back.containsAll(keeperOf.keys), isTrue);
      expect(back.length, counts['files']);
      expect(await _albumShape(api, albumId), albumBefore);

      // 戻した物の etag が変わった時（大きい物の分割コピー）は署名を作り直す。画面を開き直した時と同じく
      // controller に中身の確認と照合をやり直させ、消す前と同じ組に戻ることを見る
      final again = SimilarController(
        api: api,
        lib: _lib,
        isWeb: false,
        source: _source(api),
      );
      addTearDown(again.dispose);
      await again.start();
      expect(again.phase, SimilarPhase.ready, reason: again.error);
      debugPrint(
        'LIVE re-sign after undo: pending ${again.status?.pending} '
        '-> stored ${again.signProgress?.stored ?? 0}',
      );
      final shapeAfter = _groupShape(
        await _allGroups(api, similarTabDup),
        await _allGroups(api, similarTabSimilar),
      );
      expect(shapeAfter.difference(shapeBefore), isEmpty);
      expect(shapeBefore.difference(shapeAfter), isEmpty);
    },
    timeout: _long,
  );

  test('読み取り専用ライブラリ: 照合の状況は読めるが、まとめてゴミ箱へ・元に戻すは 403', () async {
    final s = await api.similarStatus(_readOnlyLib);
    debugPrint('LIVE b status: images=${s.images} pending=${s.pending}');
    expect(s.alg, similarAlg);

    Future<int?> statusOf(Future<Object?> Function() call) async {
      try {
        await call();
        return null;
      } on ApiError catch (e) {
        return e.status;
      }
    }

    final trash = await statusOf(
      () => api.similarTrash(_readOnlyLib, [
        (key: 'ro/p0.png', keep: 'ro/p1.png'),
      ]),
    );
    final undo = await statusOf(
      () => api.similarUndo(_readOnlyLib, ['.trash/0/ro/p0.png']),
    );
    debugPrint('LIVE b similar/trash -> $trash, similar/undo -> $undo');
    expect(trash, 403);
    expect(undo, 403);

    // 画面と同じ controller も、読み取り専用では何も選ばず何も送らない
    final c = SimilarController(api: api, lib: _readOnlyLib, readOnly: true);
    addTearDown(c.dispose);
    expect(await c.selectAllDup(true), isFalse);
    final r = await c.commit();
    expect(r.trashed, 0);
    expect(r.failed, 0);
  }, timeout: _long);
}
