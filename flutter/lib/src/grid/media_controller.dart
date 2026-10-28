import 'package:flutter/material.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../state/write_guard.dart';
import '../ui/write_guard_notice.dart';
import '../ui/album_picker.dart';
import '../ui/theme.dart';
import '../ui/trash_undo.dart';
import '../viewer/device_export.dart';
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
  void toggleAll() => g.toggleAll(_lib);

  @override
  void clearSelection() => g.clearSelection();

  // 操作を始めた時の一覧とライブラリを掴んでおく。終わる前に切り替えても別の一覧を取り直さない
  Future<void> Function() _refresher() {
    final g = this.g, lib = _lib;
    return () => g.refresh(lib);
  }

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
    final messenger = ScaffoldMessenger.of(context);
    final g = this.g, lib = _lib;
    final refresh = _refresher();
    final res = await g.bulkTrash(lib, refresh);
    // 送れた分の「元に戻す」は失敗の知らせを閉じるのを待たずに出す（6秒しかない）
    // trashKey を返さん Worker だと戻す手段が無い。移した事実だけは伝える（#148）
    if (res.trashed > 0 && res.receipts.isEmpty) {
      messenger.showSnackBar(
          SnackBar(content: Text('${res.trashed}件をゴミ箱に移しました')));
    }
    final undo = offerTrashUndo(
      messenger,
      app.api,
      res.receipts,
      onRestored: refresh,
    );
    if (res.failed > 0 && context.mounted) {
      await _alert(context, '${res.failed}件をゴミ箱に移せませんでした');
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
    if (!outcome.ok) {
      await _alert(context, outcome.error!);
      return;
    }
    g.clearSelection();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('${targets.length}件をアルバムに追加しました')));
  }

  Future<void> saveSelectedOffline(BuildContext context) async {
    // オフライン保存は #149 の転送キューに積む（暗号化して端末に置く）
    if (!app.offlineSupported) return;
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
        queued += await app.saveOffline(e.key, e.value);
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
    // 端末への書き出しが無い環境（web 等）では項目ごと出さない
    final export = app.deviceExportSupported;
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
            if (export)
              TextButton(
                onPressed: () => Navigator.of(ctx).pop('export'),
                child: const Text('端末に保存'),
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
    if (choice == null || !context.mounted) return;
    final itemLib = item.lib ?? _lib;
    switch (choice) {
      case 'export':
        String msg;
        try {
          await app.exportToDevice(item, lib: itemLib);
          msg = '端末に保存しました';
        } on DeviceExportError catch (e) {
          msg = e.message;
        } on ApiError catch (e) {
          debugPrint('export failed: $e');
          msg = '端末への保存に失敗しました';
        }
        if (context.mounted) await _alert(context, msg);
      case 'album':
        final outcome = await pickAlbumAndAdd(context, app,
            lib: itemLib, targets: [(itemLib, item.key)]);
        if (outcome != null && !outcome.ok && context.mounted) {
          await _alert(context, outcome.error!);
        }
      case 'trash':
        await trashOne(context, item);
    }
  }

  /// 1枚をすぐゴミ箱へ送り、「元に戻す」を出す（確認ダイアログは置かない。KMP 版と同じ）。
  Future<void> trashOne(BuildContext context, MediaItem item) async {
    if (!ensureWritable(context, app, item.lib ?? _lib, WriteAction.trash)) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final g = this.g, lib = _lib;
    final refresh = _refresher();
    final itemLib = item.lib ?? lib;
    final res = await trashAll(app.api, [(lib: itemLib, key: item.key)]);
    if (res.failed > 0) {
      if (context.mounted) await _alert(context, 'ゴミ箱への移動に失敗しました');
      return;
    }
    // 選んでいた1枚が消えるので、選択からも外して件数を合わせる
    if (g.selection.contains(g.selKeyOf(item, lib))) {
      g.toggleSelect(item, lib);
    }
    await refresh();
    await offerTrashUndo(messenger, app.api, res.receipts,
        onRestored: refresh);
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
