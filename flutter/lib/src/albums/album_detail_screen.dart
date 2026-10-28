import 'package:flutter/material.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../state/write_guard.dart';
import '../ui/write_guard_notice.dart';
import '../ui/album_picker.dart';
import '../ui/viewer_screen.dart' show openViewer;
import '../ui/theme.dart';
import 'album_states.dart';
import 'album_widgets.dart';
import 'item_actions.dart';
import '../ui/trash_undo.dart';

/// アルバムの中身。選択して前へ／後ろへ／外す／ゴミ箱へ、長押しメニュー、引っ張って更新、続きの自動読み込み。
class AlbumDetailScreen extends StatefulWidget {
  final AppState app;
  final String lib;
  final Album album;

  /// テストで差し替えるための状態。通常は画面が作る
  final AlbumDetailState? state;
  /// シェルのアルバムタブに子画面として載せる時の戻る。null なら画面を積んだ時の戻る（見出しは自動）
  final VoidCallback? onBack;
  /// 選択に入った・抜けた時。シェルは選択中だけ下タブを隠す
  final ValueChanged<bool>? onSelectingChanged;
  /// 見えている画面か。裏に残っている間に別のタブで増減した分を映すため、見えるように戻った時に読み直す
  final bool active;
  const AlbumDetailScreen({
    super.key,
    required this.app,
    required this.lib,
    required this.album,
    this.state,
    this.onBack,
    this.onSelectingChanged,
    this.active = true,
  });

  @override
  State<AlbumDetailScreen> createState() => _AlbumDetailScreenState();
}

class _AlbumDetailScreenState extends State<AlbumDetailScreen> {
  late final AlbumDetailState s = widget.state ??
      AlbumDetailState(widget.app.api, widget.lib, widget.album.id);

  bool get _libReadOnly => widget.app.libraries
      .any((l) => l.id == widget.lib && l.readOnly);

  /// 並び替え・外すができるか。読み込み前は書き換え不可として扱う（worker の返す readOnly 待ち）
  bool get _orderable => canEditAlbum(
      libReadOnly: _libReadOnly,
      albumReadOnly: s.albumReadOnly,
      albumId: widget.album.id);

  bool _selecting = false;

  @override
  void initState() {
    super.initState();
    s.title = widget.album.title;
    s.count = widget.album.count;
    s.addListener(_reportSelecting);
    s.refresh();
  }

