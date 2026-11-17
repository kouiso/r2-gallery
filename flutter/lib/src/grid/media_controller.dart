import 'dart:async';

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../state/write_guard.dart';
import '../ui/write_guard_notice.dart';
import '../ui/album_picker.dart';
import '../ui/theme.dart';
import '../ui/trash_undo.dart';
import 'photos_chrome.dart';
import 'selection_widgets.dart';

/// 写真タブ・フォルダ画面で共通の「選択と操作」。一覧の状態（GalleryState）に
/// 一括ゴミ箱＋元に戻す・アルバムへ・オフライン・長押しメニューをつなぐ。
/// 上下のバーはこれを [SelectionSurface] として見る。
class MediaController extends ChangeNotifier implements SelectionSurface {
  MediaController(this.app);

  final AppState app;
  GalleryState? _g;
  String _lib = '';

  GalleryState get g => _g!;
  String get lib => _lib;

  /// 見ている一覧を差し替える（ライブラリ切替）。選択の変化をバーへ伝えるため購読を付け替える。
  void bind(GalleryState g, String lib) {
    if (identical(_g, g) && _lib == lib) return;
    _g?.removeListener(notifyListeners);
    _g = g;
    _lib = lib;
    g.addListener(notifyListeners);
  }

  @override
  void dispose() {
    _g?.removeListener(notifyListeners);
    super.dispose();
  }

  bool get readOnly => app.isReadOnlyLib(_lib);

  /// 読み取り専用でも、オフライン保存は読むだけで済むので選択は許す（KMP 版と同じ）。
  bool get canSelect => !readOnly || app.offlineSupported;

  @override
  int get selectedCount => _g?.selection.length ?? 0;

  @override
  bool get allSelected => _g?.allSelected(_lib) ?? false;

  @override
  bool get selectingAll => _g?.selectAllBusy ?? false;

  @override
  void toggleAll() {
    if (allSelected) {
      g.toggleAll(_lib);
    } else {
      // 残りページを取り切ってから選ぶ。読み込み済み分だけ選ぶと
      // 「全部選んだはずなのに保存されない」に見える
      unawaited(g.selectAllFully(_lib));
    }
  }

  @override
  void clearSelection() => g.clearSelection();

  @override
  List<SelAction> selectionActions(BuildContext context) {
    final busy = _g?.bulkBusy ?? false;
    VoidCallback? when(VoidCallback f) => busy ? null : f;
    return [
      if (!readOnly) addToAlbumAction(when(() => addSelectedToAlbum(context))),
      if (app.offlineSupported)
        offlineAction(when(() => saveSelectedOffline(context))),
      if (!readOnly) trashAction(when(() => trashSelected(context))),
    ];
  }

  /// 長押し。未選択なら選択モードへ、選択中ならその1枚の個別メニュー（KMP 版と同じ）。
  void onLongPress(BuildContext context, MediaItem item) {
    if (!canSelect) return;
    if (g.selection.isEmpty) {
      g.startSelection(item, _lib);
    } else {
      showItemMenu(context, item);
    }
  }

  Future<void> trashSelected(BuildContext context) async {
    if (!ensureWritable(context, app, _lib, WriteAction.trash)) return;
    final targets = g.selection.toList();
    if (targets.isEmpty) return;
    await _trashOptimistic(
        context, targets, (failed) => '$failed件をゴミ箱に移せませんでした');
  }

  /// 一覧からすぐ外し、「元に戻す」もすぐ出す。送れなかった行は元の位置へ戻して知らせる。
  /// 一覧と lib は始めた時のものを掴む。終わる前にライブラリを切り替えても別の一覧を触らない
  Future<void> _trashOptimistic(BuildContext context, List<SelKey> targets,
      String Function(int failed) failMessage) async {
    final messenger = ScaffoldMessenger.of(context);
    final g = this.g, lib = _lib;
    final pending = g.trashOptimistic(lib, targets);
    // 「元に戻す」は失敗の知らせを閉じるのを待たずに出す（6秒しかない）
    final undo = offerOptimisticTrashUndo(
      messenger,
      count: pending.count,
      done: pending.done,
      onUndo: () async {
        final res = await g.undoTrash(lib, pending);
        // 戻した行をサーバーの今の状態（新しい署名URLなど）にそろえる。読み進めた位置は崩さない
        unawaited(g.softRefresh(lib));
        return res;
      },
    );
    final res = await pending.done;
    if (res.failed > 0 && context.mounted) {
      await _alert(context, failMessage(res.failed));
    }
    await undo;
  }

  List<MediaItem> _selectedItems() {
    final g = this.g;
    return [
      for (final it in g.items)
        if (g.selection.contains(g.selKeyOf(it, _lib))) it,
    ];
  }

