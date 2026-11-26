import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/duplicates/duplicates_screen.dart';
import 'package:r2_gallery/src/duplicates/signature_source.dart';
import 'package:r2_gallery/src/duplicates/similar_screen.dart';
import 'package:r2_gallery/src/state/app_state.dart';
import 'package:r2_gallery/src/state/trash_ops.dart';
import 'package:r2_gallery/src/ui/viewer_screen.dart';
import 'package:r2_gallery/src/viewer/screen_awake.dart';

const _mb = 1024 * 1024;

// サムネを持たせないのは、テストでネットのサムネを読みに行かせないため
MediaItem _item(String key, {bool video = false}) => MediaItem(
  key: key,
  type: video ? 'video' : 'image',
  url: 'https://w.example/m/lib/$key',
  createdAt: DateTime(2026, 11, 1).millisecondsSinceEpoch,
  size: _mb,
  lib: 'lib',
);

SimilarMember _m(
  String key,
  String match, {
  int size = _mb,
  bool variant = false,
  bool video = false,
}) => SimilarMember(
  item: _item(key, video: video),
  size: size,
  match: match,
  variant: variant,
);

/// Worker と同じ数え方の reclaim（重複の段の、反転でも差分かもでもない物）
SimilarGroup _g(String tier, List<SimilarMember> members) => SimilarGroup(
  id: members.first.key,
  tier: tier,
  members: members,
  reclaim: tier == 'dup'
      ? members
            .where(
              (m) =>
                  (m.match == 'identical' || m.match == 'same') && !m.variant,
            )
            .fold(0, (s, m) => s + m.size)
      : 0,
);

/// 重複 2 組（2 組目は 2 ページ目）と似ている 1 組
final _groupA = _g('dup', [
  _m('a/keep.png', 'keeper', size: 3 * _mb),
  _m('b/copy.png', 'identical'),
  _m('b/resized.jpg', 'same'),
  _m('b/flip.jpg', 'mirror'),
  _m('b/patch.png', 'same', variant: true),
]);
final _groupB = _g('dup', [
  _m('c/keep.jpg', 'keeper'),
  _m('c/copy.jpg', 'identical', size: 2 * _mb),
]);
final _groupS = _g('similar', [
  _m('s/keep.jpg', 'keeper'),
  _m('s/near.jpg', 'similar', size: 2 * _mb),
]);

const _summary = SimilarSummary(
  dup: SimilarTierSummary(groups: 2, items: 7, reclaimable: 4 * _mb),
  similar: SimilarTierSummary(groups: 1, items: 2),
  coverage: SimilarCoverage(
    images: 9,
    signed: 6,
    pending: 1,
    failed: 1,
    flat: 1,
  ),
  hashSkipped: 2,
);

class _Api extends ApiClient {
  _Api();

  SimilarStatus status = const SimilarStatus();
  Object? statusError;
  Object? groupsError;

  /// カーソルはページ番号
  Map<String, List<List<SimilarGroup>>> pages = {
    'dup': [
      [_groupA],
      [_groupB],
    ],
    'similar': [
      [_groupS],
    ],
  };
  SimilarSummary summary = _summary;
  final List<({String tab, String? cursor, int? limit})> groupCalls = [];

  /// 2ページ目以降を止める（「すべての重複」が読み切るまで待つのを見るため）
  Completer<void>? pageGate;

  Map<int, List<SimilarTodoItem>> todo = {};
  final Set<String> posted = {};

  Map<String, SimilarLabel> labels = {};
  final List<({String keep, List<String> keys})> relabelCalls = [];

  final List<List<({String key, String keep})>> trashCalls = [];
  Completer<void>? trashGate;
  Map<String, String> trashErrors = {};
  final List<List<String>> undoCalls = [];

  /// 中身の計算の残り（呼ぶたびに先頭から使う）。空なら 0
  final List<int> scanPending = [];

  /// 2 回目以降の計算を止める（途中の残りの表示を見るため）
  Completer<void>? scanGate;
  int scans = 0;

  @override
  Future<DuplicateScan> duplicateScan(String libId) async {
    scans++;
    if (scans >= 2) await scanGate?.future;
    final p = scanPending.isEmpty ? 0 : scanPending.removeAt(0);
    return DuplicateScan(pending: p, hashed: p > 0 ? 1 : 0, skipped: 0);
  }