  @override
  void didUpdateWidget(AlbumDetailScreen old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) s.refresh();
  }

  void _reportSelecting() {
    final now = s.selection.isNotEmpty;
    if (now == _selecting) return;
    _selecting = now;
    widget.onSelectingChanged?.call(now);
  }

  @override
  void dispose() {
    s.removeListener(_reportSelecting);
    if (widget.state == null) s.dispose();
    super.dispose();
  }

  void _showError(String? err) {
    if (err != null && mounted) showMessageDialog(context, err);
  }

  void _offerUndo(List<TrashReceipt> receipts) {
    offerTrashUndo(ScaffoldMessenger.of(context), widget.app.api, receipts,
        onRestored: s.refresh);
  }

  // アルバムの中の書き換えは、送る前に書き込みのガード（#145）を通す
  bool _can(WriteAction a) => ensureWritable(context, widget.app, widget.lib, a);

  Future<void> _trashSelected() async {
    if (!_can(WriteAction.trash)) return;
    final res = await s.trashSelected();
    if (!mounted) return;
    _offerUndo(res.receipts);
    if (res.failed > 0) _showError('${res.failed}件をゴミ箱に移せませんでした');
  }

  void _onLongPress(MediaItem it) {
    // 読み取り専用のライブラリでは選択して行える操作が無いので、選択にも入れない
    if (_libReadOnly) return;
    if (s.selection.isEmpty) {
      s.toggle(it);
    } else {
      _itemMenu(it);
    }
  }

  Future<void> _itemMenu(MediaItem it) async {
    final a = await showItemActions(context,
        item: it, readOnly: _libReadOnly, inAlbum: _orderable);
    if (a == null || !mounted) return;
    switch (a) {
      case ItemAction.movePrev:
        if (!_can(WriteAction.edit)) return;
        _showError(await s.moveItem(it, -1));
      case ItemAction.moveNext:
        if (!_can(WriteAction.edit)) return;
        _showError(await s.moveItem(it, 1));
      case ItemAction.removeFromAlbum:
        if (!_can(WriteAction.edit)) return;
        _showError(await s.removeItems([it]));
      case ItemAction.addToAlbum:
        final itLib = it.lib ?? widget.lib;
        final res = await pickAlbumAndAdd(context, widget.app,
            lib: itLib, targets: [(itLib, it.key)]);
        if (res == null || !mounted) return;
        if (!res.ok) return _showError(res.error);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('1件をアルバムに追加しました')));
          s.refresh();
        }
      case ItemAction.trash:
        if (!_can(WriteAction.trash)) return;
        final res = await trashAll(widget.app.api,
            [(lib: it.lib ?? widget.lib, key: it.key)]);
        if (!mounted) return;
        await s.refresh();
        if (!mounted) return;
        if (res.failed > 0) {
          _showError('ゴミ箱への移動に失敗しました');
        } else {
          _offerUndo(res.receipts);
        }
    }
  }

  List<SelAction> _actions() {
    final busy = s.opsBusy || s.bulkBusy;
    return [
      if (s.selection.length == 1 && _orderable) ...[
        SelAction('前へ', Icons.keyboard_arrow_left,
            () async {
              if (_can(WriteAction.edit)) _showError(await s.moveSelected(-1));
            },
            enabled: !busy),
        SelAction('後ろへ', Icons.keyboard_arrow_right,
            () async {
              if (_can(WriteAction.edit)) _showError(await s.moveSelected(1));
            },
            enabled: !busy),
      ],
      if (_orderable)
        SelAction('外す', Icons.remove_circle_outline,
            () async {
              if (_can(WriteAction.edit)) _showError(await s.removeSelected());
            },
            enabled: !busy),
      if (!_libReadOnly)
        SelAction('ゴミ箱へ', Icons.delete_outline, _trashSelected,
            danger: true, enabled: !busy),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: s,
      builder: (context, _) {
        final selecting = s.selection.isNotEmpty;
        final items = s.items;
        Widget body;
        if (s.loading && items.isEmpty) {
          body = const Center(child: CircularProgressIndicator());
        } else if (s.error != null && items.isEmpty) {
          body = Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(s.error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.danger)),
              const SizedBox(height: 12),
              FilledButton.tonal(
                  onPressed: s.refresh, child: const Text('再試行')),
            ]),
          );
        } else if (items.isEmpty) {
          body = RefreshIndicator(
            onRefresh: s.refresh,
            child: ListView(children: const [
              SizedBox(height: 160),
              Center(
                  child: Text('空のアルバムです',
                      style: TextStyle(color: AppColors.textDim))),
            ]),
          );
        } else {
          body = AlbumMediaGrid(
            items: items,
            lib: widget.lib,
            selection: s.selection,
            loadingMore: s.loadingMore,
            onRefresh: s.refresh,
            onNearEnd: s.loadMore,
            onOpen: (it) => openViewer(context,
                app: widget.app,
                lib: widget.lib,
                items: items,
                index: items.indexOf(it).clamp(0, items.length - 1),
                onChanged: s.refresh),
            onToggle: s.toggle,
            onLongPress: _onLongPress,
          );
        }
        return PopScope(
          // 選択中の戻る操作は選択の解除にする（KMP 版の閉じるボタンと同じ）
          canPop: !selecting,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) s.clearSelection();
          },
          child: Scaffold(
            appBar: AppBar(
              leading: selecting
                  ? IconButton(
                      tooltip: '選択を解除',
                      icon: const Icon(Icons.close),
                      onPressed: s.clearSelection)
                  : widget.onBack == null
                      ? null
                      : BackButton(onPressed: widget.onBack),
              title: Text(selecting
                  ? '${s.selection.length}件を選択'
                  : s.title.isEmpty
                      ? 'アルバム'
                      : '${s.title}（${s.count}）'),
              actions: [
                if (selecting)
                  TextButton(
                    onPressed: () => s.toggleAll(items),
                    child: Text(s.selection.allSelected(items, widget.lib)
                        ? 'すべて解除'
                        : 'すべて選択'),
                  ),
              ],
            ),
            body: Column(children: [
              if (s.error != null && items.isNotEmpty)
                MaterialBanner(
                  content: Text(s.error!),
                  actions: [
                    TextButton(
                        onPressed: s.refresh, child: const Text('再試行')),
                  ],
                ),
              Expanded(child: body),
            ]),
            bottomNavigationBar:
                selecting ? SelectionActionsBar(actions: _actions()) : null,
          ),
        );
      },
    );
  }
}