  Future<void> addSelectedToAlbum(BuildContext context) async {
    final g = this.g, lib = _lib;
    final targets = [for (final k in g.selection) (k.lib, k.key)];
    final outcome =
        await pickAlbumAndAdd(context, app, lib: lib, targets: targets);
    if (outcome == null || !context.mounted) return;
    // 送り終わるのを待たずに選択を解いて知らせる。失敗したら選択を戻して理由を出す
    final picked = {...g.selection};
    g.clearSelection();
    final messenger = ScaffoldMessenger.of(context);
    final shown = messenger.showSnackBar(
        SnackBar(content: Text('${targets.length}件をアルバムに追加しました')));
    final err = await outcome.done;
    if (err == null) return;
    shown.close();
    if (g.selection.isEmpty) g.reselect(picked);
    if (context.mounted) await _alert(context, err);
  }

  Future<void> saveSelectedOffline(BuildContext context) async {
    // オフライン保存は #149 の転送キューに積む（暗号化して端末に置く）
    if (!app.offlineSupported || !app.offlineAccessible) return;
    final account = app.offlineAccountId;
    bool stillAuthorized() =>
        account != null &&
        app.offlineAccessible &&
        app.offlineAccountId == account;
    final items = _selectedItems();
    final messenger = ScaffoldMessenger.of(context);
    g.clearSelection();
    // アルバム由来の一覧はライブラリが混ざり得るので、ライブラリごとに束ねて渡す
    final byLib = <String, List<MediaItem>>{};
    for (final it in items) {
      (byLib[it.lib ?? _lib] ??= []).add(it);
    }
    try {
      var queued = 0;
      for (final e in byLib.entries) {
        // 前の保存を待つ間の切替・ロック後に、別の資格で続きを積まない。
        if (!stillAuthorized()) return;
        queued += await app.saveOffline(e.key, e.value);
        if (!stillAuthorized()) return;
      }
      // 保存済み・積み済みは数えないので、0 件ならその旨を出す（#149 と同じ文言）
      messenger.showSnackBar(SnackBar(
          content: Text(queued > 0
              ? '$queued件をオフライン保存に追加しました'
              : 'オフライン保存済みです')));
    } on Exception catch (e) {
      debugPrint('offline save failed: $e');
      messenger.showSnackBar(
        const SnackBar(content: Text('オフライン保存に追加できませんでした')),
      );
    }
  }

  /// 1枚の個別メニュー。読み取り専用では書き換える項目を一切出さず、その旨を書く。
  Future<void> showItemMenu(BuildContext context, MediaItem item) async {
    final readOnly = this.readOnly;
    final account = app.offlineAccountId;
    final offline = app.offlineSupported;
    final itemLib = item.lib ?? _lib;
    final saved = app.isOffline(itemLib, item.key);
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (readOnly)
              const Text(
                'このライブラリは読み取り専用です',
                style: TextStyle(color: AppColors.textDim),
              ),
            if (offline)
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(saved ? 'offline-remove' : 'offline-save'),
                child: Text(saved ? '保存済みを削除' : 'オフライン保存'),
              ),
            if (!readOnly) ...[
              TextButton(
                onPressed: () => Navigator.of(ctx).pop('album'),
                child: const Text('アルバムに追加'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop('trash'),
                child: const Text(
                  'ゴミ箱へ',
                  style: TextStyle(color: AppColors.danger),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('閉じる'),
          ),
        ],
      ),
    );
    if (choice == null || !context.mounted || account != app.offlineAccountId) return;
    switch (choice) {
      case 'offline-save':
        try {
          final queued = await app.saveOffline(itemLib, [item]);
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
                queued > 0 ? 'オフライン保存に追加しました' : '保存済み、または保存待ちです')));
          }
        } on Exception {
          if (context.mounted) await _alert(context, 'オフライン保存に追加できませんでした');
        }
      case 'offline-remove':
        final remove = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('このオフライン保存を削除しますか？'),
            content: const Text('このアプリ内の保存だけを削除します。サーバー上の作品は消えません。'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('キャンセル')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('削除')),
            ],
          ),
        );
        if (remove == true && account == app.offlineAccountId) {
          try {
            await app.removeOffline(itemLib, item.key);
          } on Exception {
            if (context.mounted) await _alert(context, 'オフライン保存を削除できませんでした');
          }
        }
      case 'album':
        final outcome = await pickAlbumAndAdd(context, app,
            lib: itemLib, targets: [(itemLib, item.key)]);
        final err = await outcome?.done;
        if (err != null && context.mounted) await _alert(context, err);
      case 'trash':
        await trashOne(context, item);
    }
  }

  /// 1枚をすぐゴミ箱へ送り、「元に戻す」を出す（確認ダイアログは置かない。KMP 版と同じ）。
  /// 選んでいた1枚なら選択からも外れる（trashOptimistic が外す）。
  Future<void> trashOne(BuildContext context, MediaItem item) async {
    if (!ensureWritable(context, app, item.lib ?? _lib, WriteAction.trash)) {
      return;
    }
    await _trashOptimistic(
        context, [g.selKeyOf(item, _lib)], (_) => 'ゴミ箱への移動に失敗しました');
  }

  Future<void> _alert(BuildContext context, String msg) => showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(msg),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}