  @override
  Future<DuplicatePage> duplicates(
    String libId, {
    String? cursor,
    int limit = 50,
  }) async => const DuplicatePage(groups: []);

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
    final gate = pageGate;
    if (gate != null && cursor != null) await gate.future;
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
    return {for (final k in keys) k: labels[k] ?? const SimilarLabel()};
  }

  @override
  Future<List<SimilarTrashItemResult>> similarTrash(
    String libId,
    List<({String key, String keep})> items,
  ) async {
    trashCalls.add(items);
    await trashGate?.future;
    return [
      for (final i in items)
        trashErrors.containsKey(i.key)
            ? SimilarTrashItemResult(
                key: i.key,
                ok: false,
                error: trashErrors[i.key],
              )
            : SimilarTrashItemResult(
                key: i.key,
                ok: true,
                trashKey: '.trash/1/${i.key}',
                kind: 'identical',
              ),
    ];
  }

  @override
  Future<List<SimilarUndoItemResult>> similarUndo(
    String libId,
    List<String> trashKeys,
  ) async {
    undoCalls.add(trashKeys);
    return [
      for (final tk in trashKeys)
        SimilarUndoItemResult(trashKey: tk, ok: true, key: tk),
    ];
  }
}

class _Source implements SignatureSource {
  Completer<void>? gate;
  int calls = 0;

  @override
  Future<SignatureOutcome> sign(SimilarTodoItem item) async {
    calls++;
    await gate?.future;
    return SignatureOutcome.signed(item, 't', Uint8List(297));
  }
}

class _Driver implements ScreenAwakeDriver {
  int acquires = 0;
  int releases = 0;
  @override
  bool get visible => true;
  @override
  Stream<ScreenAwakeEvent> get events => const Stream.empty();
  @override
  Future<ScreenAwakeStatus> acquire() async {
    acquires++;
    return ScreenAwakeStatus.held;
  }

  @override
  Future<void> release() async => releases++;
  @override
  void dispose() {}
}

class _NoCache extends Fake implements BaseCacheManager {
  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) => Stream.error(Exception('no network in tests'));
}

SimilarTodoItem _todo(String key) =>
    SimilarTodoItem(item: _item(key), etag: 'e-$key', size: 1000, ext: 'jpg');

AppState _app(ApiClient api, {bool readOnly = false}) =>
    AppState(api: api, bakedEndpoint: '', bakedToken: '')
      ..connected = true
      ..libraries = [Library(id: 'lib', title: 'L', readOnly: readOnly)]
      ..activeLib = 'lib';

/// 読み込み中の輪は回り続けて pumpAndSettle が終わらないので、決まった回数だけ進める
Future<void> _pumps(WidgetTester tester, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Future<void> _show(
  WidgetTester tester,
  AppState app, {
  _Source? source,
  bool isWeb = false,
  ScreenAwakeCoordinator? awake,
}) async {
  // 組を縦に並べても全部が画面に収まる高さにする
  tester.view.physicalSize = const Size(1000, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: SimilarScreen(
        app: app,
        lib: 'lib',
        clock: () => DateTime(2026, 11, 15),
        source: source ?? _Source(),
        isWeb: isWeb,
        screenAwake: awake,
        imageCacheManager: _NoCache(),
      ),
    ),
  );
  await _pumps(tester);
}

/// 2ページ目まで1ページに収めた一覧（続きの読み込みの輪を出さない）
Map<String, List<List<SimilarGroup>>> _onePage() => {
  'dup': [
    [_groupA, _groupB],
  ],
  'similar': [
    [_groupS],
  ],
};

Future<void> _leave(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 7));
}

