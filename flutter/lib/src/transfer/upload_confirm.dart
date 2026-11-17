import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../api/models.dart';
import '../duplicates/content_hash.dart';
import '../duplicates/upload_check.dart';
import '../duplicates/upload_check_panel.dart';
import '../state/app_state.dart';
import '../ui/album_picker.dart';
import '../ui/theme.dart';
import '../webdl/media_name.dart';
import 'transfer_queue.dart';
import 'transfer_rows.dart';

/// 確認シートに出す要約。名前は先頭から [previewCount] 件まで、残りは件数にまとめる（KMP 版 summarizeUpload）。
class UploadSummary {
  final String title;
  final String sizeText;
  final List<UploadSource> preview;
  final int more;
  const UploadSummary(this.title, this.sizeText, this.preview, this.more);
}

const previewCount = 3;

UploadSummary summarizeUpload(List<UploadSource> items) {
  final known = items.where((i) => i.size > 0).toList();
  final total = known.fold<int>(0, (a, i) => a + i.size);
  final sizeText = items.isEmpty || known.isEmpty
      ? 'サイズ不明'
      : known.length == items.length
          ? formatBytes(total)
          : '${formatBytes(total)}（一部サイズ不明）';
  return UploadSummary(
    '${items.length}件をアップロード',
    sizeText,
    items.take(previewCount).toList(),
    items.length > previewCount ? items.length - previewCount : 0,
  );
}

/// 拡張子から MIME。HEIC はネット取り込みの表に無いので足す。
String uploadMimeFor(String name) {
  final m = mimeForName(name);
  if (m != 'application/octet-stream') return m;
  final lower = name.toLowerCase();
  if (lower.endsWith('.heic') || lower.endsWith('.heif')) return 'image/heic';
  return m;
}

/// アップロード確認シートの中身（KMP 版 UploadConfirmContent、design #37 画面06）。
class UploadConfirmContent extends StatelessWidget {
  final UploadSummary summary;
  final String libTitle;
  final bool readOnly;
  final bool noLibrary;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  /// 重複確認の欄（#101）。書き込めない保存先では照合しないので null。
  final Widget? duplicateCheck;

  /// アルバムの入れ先の欄（#102）。書き込めない保存先では選べないので null。
  final ValueListenable<String>? albumLabel;
  final VoidCallback? onPickAlbum;
  const UploadConfirmContent({
    super.key,
    required this.summary,
    required this.libTitle,
    required this.readOnly,
    required this.noLibrary,
    required this.onConfirm,
    required this.onCancel,
    this.duplicateCheck,
    this.albumLabel,
    this.onPickAlbum,
  });

  @override
  Widget build(BuildContext context) {
    final blocked = readOnly || noLibrary;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(summary.title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            _Fact(label: '保存先', value: libTitle),
            _Fact(label: '合計サイズ', value: summary.sizeText),
            const SizedBox(height: 8),
            for (final s in summary.preview) _PreviewRow(source: s),
            if (summary.more > 0)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text('ほか ${summary.more}件',
                    style: AppText.caption.copyWith(
                        color: AppColors.textDim)),
              ),
            ?duplicateCheck,
            if (albumLabel != null && onPickAlbum != null)
              ValueListenableBuilder<String>(
                valueListenable: albumLabel!,
                builder: (_, label, _) => InkWell(
                  onTap: blocked ? null : onPickAlbum,
                  child: _Fact(
                    label: 'アルバム',
                    value: label,
                    trailing: const Icon(Icons.chevron_right,
                        color: AppColors.textDim, size: 20),
                  ),
                ),
              ),
            if (blocked)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  readOnly
                      ? 'このライブラリは読み取り専用なので、アップロードできません。'
                      : '保存先のライブラリが見つかりません。接続先を確認してください。',
                  style: AppText.caption.copyWith(color: AppColors.danger),
                ),
              ),
            const SizedBox(height: 16),
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 52),
              child: FilledButton(
                onPressed: blocked ? null : onConfirm,
                child: const Text('アップロード'),
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: TextButton(
                  onPressed: onCancel, child: const Text('キャンセル')),
            ),
          ],
        ),
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  final String label;
  final String value;
  final Widget? trailing;
  const _Fact({required this.label, required this.value, this.trailing});

  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 32),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 4, right: 16),
              child: Text(label,
                  style: AppText.caption.copyWith(
                      color: AppColors.textDim)),
            ),
            Expanded(child: Text(value, style: AppText.body)),
            ?trailing,
          ],
        ),
      );
}

class _PreviewRow extends StatelessWidget {
  final UploadSource source;
  const _PreviewRow({required this.source});

