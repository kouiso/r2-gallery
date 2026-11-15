import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/albums/album_states.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/grid/media_controller.dart';
import 'package:r2_gallery/src/state/app_state.dart';
import 'package:r2_gallery/src/state/trash_state.dart';

MediaItem _it(String key, {String v = '1'}) => MediaItem(
    key: key, type: 'image', url: 'https://w.example/m/$key?v=$v');

List<String> _keys(List<MediaItem> l) => [for (final i in l) i.key];

/// 書き込み系の返事を手で返せる Worker。返すまでは「送っている途中」のまま。
class _Api extends ApiClient {
  FolderPage Function(String? cursor)? pages;
  final Map<String, Completer<String>> trashGates = {};
  final Map<String, Completer<String>> restoreGates = {};
  final List<String> trashCalls = [];
  final List<String> restoreCalls = [];
  Completer<String>? createGate;
  Completer<void>? writeGate;
  final List<String> writes = [];
  List<MediaItem> albumItems = [];
  Completer<TrashPage>? trashListGate;

  @override
  Future<TrashPage> trashList(String libId, {String? cursor}) =>
      (trashListGate = Completer<TrashPage>()).future;

  @override
  Future<FolderPage> folder(String libId,
          {String prefix = '',
          String? cursor,
          bool recursive = false,
          String? sort,
          bool fresh = false}) async =>
      pages!(cursor);

  @override
  Future<String> trash(String libId, String key) {
    trashCalls.add(key);
    return (trashGates[key] ??= Completer<String>()).future;
  }

  @override
  Future<String> restore(String libId, String trashKey) {
    restoreCalls.add(trashKey);
    return (restoreGates[trashKey] ??= Completer<String>()).future;
  }

  @override
  Future<String> albumCreate(String lib, String title) {
    writes.add('create $title');
    return (createGate = Completer<String>()).future;
  }

  Future<void> _write(String what) {
    writes.add(what);
    return (writeGate = Completer<void>()).future;
  }

  @override
  Future<void> albumRename(String lib, String albumId, String title) =>
      _write('rename $albumId $title');

  @override
  Future<void> albumDelete(String lib, String albumId) =>
      _write('delete $albumId');

  @override
  Future<void> albumRemove(String lib, String albumId, List<String> keys) =>
      _write('remove $lib ${keys.join(',')}');

  @override
  Future<List<MediaItem>> albumAll(String lib, String albumId) async =>
      [...albumItems];

  @override
  Future<void> albumOrder(String lib, String albumId, List<MediaItem> items) =>
      _write('order ${_keys(items).join(',')}');

  @override
  Future<AlbumPage> album(String libId, String albumId,
          {String? cursor, int limit = 60}) async =>
      AlbumPage(
          items: [...albumItems],
          title: 't',
          count: albumItems.length,
          readOnly: false);
}

/// 5件ずつの2ページ（a..e / f..j）を読み込み済みの一覧を作る。
Future<(GalleryState, _Api)> _twoPages() async {
  final api = _Api();
  api.pages = (c) => c == null
      ? FolderPage(items: [for (final k in 'abcde'.split('')) _it(k)], cursor: 'c1', sort: 'new')
      : FolderPage(items: [for (final k in 'fghij'.split('')) _it(k)], cursor: 'c2', sort: 'new');
  final g = GalleryState(api);
  await g.refresh('lib');
  await g.loadMore('lib');
  return (g, api);
}