void main() {
  testWidgets('オリジナルに札が付き、ほかの物は札と丸いチェックで選べる', (tester) async {
    final api = _Api()..pages = _onePage();
    await _show(tester, _app(api));
    expect(find.text('重複・似ている写真'), findsOneWidget);
    expect(find.text('重複 (2組)'), findsOneWidget);
    expect(find.text('似ている (1組)'), findsOneWidget);
    expect(find.text('2組 · 4.0 MB 空けられます'), findsOneWidget);
    expect(find.text('オリジナル'), findsNWidgets(2));
    expect(find.text('同じファイル'), findsNWidgets(2));
    expect(find.text('ほぼ同じ'), findsOneWidget);
    expect(find.text('反転'), findsOneWidget);
    expect(find.text('差分かも'), findsOneWidget);
    // オリジナルにはチェックが無い
    expect(find.byKey(const ValueKey('select:a/keep.png')), findsNothing);
    expect(find.byKey(const ValueKey('select:b/copy.png')), findsOneWidget);
    // 見つからなかった理由の内訳
    expect(find.text('照合が済んでいない物: 1 件'), findsOneWidget);
    expect(find.text('確認できなかった物: 1 件'), findsOneWidget);
    expect(find.text('単色に近く比べなかった物: 1 件'), findsOneWidget);
    expect(find.text('大きすぎて中身を確認できなかった物: 2 件'), findsOneWidget);
    // 選ぶまでは押せない
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
    expect(find.text('ゴミ箱に移動（0件 · 0 B）'), findsOneWidget);
    // 1件ずつなら反転も選べる
    await tester.tap(find.byKey(const ValueKey('select:b/flip.jpg')));
    await tester.pump();
    expect(find.text('ゴミ箱に移動（1件 · 1.0 MB）'), findsOneWidget);
    await _leave(tester);
  });

  testWidgets('「すべての重複」は残りのページを読み切ってから、同じ・ほぼ同じだけを選ぶ', (tester) async {
    final gate = Completer<void>();
    final api = _Api()..pageGate = gate;
    await _show(tester, _app(api));
    await tester.tap(find.text('すべての重複'));
    await _pumps(tester, 3);
    expect(find.text('全件を読み込んでいます…'), findsOneWidget);
    // 読み切るまでは何も選ばない
    expect(find.text('ゴミ箱に移動（0件 · 0 B）'), findsOneWidget);
    gate.complete();
    await _pumps(tester);
    expect(
      api.groupCalls.where((c) => c.tab == 'dup' && c.cursor == '1'),
      isNotEmpty,
    );
    // copy・resized（各 1 MB）と 2ページ目の copy（2 MB）。反転・差分かも・オリジナルは選ばない
    expect(find.text('ゴミ箱に移動（3件 · 4.0 MB）'), findsOneWidget);
    final flip = tester.widget<Checkbox>(
      find.byKey(const ValueKey('select:b/flip.jpg')),
    );
    expect(flip.value, isFalse);
    final patch = tester.widget<Checkbox>(
      find.byKey(const ValueKey('select:b/patch.png')),
    );
    expect(patch.value, isFalse);
    // 似ているタブには触らない
    await tester.tap(find.text('似ている (1組)'));
    await _pumps(tester, 30);
    final near = tester.widget<Checkbox>(
      find.byKey(const ValueKey('select:s/near.jpg')),
    );
    expect(near.value, isFalse);
    expect(find.text('すべての重複'), findsNothing);
    // もう一度押すと外れる
    await tester.tap(find.text('重複 (2組)'));
    await _pumps(tester, 30);
    await tester.tap(find.text('すべての重複'));
    await _pumps(tester);
    expect(find.text('ゴミ箱に移動（0件 · 0 B）'), findsOneWidget);
    await _leave(tester);
  });

  testWidgets('「すべての重複」が残りを読んでいる間は、選んだ物があっても下のボタンを押せない', (tester) async {
    final gate = Completer<void>();
    final api = _Api()..pageGate = gate;
    await _show(tester, _app(api));
    await tester.tap(find.byKey(const ValueKey('select:b/flip.jpg')));
    await tester.pump();
    expect(find.text('ゴミ箱に移動（1件 · 1.0 MB）'), findsOneWidget);
    await tester.tap(find.text('すべての重複'));
    await _pumps(tester, 3);
    expect(find.text('全件を読み込んでいます…'), findsOneWidget);
    // 押せると、確かめの画面を出している間に読み終えて、確かめた件数より多く送ってしまう
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    gate.complete();
    await _pumps(tester);
    expect(find.text('ゴミ箱に移動（4件 · 5.0 MB）'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
    expect(api.trashCalls, isEmpty);
    await _leave(tester);
  });

  testWidgets('確かめの文に種類ごとの件数と30日のゴミ箱を出し、送る間は進み具合、後で元に戻せる', (tester) async {
    final api = _Api()
      ..pages = _onePage()
      ..trashGate = Completer<void>();
    final app = _app(api);
    final changed = <String>[];
    final sub = app.contentChanged.listen(changed.add);
    addTearDown(sub.cancel);
    await _show(tester, app);
    await tester.tap(find.text('すべての重複'));
    await _pumps(tester);
    await tester.tap(find.text('ゴミ箱に移動（3件 · 4.0 MB）'));
    await _pumps(tester);
    expect(find.text('3件をゴミ箱に移動しますか？'), findsOneWidget);
    expect(
      find.text(
        '完全に同じ 2件・ほぼ同じ 1件。オリジナルは残します。'
        'アルバムに入っていた物はオリジナルに置き換えます。ゴミ箱から30日間は元に戻せます。',
      ),
      findsOneWidget,
    );
    expect(find.text('『似ている』『差分かも』は別の絵のこともあります。'), findsNothing);
    await tester.tap(find.text('ゴミ箱に移動'));
    await _pumps(tester, 4);
    expect(find.text('ゴミ箱へ移動中 0 / 3'), findsOneWidget);
    expect(find.text('中止'), findsOneWidget);
    // 組ごとに残す物を添えて送る
    expect(api.trashCalls.single, [
      (key: 'b/copy.png', keep: 'a/keep.png'),
      (key: 'b/resized.jpg', keep: 'a/keep.png'),
      (key: 'c/copy.jpg', keep: 'c/keep.jpg'),
    ]);
    api.trashGate!.complete();
    await _pumps(tester);
    expect(find.textContaining('ゴミ箱へ移動中'), findsNothing);
    expect(find.text('3件をゴミ箱に移しました'), findsOneWidget);
    expect(changed, ['lib']);
    // オリジナルだけ残った組は畳まれる
    expect(find.text('copy.jpg'), findsNothing);
    expect(find.text('重複 (1組)'), findsOneWidget);
    await tester.tap(find.text('元に戻す'));
    // スナックバーが閉じ終わってから戻し始める
    await _pumps(tester, 40);
    expect(api.undoCalls.single, [
      '.trash/1/b/copy.png',
      '.trash/1/b/resized.jpg',
      '.trash/1/c/copy.jpg',
    ]);
    expect(changed, ['lib', 'lib']);
    await _leave(tester);
  });

  testWidgets('似ている物や差分かもを選ぶと、別の絵のことがあると添える', (tester) async {
    final api = _Api()..pages = _onePage();
    await _show(tester, _app(api));
    await tester.tap(find.byKey(const ValueKey('select:b/patch.png')));
    await tester.pump();
    await tester.tap(find.text('似ている (1組)'));
    await _pumps(tester, 30);
    expect(find.text('見た目が近いだけで別の絵のこともあります。確かめてから選んでください'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('group:similar:s/keep.jpg')));
    await tester.pump();
    await tester.tap(find.text('ゴミ箱に移動（2件 · 3.0 MB）'));
    await _pumps(tester);
    expect(find.textContaining('ほぼ同じ 1件（うち差分かも 1件）・似ている 1件。'), findsOneWidget);
    expect(find.text('『似ている』『差分かも』は別の絵のこともあります。'), findsOneWidget);
    await tester.tap(find.text('キャンセル'));
    await _pumps(tester);
    expect(api.trashCalls, isEmpty);
    await _leave(tester);
  });

  testWidgets('移せなかった物は元に戻して件数を知らせる', (tester) async {
    final api = _Api()
      ..pages = _onePage()
      ..trashErrors = {'b/copy.png': 'move_failed'};
    await _show(tester, _app(api));
    await tester.tap(find.byKey(const ValueKey('select:b/copy.png')));
    await tester.tap(find.byKey(const ValueKey('select:b/resized.jpg')));
    await tester.pump();
    await tester.tap(find.text('ゴミ箱に移動（2件 · 2.0 MB）'));
    await _pumps(tester);
    await tester.tap(find.text('ゴミ箱に移動'));
    await _pumps(tester);
    expect(find.text('1件をゴミ箱に移しました'), findsOneWidget);
    expect(find.text('copy.png'), findsOneWidget);
    expect(find.text('resized.jpg'), findsNothing);
    // 「元に戻す」が閉じてから失敗の知らせが出る
    // 出てくる動きが終わってから6秒の期限が数え始まる
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 7));
    await _pumps(tester, 40);
    expect(find.text('1件を移せませんでした'), findsOneWidget);
    await _leave(tester);
  });

  testWidgets('読み取り専用のライブラリでは組だけ見せ、選ぶ物も消すボタンも出さない', (tester) async {
    final api = _Api()..pages = _onePage();
    await _show(tester, _app(api, readOnly: true));
    expect(find.text('オリジナル'), findsNWidgets(2));
    expect(find.byType(Checkbox), findsNothing);
    expect(find.byType(CheckboxListTile), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.text('このライブラリは読み取り専用です'), findsOneWidget);
    // 長押ししても開くだけ
    await tester.longPress(find.text('copy.png'));
    await _pumps(tester);
    expect(find.text('開く'), findsOneWidget);
    expect(find.text('オリジナルにする'), findsNothing);
    expect(find.text('この1件だけゴミ箱へ'), findsNothing);
    await _leave(tester);
  });

  testWidgets('照合が 300 件を超えると通信量を見せて同意を待ち、あとでなら今の結果を見せる', (tester) async {
    final source = _Source();
    final api = _Api()
      ..pages = _onePage()
      ..status = const SimilarStatus(
        pending: 301,
        pendingWithThumb: 301,
        pendingBytesEstimate: 301 * 40960,
      );
    await _show(tester, _app(api), source: source);
    expect(find.text('見た目の照合が済んでいない写真 301 枚（通信 約 11.7 MB）'), findsOneWidget);
    expect(find.text('この端末で照合する'), findsOneWidget);
    expect(
      find.textContaining('PC の tools/similar-signatures.mjs でも進められます'),
      findsOneWidget,
    );
    expect(find.textContaining('Web では時間がかかります'), findsNothing);
    await tester.tap(find.text('あとで（今の結果を見る）'));
    await _pumps(tester);
    expect(source.calls, 0);
    expect(find.text('2組 · 4.0 MB 空けられます'), findsOneWidget);
    await _leave(tester);
  });

  testWidgets('Web の同意の画面では Android か PC をすすめる', (tester) async {
    final api = _Api()
      ..pages = _onePage()
      ..status = const SimilarStatus(pending: 400, pendingWithThumb: 350);
    await _show(tester, _app(api), isWeb: true);
    expect(find.text('見た目の照合が済んでいない写真 350 枚（通信 約 13.6 MB）'), findsOneWidget);
    expect(
      find.textContaining('Web では時間がかかります。Android か PC がおすすめです'),
      findsOneWidget,
    );
    await _leave(tester);
  });

  testWidgets('300 件以下ならすぐ照合し、照合の間は画面を消さず、途中の結果も見られる', (tester) async {
    final driver = _Driver();
    final awake = ScreenAwakeCoordinator(driver);
    addTearDown(awake.dispose);
    final source = _Source()..gate = Completer<void>();
    final api = _Api()
      ..pages = _onePage()
      ..status = const SimilarStatus(pending: 2, pendingWithThumb: 2)
      ..todo = {
        0: [_todo('x1.jpg'), _todo('x2.jpg')],
      };
    await _show(tester, _app(api), source: source, awake: awake);
    expect(find.text('見た目を照合中 0 / 2'), findsOneWidget);
    expect(find.text('画面を離れると止まり、次は続きから'), findsOneWidget);
    expect(find.text('途中の結果を見る'), findsOneWidget);
    expect(driver.acquires, 1);
    source.gate!.complete();
    await _pumps(tester, 20);
    expect(api.posted, {'x1.jpg', 'x2.jpg'});
    expect(find.text('2組 · 4.0 MB 空けられます'), findsOneWidget);
    // 照合が終われば保持を解く
    expect(driver.releases, 1);
    await _leave(tester);
  });

  testWidgets('何も無ければそう言い、内訳も添える', (tester) async {
    final api = _Api()
      ..pages = {
        'dup': [const []],
        'similar': [const []],
      }
      ..summary = const SimilarSummary(
        coverage: SimilarCoverage(images: 3, signed: 2, flat: 1),
      );
    await _show(tester, _app(api));
    expect(find.text('重複も似ている写真も見つかりませんでした'), findsOneWidget);
    expect(find.text('単色に近く比べなかった物: 1 件'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    await _leave(tester);
  });

  testWidgets('読めなかったら再試行で読み直せる', (tester) async {
    final api = _Api()
      ..pages = _onePage()
      ..groupsError = const ApiError(500, 'boom');
    await _show(tester, _app(api));
    expect(find.text('重複・似ている写真の一覧を読めませんでした'), findsOneWidget);
    api.groupsError = null;
    await tester.tap(find.text('再試行'));
    await _pumps(tester);
    expect(find.text('2組 · 4.0 MB 空けられます'), findsOneWidget);
    await _leave(tester);
  });

  testWidgets('長押しからこの1件だけゴミ箱へ送れる', (tester) async {
    final api = _Api()..pages = _onePage();
    await _show(tester, _app(api));
    await tester.longPress(find.text('flip.jpg'));
    await _pumps(tester);
    expect(find.text('オリジナルにする'), findsOneWidget);
    await tester.tap(find.text('この1件だけゴミ箱へ'));
    await _pumps(tester);
    expect(api.trashCalls.single, [(key: 'b/flip.jpg', keep: 'a/keep.png')]);
    expect(find.text('1件をゴミ箱に移しました'), findsOneWidget);
    expect(find.text('flip.jpg'), findsNothing);
    await _leave(tester);
  });

  testWidgets('戻せずゴミ箱に残っただけの時も、ギャラリーに読み直させる', (tester) async {
    final api = _Api()
      ..pages = _onePage()
      ..trashErrors = {'b/flip.jpg': 'put_back_failed'};
    final app = _app(api);
    final changed = <String>[];
    final sub = app.contentChanged.listen(changed.add);
    addTearDown(sub.cancel);
    await _show(tester, app);
    await tester.longPress(find.text('flip.jpg'));
    await _pumps(tester);
    await tester.tap(find.text('この1件だけゴミ箱へ'));
    await _pumps(tester, 30);
    expect(find.text('1件は元の場所へ戻せず、ゴミ箱に残りました。ゴミ箱から戻せます'), findsOneWidget);
    // 移した物は無いので「元に戻す」は出さないが、元の場所からは無くなっている
    expect(find.text('元に戻す'), findsNothing);
    expect(changed, ['lib']);
    await _leave(tester);
  });

  testWidgets('長押しからオリジナルを選び直すと、札を付け直して別物は選べなくする', (tester) async {
    final api = _Api()
      ..pages = _onePage()
      ..labels = {
        'a/keep.png': const SimilarLabel(match: 'same', ph: 1, dh: 2),
        'b/copy.png': const SimilarLabel(match: 'same', ph: 1, dh: 2),
        // 反転と差分かもは新しいオリジナルとは別物と分かった
      };
    await _show(tester, _app(api));
    await tester.longPress(find.text('resized.jpg'));
    await _pumps(tester);
    await tester.tap(find.text('オリジナルにする'));
    await _pumps(tester);
    expect(api.relabelCalls.single.keep, 'b/resized.jpg');
    // 前のオリジナルは選べる物になり、新しいオリジナルにはチェックが無い
    expect(find.byKey(const ValueKey('select:a/keep.png')), findsOneWidget);
    expect(find.byKey(const ValueKey('select:b/resized.jpg')), findsNothing);
    expect(find.byKey(const ValueKey('select:b/flip.jpg')), findsNothing);
    expect(find.text('オリジナルと別物'), findsNWidgets(2));
    await _leave(tester);
  });

  testWidgets('オリジナルを選び直した後、前のオリジナルを消すと新しいオリジナルを残す物として送る', (tester) async {
    final api = _Api()
      ..pages = _onePage()
      ..labels = {
        'a/keep.png': const SimilarLabel(match: 'same', ph: 1, dh: 2),
        'b/copy.png': const SimilarLabel(match: 'same', ph: 1, dh: 2),
      };
    await _show(tester, _app(api));
    await tester.longPress(find.text('resized.jpg'));
    await _pumps(tester);
    await tester.tap(find.text('オリジナルにする'));
    await _pumps(tester);
    await tester.longPress(find.text('keep.png'));
    await _pumps(tester);
    await tester.tap(find.text('この1件だけゴミ箱へ'));
    await _pumps(tester);
    expect(api.trashCalls.single, [(key: 'a/keep.png', keep: 'b/resized.jpg')]);
    expect(find.text('keep.png'), findsNothing);
    await _leave(tester);
  });

  testWidgets('タップでビューアを開く', (tester) async {
    final api = _Api()..pages = _onePage();
    await _show(tester, _app(api));
    await tester.tap(find.text('resized.jpg'));
    await _pumps(tester, 30);
    expect(find.byType(ViewerScreen), findsOneWidget);
    await _leave(tester);
  });

  testWidgets('見た目の照合が無い古い Worker（404）では従来の重複の画面を出す', (tester) async {
    final api = _Api()
      ..statusError = const ApiError(404, 'x', code: 'not_found');
    await _show(tester, _app(api));
    expect(find.byType(DuplicatesScreen), findsOneWidget);
    expect(find.text('重複した写真・動画'), findsOneWidget);
    await _leave(tester);
  });

  testWidgets('見た目の照合を断る大きなライブラリ（413）では従来の重複の画面を出す', (tester) async {
    final api = _Api()
      ..groupsError = const ApiError(
        413,
        'too many',
        code: 'too_many_for_similar',
      );
    await _show(tester, _app(api));
    expect(find.byType(DuplicatesScreen), findsOneWidget);
    await _leave(tester);
  });

  testWidgets('一覧の口だけが落ちた時は、再試行と並べて同じファイルだけの従来の画面へ移れる', (tester) async {
    final api = _Api()..groupsError = const ApiError(503, 'cpu limit');
    await _show(tester, _app(api));
    expect(find.text('重複・似ている写真の一覧を読めませんでした'), findsOneWidget);
    expect(find.text('再試行'), findsOneWidget);
    await tester.tap(find.text('同じファイルだけを探す'));
    await _pumps(tester);
    expect(find.byType(DuplicatesScreen), findsOneWidget);
    await _leave(tester);
  });

  testWidgets('中身の計算の途中は残りの件数を出す', (tester) async {
    final gate = Completer<void>();
    final api = _Api()
      ..pages = _onePage()
      ..scanPending.addAll([5, 0])
      ..scanGate = gate;
    await _show(tester, _app(api));
    expect(api.scans, 2);
    expect(find.text('中身を確認中… あと 5 件'), findsOneWidget);
    gate.complete();
    await _pumps(tester);
    expect(find.text('2組 · 4.0 MB 空けられます'), findsOneWidget);
    await _leave(tester);
  });

  testWidgets('まだ中身を確認できていない物があれば、その件数を重複の段の頭に出す', (tester) async {
    final api = _Api()
      ..pages = _onePage()
      ..summary = const SimilarSummary(
        dup: SimilarTierSummary(groups: 2, items: 7, reclaimable: 4 * _mb),
        similar: SimilarTierSummary(groups: 1, items: 2),
        hashPending: 3,
      );
    await _show(tester, _app(api));
    expect(find.text('まだ中身を確認できていない物: 3 件'), findsOneWidget);
    await _leave(tester);
  });

  testWidgets('末尾まで来たら続きのページを読む', (tester) async {
    final api = _Api();
    await _show(tester, _app(api));
    expect(
      api.groupCalls.where((c) => c.tab == 'dup' && c.cursor == '1'),
      hasLength(1),
    );
    expect(find.text('copy.jpg'), findsOneWidget);
    await _leave(tester);
  });

  testWidgets('ビューアでゴミ箱へ送って閉じると一覧を読み直す', (tester) async {
    final api = _Api()..pages = _onePage();
    await _show(tester, _app(api));
    final firstPages = api.groupCalls.where((c) => c.cursor == null).length;
    await tester.tap(find.text('resized.jpg'));
    await _pumps(tester, 30);
    expect(find.byType(ViewerScreen), findsOneWidget);
    // ビューアのゴミ箱は閉じる時に受け取りを返す。一覧はそれを受けて読み直す
    Navigator.of(tester.element(find.byType(ViewerScreen))).pop(
      const TrashReceipt('lib', '.trash/1/b/resized.jpg', key: 'b/resized.jpg'),
    );
    await _pumps(tester, 30);
    expect(
      api.groupCalls.where((c) => c.cursor == null).length,
      firstPages + 2,
    );
    await _leave(tester);
  });

  group('電話の幅（375 x 812）', () {
    Future<void> showPhone(WidgetTester tester, AppState app) async {
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: SimilarScreen(
            app: app,
            lib: 'lib',
            clock: () => DateTime(2026, 11, 15),
            source: _Source(),
            isWeb: false,
            imageCacheManager: _NoCache(),
          ),
        ),
      );
      await _pumps(tester);
    }

    /// 札が丸いチェックと重ならず、札の文字がタイルの中に収まる
    void expectBadgesFit(WidgetTester tester, List<String> keys) {
      for (final k in keys) {
        final badge = find.byKey(ValueKey('badge:$k'));
        expect(badge, findsOneWidget, reason: k);
        final tile = tester.getRect(
          find.ancestor(of: badge, matching: find.byType(AspectRatio)).first,
        );
        final b = tester.getRect(badge);
        final text = tester.getRect(
          find.descendant(of: badge, matching: find.byType(Text)),
        );
        expect(
          tile.contains(b.topLeft) && tile.contains(b.bottomRight),
          isTrue,
          reason: '$k badge $b tile $tile',
        );
        expect(
          text.left >= tile.left && text.right <= tile.right,
          isTrue,
          reason: '$k text $text tile $tile',
        );
        final check = find.byKey(ValueKey('select:$k'));
        if (check.evaluate().isNotEmpty) {
          final c = tester.getRect(check);
          expect(b.overlaps(c), isFalse, reason: '$k badge $b check $c');
          expect(c.width, lessThanOrEqualTo(32), reason: k);
        }
      }
    }

    const keys = [
      'a/keep.png',
      'b/copy.png',
      'b/resized.jpg',
      'b/flip.jpg',
      'b/patch.png',
    ];

    testWidgets('札は丸いチェックと重ならず、タイルからはみ出さない', (tester) async {
      final api = _Api()..pages = _onePage();
      await showPhone(tester, _app(api));
      expect(tester.takeException(), isNull);
      expectBadgesFit(tester, keys);
      await _leave(tester);
    });

    testWidgets('文字を 1.3 倍にしても札は丸いチェックと重ならない', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final api = _Api()..pages = _onePage();
      await showPhone(tester, _app(api));
      expectBadgesFit(tester, keys);
      await _leave(tester);
    });

    testWidgets('「オリジナルと別物」の札もタイルの中に全部収まる', (tester) async {
      final api = _Api()
        ..pages = _onePage()
        ..labels = {
          'a/keep.png': const SimilarLabel(match: 'same', ph: 1, dh: 2),
          'b/copy.png': const SimilarLabel(match: 'same', ph: 1, dh: 2),
        };
      await showPhone(tester, _app(api));
      await tester.longPress(find.text('resized.jpg'));
      await _pumps(tester);
      await tester.tap(find.text('オリジナルにする'));
      await _pumps(tester);
      expect(find.text('オリジナルと別物'), findsNWidgets(2));
      expectBadgesFit(tester, keys);
      await _leave(tester);
    });

    // 札は残す物と消す物の一番の目印。縮めて読めなくしない（360 px の電話で 1 枚 98 px ほど）
    for (final scale in [1.0, 1.3, 2.0]) {
      testWidgets('360 px の幅で文字 $scale 倍でも、動画の札も 10 px 以上の文字で、印と重ならない', (
        tester,
      ) async {
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final members = [
          _m('v/keep.mp4', 'keeper', video: true),
          _m('v/copy.mp4', 'identical', video: true),
          _m('v/none.mp4', 'none', video: true),
          _m('v/patch.mp4', 'same', variant: true, video: true),
          _m('v/none.jpg', 'none'),
          _m('v/copy.jpg', 'identical'),
        ];
        final api = _Api()
          ..pages = {
            'dup': [
              [_g('dup', members)],
            ],
            'similar': [const []],
          };
        tester.view.physicalSize = const Size(360, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            home: SimilarScreen(
              app: _app(api),
              lib: 'lib',
              clock: () => DateTime(2026, 11, 15),
              source: _Source(),
              isWeb: false,
              imageCacheManager: _NoCache(),
            ),
          ),
        );
        await _pumps(tester);
        expect(tester.takeException(), isNull);
        final keys = [for (final m in members) m.key];
        expectBadgesFit(tester, keys);
        for (final k in keys) {
          final badge = find.byKey(ValueKey('badge:$k'));
          final textFinder = find.descendant(
            of: badge,
            matching: find.byType(Text),
          );
          final box = tester.renderObject<RenderBox>(textFinder);
          // 縮めた後に描かれる幅と、縮める前の幅の比
          final drawn =
              box.localToGlobal(Offset(box.size.width, 0)).dx -
              box.localToGlobal(Offset.zero).dx;
          final shrink = drawn / box.size.width;
          final font = tester.widget<Text>(textFinder).style!.fontSize!;
          expect(
            font * scale * shrink,
            greaterThanOrEqualTo(10),
            reason: '$k shrink $shrink',
          );
          final tile = find.ancestor(
            of: badge,
            matching: find.byType(AspectRatio),
          );
          final play = find.descendant(
            of: tile.first,
            matching: find.byIcon(Icons.play_arrow),
          );
          if (play.evaluate().isNotEmpty) {
            final p = tester.getRect(play);
            expect(tester.getRect(badge).overlaps(p), isFalse, reason: k);
            final check = find.byKey(ValueKey('select:$k'));
            if (check.evaluate().isNotEmpty) {
              expect(p.overlaps(tester.getRect(check)), isFalse, reason: k);
            }
          }
        }
        await _leave(tester);
      });
    }
  });

  testWidgets('「すべての重複」で選べる物が1件も無ければ押せない', (tester) async {
    final api = _Api()
      ..pages = {
        'dup': [
          [
            _g('dup', [
              _m('a/keep.png', 'keeper'),
              _m('b/flip.jpg', 'mirror'),
              _m('b/patch.png', 'same', variant: true),
            ]),
          ],
        ],
        'similar': [const []],
      };
    await _show(tester, _app(api));
    final tile = tester.widget<CheckboxListTile>(find.byType(CheckboxListTile));
    expect(tile.onChanged, isNull);
    expect(tile.value, isFalse);
    // 1件ずつ選んだ反転は「すべての重複」の一部に数えない
    await tester.tap(find.byKey(const ValueKey('select:b/flip.jpg')));
    await tester.pump();
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      isFalse,
    );
    expect(find.text('ゴミ箱に移動（1件 · 1.0 MB）'), findsOneWidget);
    await _leave(tester);
  });

  group('まとめて送っている間に戻る', () {
    Future<_Api> start(WidgetTester tester) async {
      final api = _Api()
        ..pages = _onePage()
        // 1 件ずつ送らせ、2 本が止まっている間に 3 本目が残るようにする
        ..status = const SimilarStatus(trashBatch: 1)
        ..trashGate = Completer<void>();
      tester.view.physicalSize = const Size(1000, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final app = _app(api);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => SimilarScreen(
                        app: app,
                        lib: 'lib',
                        clock: () => DateTime(2026, 11, 15),
                        source: _Source(),
                        isWeb: false,
                        imageCacheManager: _NoCache(),
                      ),
                    ),
                  ),
                  child: const Text('開く'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('開く'));
      await _pumps(tester, 30);
      await tester.tap(find.text('すべての重複'));
      await _pumps(tester);
      await tester.tap(find.text('ゴミ箱に移動（3件 · 4.0 MB）'));
      await _pumps(tester);
      await tester.tap(find.text('ゴミ箱に移動'));
      await _pumps(tester, 4);
      expect(find.text('ゴミ箱へ移動中 0 / 3'), findsOneWidget);
      expect(api.trashCalls, hasLength(2));
      return api;
    }

    testWidgets('戻る前に確かめ、「続ける」なら画面に留まって全部送る', (tester) async {
      final api = await start(tester);
      await tester.tap(find.byType(BackButton));
      await _pumps(tester);
      expect(find.text('移動を中止して戻りますか？'), findsOneWidget);
      expect(find.byType(SimilarScreen), findsOneWidget);
      await tester.tap(find.text('続ける'));
      await _pumps(tester);
      expect(find.byType(SimilarScreen), findsOneWidget);
      api.trashGate!.complete();
      await _pumps(tester);
      expect(api.trashCalls, hasLength(3));
      expect(find.text('3件をゴミ箱に移しました'), findsOneWidget);
      await _leave(tester);
    });

    testWidgets('「中止して戻る」なら残りを送らずに戻る', (tester) async {
      final api = await start(tester);
      await tester.tap(find.byType(BackButton));
      await _pumps(tester);
      await tester.tap(find.text('中止して戻る'));
      await _pumps(tester, 30);
      expect(find.byType(SimilarScreen), findsNothing);
      api.trashGate!.complete();
      await _pumps(tester, 30);
      expect(api.trashCalls, hasLength(2));
      await _leave(tester);
    });
  });

  test('桁区切り', () {
    expect(formatCount(0), '0');
    expect(formatCount(999), '999');
    expect(formatCount(3210), '3,210');
    expect(formatCount(1234567), '1,234,567');
  });
}
