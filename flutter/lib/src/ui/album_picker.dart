import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../state/app_state.dart';
import '../state/write_guard.dart';
import 'write_guard_notice.dart';

/// 別のライブラリの項目が混ざった選択。アルバムは1ライブラリに属し、追加 API は
/// キーだけを受け取るので、混ざったまま送ると別の棚の同名ファイルを入れてしまう。
class MixedLibraryError implements Exception {
  const MixedLibraryError();
  @override
  String toString() => 'mixed libraries';
}

/// 選んだ項目（lib, key）を既存アルバム [albumId] か新規アルバム [newTitle] へ入れる。
/// [fallbackLib] 以外のライブラリが混ざっていたら、黙って落とさず失敗にする。
Future<void> bulkAddToAlbum({
  required Future<String> Function(String lib, String title) create,
  required Future<void> Function(String lib, String albumId, List<String> keys)
  add,
  required String fallbackLib,
  required List<(String, String)> targets,
  String? albumId,
  String? newTitle,
}) async {
  if (albumId == null && (newTitle == null || newTitle.trim().isEmpty)) {
    throw ArgumentError('album or new title required');
  }
  if (targets.any((t) => t.$1 != fallbackLib)) throw const MixedLibraryError();
  final id = albumId ?? await create(fallbackLib, newTitle!.trim());
  if (id.isEmpty) throw const ApiError(0, 'album id missing');
  final keys = [for (final t in targets) t.$2];
  for (var i = 0; i < keys.length; i += albumAddChunk) {
    final end = i + albumAddChunk > keys.length
        ? keys.length
        : i + albumAddChunk;
    await add(fallbackLib, id, keys.sublist(i, end));
  }
}

/// 「アルバムに追加」の入口は写真タブ・アルバム・フォルダ・ビューワーのどこからでもこれ1つ。
/// 書けないライブラリなら理由を出して開かない。[targets] は (lib, key)。
/// 戻り値: 閉じただけなら null。追加を試みたら結果（失敗なら error に画面へ出す文言）。
Future<AlbumPickOutcome?> pickAlbumAndAdd(
  BuildContext context,
  AppState app, {
  required String lib,
  required List<(String, String)> targets,
}) async {
  if (targets.isEmpty) return null;
  if (!ensureWritable(context, app, lib, WriteAction.edit)) return null;
  final api = app.api;
  return showAlbumPicker(
    context,
    api: api,
    lib: lib,
    onPick: (albumId, newTitle) => bulkAddToAlbum(
      create: api.albumCreate,
      add: api.albumAdd,
      fallbackLib: lib,
      targets: targets,
      albumId: albumId,
      newTitle: newTitle,
    ),
  );
}

/// 書き込めるアルバム一覧。自動で作られる「その他」と読み取り専用アルバムは入れられないので外す。
Future<List<Album>> writableAlbums(ApiClient api, String lib) async {
  try {
    final all = await api.albums(lib);
    return all.where((a) => a.id != otherAlbumId && !a.readOnly).toList();
  } on Exception catch (e) {
    // 一覧が取れなくても新規作成はできるので、空の一覧で続ける（KMP 版と同じ）
    debugPrint('albums load failed: $e');
    return const [];
  }
}

/// 「アルバムに追加」ダイアログ。既存アルバムを選ぶか、新しい名前を入れて作成して追加する。
/// 追加の本体は [onPick]（albumId か newTitle のどちらか）。処理中はダイアログを閉じずに待つ。
/// 戻り値: 追加できたら true、キャンセルなら null。失敗時は [failureMessage] を返す。
Future<AlbumPickOutcome?> showAlbumPicker(
  BuildContext context, {
  required ApiClient api,
  required String lib,
  required Future<void> Function(String? albumId, String? newTitle) onPick,
  String failureMessage = 'アルバムへの追加に失敗しました',
}) {
  return showDialog<AlbumPickOutcome>(
    context: context,
    builder: (_) => AlbumPickerDialog(
      albums: writableAlbums(api, lib),
      onPick: onPick,
      failureMessage: failureMessage,
    ),
  );
}

/// ダイアログの結果。[error] が null なら追加できた。
class AlbumPickOutcome {
  final String? error;
  const AlbumPickOutcome({this.error});
  bool get ok => error == null;
}

class AlbumPickerDialog extends StatefulWidget {
  final Future<List<Album>> albums;
  final Future<void> Function(String? albumId, String? newTitle) onPick;
  final String failureMessage;
  const AlbumPickerDialog({
    super.key,
    required this.albums,
    required this.onPick,
    required this.failureMessage,
  });

  @override
  State<AlbumPickerDialog> createState() => _AlbumPickerDialogState();
}

class _AlbumPickerDialogState extends State<AlbumPickerDialog> {
  final _title = TextEditingController();
  List<Album>? _albums;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.albums.then((a) {
      if (mounted) setState(() => _albums = a);
    });
    _title.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _pick(String? albumId, String? newTitle) async {
    // 二度押しで同じアルバムへ二重に作成・追加しないよう、処理中は受け付けない
    if (_busy) return;
    setState(() => _busy = true);
    String? error;
    try {
      await widget.onPick(albumId, newTitle);
    } on Exception catch (e) {
      debugPrint('album add failed: $e');
      error = widget.failureMessage;
    }
    if (!mounted) return;
    Navigator.of(context).pop(AlbumPickOutcome(error: error));
  }

  @override
  Widget build(BuildContext context) {
    final albums = _albums;
    final title = _title.text.trim();
    // 処理中に外側タップや戻るで閉じると、結果を受け取る相手がいなくなる
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: const Text('アルバムに追加'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (albums == null)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                for (final a in albums)
                  TextButton(
                    onPressed: _busy ? null : () => _pick(a.id, null),
                    child: Text('${a.title}（${a.count}）'),
                  ),
              const SizedBox(height: 8),
              TextField(
                controller: _title,
                enabled: !_busy,
                decoration: const InputDecoration(hintText: '新しいアルバム名'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: _busy || title.isEmpty ? null : () => _pick(null, title),
            child: Text(_busy ? '追加中…' : '作成して追加'),
          ),
        ],
      ),
    );
  }
}