void main() {
  group('一覧を巻き戻さない取り直し', () {
    test('新着は先頭に足し、消えた行は外し、読み込み済みの続きと cursor は残す', () async {
      final (g, api) = await _twoPages();
      expect(_keys(g.items), 'abcdefghij'.split(''));
      // b が消え、新着 n が入り、先頭ページの末尾が e から f までずれた
      api.pages = (_) => FolderPage(
          items: [_it('n'), _it('a', v: '2'), _it('c'), _it('d'), _it('e'), _it('f')],
          cursor: 'x1',
          sort: 'new');
      await g.softRefresh('lib');
      expect(_keys(g.items), ['n', 'a', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j']);
      // 重なった行は新しい行（新しい署名URL）に替わる
      expect(g.items[1].url, endsWith('v=2'));
      expect(g.cursor, 'c2', reason: '読み込み済みの2ページ目の続きから読む');
    });

    test('重ならない時だけ全部置き換える', () async {
      final (g, api) = await _twoPages();
      api.pages = (_) =>
          FolderPage(items: [_it('x'), _it('y')], cursor: 'x1', sort: 'new');
      await g.softRefresh('lib');
      expect(_keys(g.items), ['x', 'y']);
      expect(g.cursor, 'x1');
    });

    test('読み込み済みが先頭ページに収まっていれば、続きは先頭ページの cursor から', () async {
      final api = _Api()
        ..pages = (_) => FolderPage(items: [_it('a'), _it('b')], cursor: 'c1', sort: 'new');
      final g = GalleryState(api);
      await g.refresh('lib');
      api.pages = (_) =>
          FolderPage(items: [_it('n'), _it('a'), _it('b')], cursor: 'c9', sort: 'new');
      await g.softRefresh('lib');
      expect(_keys(g.items), ['n', 'a', 'b']);
      expect(g.cursor, 'c9');
    });

    test('取り直しの失敗では一覧を消さない', () async {
      final (g, api) = await _twoPages();
      api.pages = (_) => throw const ApiError(0, 'offline');
      await g.softRefresh('lib');
      expect(g.items, hasLength(10));
      expect(g.error, isNotNull);
    });
  });

  group('ゴミ箱へ（先に一覧から外す）', () {
    test('送り終わる前に一覧から消え、選択も外れる', () async {
      final (g, api) = await _twoPages();
      g.startSelection(g.items[1], 'lib');
      final p = g.trashOptimistic('lib', [const SelKey('lib', 'b'), const SelKey('lib', 'g')]);
      expect(_keys(g.items), ['a', 'c', 'd', 'e', 'f', 'h', 'i', 'j']);
      expect(g.selection, isEmpty);
      expect(g.selectionMode, isFalse);
      expect(api.trashCalls, ['b', 'g']);
      api.trashGates['b']!.complete('tk-b');
      api.trashGates['g']!.complete('tk-g');
      final res = await p.done;
      expect(res.trashed, 2);
      expect(_keys(g.items), ['a', 'c', 'd', 'e', 'f', 'h', 'i', 'j']);
    });

    test('送れなかった行だけ元の位置へ戻す', () async {
      final (g, api) = await _twoPages();
      final p = g.trashOptimistic('lib', [
        const SelKey('lib', 'a'),
        const SelKey('lib', 'b'),
        const SelKey('lib', 'j'),
      ]);
      api.trashGates['a']!.completeError(const ApiError(500, 'x'));
      api.trashGates['b']!.completeError(const ApiError(500, 'x'));
      api.trashGates['j']!.complete('tk-j');
      final res = await p.done;
      expect(res.failed, 2);
      expect(_keys(g.items), 'abcdefghi'.split(''));
      expect(g.bulkError, '2件をゴミ箱に移せませんでした');
    });

    test('全部失敗したら元の並びに完全に戻る', () async {
      final (g, api) = await _twoPages();
      final before = _keys(g.items);
      final p = g.trashOptimistic('lib', [
        for (final k in ['a', 'c', 'd', 'j']) SelKey('lib', k),
      ]);
      for (final c in api.trashGates.values) {
        c.completeError(const ApiError(0, 'offline'));
      }
      await p.done;
      expect(_keys(g.items), before);
    });

    test('送っている途中に届いた取り直しのページから、消した行を蘇らせない', () async {
      final (g, api) = await _twoPages();
      final p = g.trashOptimistic('lib', [const SelKey('lib', 'b')]);
      // Worker はまだ b を持っていて、取り直すと b 入りのページが返る
      await g.softRefresh('lib');
      expect(_keys(g.items), isNot(contains('b')));
      await g.refresh('lib');
      expect(_keys(g.items), isNot(contains('b')));
      api.trashGates['b']!.completeError(const ApiError(500, 'x'));
      await p.done;
      // 送れなかった時は元の位置に戻る
      expect(_keys(g.items).take(3), ['a', 'b', 'c']);
    });

    test('送っている途中の「元に戻す」は、すぐ元の位置へ戻し、送り終わってから復元する', () async {
      final (g, api) = await _twoPages();
      final before = _keys(g.items);
      final p = g.trashOptimistic(
          'lib', [const SelKey('lib', 'c'), const SelKey('lib', 'd')]);
      final undo = g.undoTrash('lib', p);
      expect(_keys(g.items), before, reason: '押した瞬間に戻る');
      await pumpEventQueue();
      expect(api.restoreCalls, isEmpty, reason: 'trashKey が揃うまで復元は送れない');

      api.trashGates['c']!.complete('tk-c');
      api.trashGates['d']!.complete('tk-d');
      await pumpEventQueue();
      expect(api.restoreCalls, ['tk-c']);
      api.restoreGates['tk-c']!.complete('c');
      await pumpEventQueue();
      api.restoreGates['tk-d']!.completeError(const ApiError(409, 'exists'));
      final res = await undo;
      expect(res.restored, 1);
      expect(res.conflict, 1);
      // 戻せなかった d は外し直す
      expect(_keys(g.items), [for (final k in before) if (k != 'd') k]);
    });

    test('trashKey を返さん古い Worker の分は、戻せなかったとして外し直す', () async {
      final (g, api) = await _twoPages();
      final p = g.trashOptimistic('lib', [const SelKey('lib', 'a')]);
      api.trashGates['a']!.complete('');
      final undo = g.undoTrash('lib', p);
      expect(g.items.first.key, 'a');
      final res = await undo;
      expect(res.failed, 1);
      expect(api.restoreCalls, isEmpty);
      expect(g.items.first.key, 'b');
    });

    test('外している間に一覧が変わっても、直前の行の後ろへ戻す', () async {
      final (g, api) = await _twoPages();
      final p = g.trashOptimistic('lib', [const SelKey('lib', 'c')]);
      // 先頭に新着が入った（取り直し）
      g.items = [_it('n'), ...g.items];
      api.trashGates['c']!.completeError(const ApiError(500, 'x'));
      await p.done;
      expect(_keys(g.items).take(5), ['n', 'a', 'b', 'c', 'd']);
    });
  });

  testWidgets('写真の一覧でゴミ箱へ: 送り終わる前に消えて「元に戻す」が出る。失敗したら元の位置に戻って知らせる',
      (tester) async {
    final (g, api) = await _twoPages();
    final app = AppState(api: api, bakedEndpoint: '', bakedToken: '')
      ..connected = true
      ..libraries = [const Library(id: 'lib', title: 'L')]
      ..activeLib = 'lib';
    final c = MediaController(app)..bind(g, 'lib');
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: Builder(builder: (context) {
      ctx = context;
      return const SizedBox();
    }))));
    unawaited(c.trashOne(ctx, g.items[2]));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(_keys(g.items).contains('c'), isFalse);
    expect(find.text('1件をゴミ箱に移しました'), findsOneWidget);
    expect(find.text('元に戻す'), findsOneWidget);

    api.trashGates['c']!.completeError(const ApiError(500, 'x'));
    await tester.pumpAndSettle();
    expect(_keys(g.items), 'abcdefghij'.split(''));
    expect(find.text('ゴミ箱への移動に失敗しました'), findsOneWidget);
    // 移せなかったので「移しました」は引っ込める
    expect(find.text('1件をゴミ箱に移しました'), findsNothing);
  });

  group('ゴミ箱タブの復元（先に行を外す）', () {
    TrashItem t(String k) =>
        TrashItem(trashKey: 'tk-$k', key: k, deletedAt: 1, size: 1);

    test('返事の前に行が消え、失敗したら同じ位置へ戻る', () async {
      final api = _Api();
      final s = TrashState(api)..items = [t('a'), t('b'), t('c')];
      s.selected.add('tk-b');
      final f = s.restoreOne('lib', s.items[1]);
      expect([for (final i in s.items) i.key], ['a', 'c']);
      api.restoreGates['tk-b']!.completeError(const ApiError(500, 'x'));
      expect(await f, 500);
      expect([for (final i in s.items) i.key], ['a', 'b', 'c']);
      expect(s.selected, {'tk-b'});
    });

    test('まとめて復元も先に外し、戻せなかった行だけ戻す', () async {
      final api = _Api();
      final s = TrashState(api);
      final load = s.refresh('lib');
      api.trashListGate!.complete(TrashPage([t('a'), t('b'), t('c'), t('d')], null));
      await load;
      s.selected.addAll(['tk-a', 'tk-c', 'tk-d']);
      final f = s.bulkRestore('lib');
      expect([for (final i in s.items) i.key], ['b']);
      api.restoreGates['tk-a']!.complete('a');
      await pumpEventQueue();
      api.restoreGates['tk-c']!.completeError(const ApiError(409, 'x'));
      await pumpEventQueue();
      api.restoreGates['tk-d']!.complete('d');
      await pumpEventQueue();
      // 読み直しの返事の前: 戻せなかった c だけが元の位置に戻っている
      expect([for (final i in s.items) i.key], ['b', 'c']);
      // 失敗が混ざったので読み直して整える
      api.trashListGate!.complete(TrashPage([t('b'), t('c')], null));
      final res = await f;
      expect(res.restored, 2);
      expect(res.conflict, 1);
      expect([for (final i in s.items) i.key], ['b', 'c']);
    });

    test('まとめて全部戻せたら読み直さない', () async {
      final api = _Api();
      final s = TrashState(api)..items = [t('a'), t('b')];
      s.selected.addAll(['tk-a']);
      final f = s.bulkRestore('lib');
      api.restoreGates['tk-a']!.complete('a');
      await f;
      expect(api.trashListGate, isNull);
      expect([for (final i in s.items) i.key], ['b']);
    });
  });

  group('アルバムの操作（先に画面へ反映）', () {
    test('作成は仮の id ですぐ出し、id が来たら差し替える。失敗したら消す', () async {
      final api = _Api();
      final h = AlbumsHomeState(api)..albums = [const Album(id: 'x', title: '家族')];
      final f = h.create('lib', '旅行');
      expect([for (final a in h.albums) a.title], ['家族', '旅行']);
      final tmp = h.albums.last.id;
      expect(h.isPending(tmp), isTrue);
      api.createGate!.complete('al-9');
      expect(await f, isNull);
      expect(h.albums.last.id, 'al-9');
      expect(h.isPending('al-9'), isFalse);

      final f2 = h.create('lib', '失敗');
      expect(h.albums, hasLength(3));
      api.createGate!.completeError(const ApiError(500, 'x'));
      expect(await f2, isNotNull);
      expect([for (final a in h.albums) a.title], ['家族', '旅行']);
    });

    test('名前変更はすぐ反映し、失敗したら元の名前へ戻す', () async {
      final api = _Api();
      final h = AlbumsHomeState(api)..albums = [const Album(id: 'x', title: '家族', count: 4)];
      final f = h.rename('lib', 'x', '家族2');
      expect(h.albums.single.title, '家族2');
      api.writeGate!.completeError(const ApiError(500, 'x'));
      expect(await f, isNotNull);
      expect(h.albums.single.title, '家族');
      expect(h.albums.single.count, 4);
    });

    test('削除はすぐ外し、失敗したら元の位置へ戻す', () async {
      final api = _Api();
      final h = AlbumsHomeState(api)
        ..albums = [
          const Album(id: 'x', title: 'X'),
          const Album(id: 'y', title: 'Y'),
          const Album(id: 'z', title: 'Z'),
        ];
      final f = h.delete('lib', 'y');
      expect([for (final a in h.albums) a.id], ['x', 'z']);
      api.writeGate!.completeError(const ApiError(500, 'x'));
      expect(await f, isNotNull);
      expect([for (final a in h.albums) a.id], ['x', 'y', 'z']);
    });

    test('アルバムから外すのはすぐ反映し、失敗したら元の並びと件数へ戻す', () async {
      final api = _Api()..albumItems = [_it('1'), _it('2'), _it('3')];
      final s = AlbumDetailState(api, 'lib', 'al');
      await s.refresh();
      final f = s.removeItems([s.items[1]]);
      expect(_keys(s.items), ['1', '3']);
      expect(s.count, 2);
      api.writeGate!.completeError(const ApiError(500, 'x'));
      expect(await f, 'アルバムから外せませんでした');
      expect(_keys(s.items), ['1', '2', '3']);
      expect(s.count, 3);
    });

    test('並び替えはすぐ動かし、書き戻せなかったら元の並びへ戻す', () async {
      final api = _Api()..albumItems = [_it('1'), _it('2'), _it('3')];
      final s = AlbumDetailState(api, 'lib', 'al');
      await s.refresh();
      final f = s.moveItem(s.items[0], 1);
      expect(_keys(s.items), ['2', '1', '3']);
      await pumpEventQueue();
      expect(api.writes.last, 'order 2,1,3');
      api.writeGate!.completeError(const ApiError(409, 'x'));
      expect(await f, '並び替えに失敗しました');
      expect(_keys(s.items), ['1', '2', '3']);
    });

    test('並び替えが通れば読み直さない', () async {
      final api = _Api()..albumItems = [_it('1'), _it('2')];
      final s = AlbumDetailState(api, 'lib', 'al');
      await s.refresh();
      final f = s.moveItem(s.items[1], -1);
      await pumpEventQueue();
      api.writeGate!.complete();
      expect(await f, isNull);
      expect(_keys(s.items), ['2', '1']);
    });
  });
}
