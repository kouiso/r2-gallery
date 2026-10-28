import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../state/app_state.dart';
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
  const UploadConfirmContent({
    super.key,
    required this.summary,
    required this.libTitle,
    required this.readOnly,
    required this.noLibrary,
    required this.onConfirm,
    required this.onCancel,
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
                    style: const TextStyle(
                        color: AppColors.textDim, fontSize: 12)),
              ),
            if (blocked)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  readOnly
                      ? 'このライブラリは読み取り専用なので、アップロードできません。'
                      : '保存先のライブラリが見つかりません。接続先を確認してください。',
                  style:
                      const TextStyle(color: AppColors.danger, fontSize: 13),
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
  const _Fact({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 32),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 4, right: 16),
              child: Text(label,
                  style:
                      const TextStyle(color: AppColors.textDim, fontSize: 12)),
            ),
            Expanded(child: Text(value, style: const TextStyle(fontSize: 16))),
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
      borderRadius: BorderRadius.circular(8),
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

/// 確認シートを出し、「アップロード」を押された時だけ積む。積んだ件数を返す。
Future<int> confirmAndUpload(
    BuildContext context, AppState app, String lib, List<UploadSource> sources) async {
  if (sources.isEmpty) return 0;
  final libs = app.libraries;
  final found = libs.where((l) => l.id == lib).toList();
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
    ),
  );
  if (ok != true) return 0;
  return app.upload(lib, sources);
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