  Widget _thumb() {
    const box = 44.0;
    final isImage = source.mime.startsWith('image/');
    Widget? img;
    if (isImage) {
      final bytes = source.bytes;
      final path = source.path;
      // 縮小して読む。原寸の写真を何枚も展開すると確認シートだけでメモリを食う
      if (bytes != null) {
        img = Image.memory(bytes,
            width: box, height: box, fit: BoxFit.cover, cacheWidth: 132);
      } else if (path != null && !kIsWeb) {
        img = Image.file(File(path),
            width: box, height: box, fit: BoxFit.cover, cacheWidth: 132);
      }
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.small),
      child: SizedBox(
        width: box,
        height: box,
        child: img ??
            ColoredBox(
              color: AppColors.surfaceHigh,
              child: Icon(
                source.mime.startsWith('video/')
                    ? Icons.play_circle_outline
                    : Icons.image_outlined,
                color: AppColors.textDim,
                size: 22,
              ),
            ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            _thumb(),
            const SizedBox(width: 12),
            Expanded(
              child: Text(source.name,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      );
}

/// シートで選んだアルバムの入れ先。既存の albumId か、作る名前のどちらか。
class _AlbumPick {
  String? albumId;
  String? newTitle;
  final label = ValueNotifier<String>('なし');
}

/// 一覧に出ない形式の元を一覧に出る形へ直す。直せん物はそのまま返し、
/// 呼び出し側の除外に任せる。
/// - HEIC/HEIF: 端末のデコーダで JPEG に変える。bytes が無い元は読み込んで変える
/// - 拡張子だけ欠けた名前: MIME から拡張子を足す（共有シート経由で名前が
///   来ない経路用）
/// 変換に失敗した物は触らず返す（落として誤った名前で上げる方が害がある）
/// [jpegConverter] はテストの差し替え口。既定は端末のデコーダ
Future<UploadSource> _toListableSource(
  UploadSource s,
  Future<Uint8List> Function(Uint8List bytes) jpegConverter,
) async {
  if (hasListedExtension(s.name)) return s;
  final isHeic = s.mime == 'image/heic' ||
      s.mime == 'image/heif' ||
      RegExp(r'\.(heic|heif)$', caseSensitive: false).hasMatch(s.name);
  if (isHeic) {
    final bytes = await _readAllBytes(s);
    if (bytes != null) {
      try {
        final jpg = await jpegConverter(bytes);
        final base = s.name.replaceFirst(
            RegExp(r'\.(heic|heif)$', caseSensitive: false), '');
        // メモリ(bytes)で渡すと転送キューが端末へ退避せず、再起動で未完了の
        // 送信が消える。reader で渡して普段どおり退避→台帳復旧に乗せる
        return UploadSource(
          name: '$base.jpg',
          size: jpg.length,
          mime: 'image/jpeg',
          reader: () => Stream.value(jpg),
        );
      } catch (_) {
        return s;
      }
    }
    return s;
  }
  if (!s.name.contains('.')) {
    final ext = extForMime(s.mime);
    if (ext != null) {
      return UploadSource(
        name: s.name + ext,
        size: s.size,
        mime: s.mime,
        path: s.path,
        bytes: s.bytes,
        reader: s.reader,
        sha256: s.sha256,
      );
    }
  }
  return s;
}

Future<Uint8List?> _readAllBytes(UploadSource s) async {
  if (s.bytes != null) return s.bytes;
  final path = s.path;
  if (path != null) {
    try {
      return await File(path).readAsBytes();
    } catch (_) {
      return null;
    }
  }
  final reader = s.reader;
  if (reader == null) return null;
  final builder = BytesBuilder(copy: false);
  try {
    await for (final chunk in reader()) {
      builder.add(chunk);
    }
  } catch (_) {
    return null;
  }
  return builder.takeBytes();
}

/// 確認シートを出し、「アップロード」を押された時だけ積む。積んだ件数を返す。
/// シートを開いた時点で重複の照合を裏で始め、同じ物はスキップを既定にする（#101）。
/// 「アルバム」の欄で入れ先を選べる（#102）。新規は確定時に1回だけ作る。
/// [hasher] はテストでどれを計算したか数えるための差し替え口。
/// [jpegConverter] はテストで HEIC→JPEG を差し替える口。既定は端末のデコーダ
Future<int> confirmAndUpload(
    BuildContext context, AppState app, String lib, List<UploadSource> sources,
    {UploadHasher? hasher,
    Future<Uint8List> Function(Uint8List bytes)? jpegConverter}) async {
  if (sources.isEmpty) return 0;
  // 一覧に出ない形式でも端末で直せる物は直して受け付ける。HEIC は iPhone の
  // 既定なので捨てるとアップロードが全部消える。直せん物だけ除く（#63・#164）
  // 原本保存が目的なので、既定(1920x1080)で掛かる上限を潰して縮小させない
  final convert = jpegConverter ??
      (bytes) => FlutterImageCompress.compressWithList(
          bytes,
          format: CompressFormat.jpeg,
          minWidth: 1 << 30,
          minHeight: 1 << 30);
  sources =
      await Future.wait(sources.map((s) => _toListableSource(s, convert)));
  if (!context.mounted) return 0;
  // 一覧が拾う拡張子以外は上げても一覧に一生出てこないので、確認の前に除く（#63）
  final rejected = sources.where((s) => !hasListedExtension(s.name)).length;
  if (rejected > 0) {
    sources = sources.where((s) => hasListedExtension(s.name)).toList();
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('一覧に出ない形式 $rejected件を除きました')));
    if (sources.isEmpty) return 0;
  }
  final libs = app.libraries;
  final found = libs.where((l) => l.id == lib).toList();
  final writable = found.isNotEmpty && !found.first.readOnly;
  final check = writable
      ? (UploadCheckController(
          sources,
          (cancelled) => runUploadCheck(
            check: app.api.checkObjects,
            lib: lib,
            sources: sources,
            hasher: hasher ?? hashUploadSource,
            cancelled: cancelled,
          ),
        )..start())
      : null;
  final pick = _AlbumPick();
  // 選択肢の一覧は1回だけ取り、欄の表示名の解決とダイアログで共用する
  final albums = writable ? writableAlbums(app.api, lib) : null;
  // シートを閉じた後に知らせるので、開く前の画面のものを掴んでおく
  final messenger = ScaffoldMessenger.maybeOf(context);
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surfaceHigh,
    builder: (ctx) => UploadConfirmContent(
      summary: summarizeUpload(sources),
      libTitle: found.isEmpty ? lib : found.first.title,
      readOnly: found.isNotEmpty && found.first.readOnly,
      noLibrary: found.isEmpty,
      onConfirm: () => Navigator.pop(ctx, true),
      onCancel: () => Navigator.pop(ctx, false),
      duplicateCheck: check == null ? null : UploadCheckPanel(controller: check),
      albumLabel: albums == null ? null : pick.label,
      onPickAlbum: albums == null
          ? null
          : () async {
              await showAlbumPicker(
                ctx,
                api: app.api,
                lib: lib,
                onPick: (albumId, newTitle) async {
                  pick.albumId = albumId;
                  pick.newTitle = newTitle;
                  pick.label.value = newTitle ??
                      (await albums)
                          .firstWhere((a) => a.id == albumId,
                              orElse: () =>
                                  const Album(id: '', title: '？', count: 0))
                          .title;
                },
              );
            },
    ),
  );
  try {
    if (ok == true) {
      // 新しいアルバムは「アップロード」を押した時に1回だけ作る
      var albumId = pick.albumId;
      if (albumId == null && pick.newTitle != null) {
        try {
          albumId = await app.api.albumCreate(lib, pick.newTitle!);
        } on Exception catch (e) {
          debugPrint('album create failed: $e');
          messenger?.showSnackBar(
              const SnackBar(content: Text('アルバムを作れませんでした。入れ先なしでアップロードします')));
        }
      }
      if (check == null) {
        return app.upload(lib, sources, albumId: albumId);
      }
      final picked = check.toUpload();
      final skipped = sources.length - picked.length;
      // 照合の途中で押された時は止めずに上げる。確かめていないことだけは伝える
      final msg = check.checking
          ? '重複の確認ができませんでした'
          : skipped > 0
              ? '同じ物 $skipped件をスキップしました'
              : null;
      if (msg != null) messenger?.showSnackBar(SnackBar(content: Text(msg)));
      if (picked.isEmpty) return 0;
      return app.upload(lib, picked, albumId: albumId);
    }
    return 0;
  } finally {
    check?.dispose();
    pick.label.dispose();
  }
}

/// 端末のピッカーで写真・動画を選ばせ、確認シートを経てアップロードに積む。
Future<int> pickAndConfirmUpload(
    BuildContext context, AppState app, String lib) async {
  // ピッカーから戻るのは端末上は「裏から復帰」なので、包まんと「毎回ロック」で選ぶたびにロックされる
  final files = await app
      .runExternal(() => FilePicker.pickFiles(type: FileType.media));
  if (files.isEmpty || !context.mounted) return 0;
  final sources = <UploadSource>[];
  for (final f in files) {
    final mime = uploadMimeFor(f.name);
    if (kIsWeb) {
      // Web は端末のファイル置き場が無いので、選んだ中身をそのまま持つ
      final bytes = await f.readAsBytes();
      sources.add(UploadSource(
          name: f.name, size: bytes.length, mime: mime, bytes: bytes));
      continue;
    }
    final path = f.path;
    sources.add(UploadSource(
      name: f.name,
      size: f.lengthSync() ?? await f.length() ?? 0,
      mime: mime,
      path: path,
      reader: path == null ? f.readAsByteStream : null,
    ));
  }
  if (!context.mounted) return 0;
  return confirmAndUpload(context, app, lib, sources);
}
