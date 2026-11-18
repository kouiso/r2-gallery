/// 取り込んだファイルの名前と MIME の整え方。KMP 版 TransferQueue.kt の
/// normalizeUploadName / extForMime / suffixed と files/Mime.kt に対応する。
library;

import 'listed_ext.g.dart';

// 一覧が拾う拡張子の表は worker/src/lib/media-ext.json が元（listed_ext.g.dart は生成物）。
// この拡張子で終わらんキーはアップロードできても一覧に一生出てこない
final _listedExt = RegExp(
  '\\.(${[...listedImageExt, ...listedVideoExt].join('|')})\$',
  caseSensitive: false,
);

/// ギャラリーの一覧に出る名前か。
bool hasListedExtension(String name) => _listedExt.hasMatch(name);

String? extForMime(String mime) {
  switch (mime.toLowerCase().split(';').first.trim()) {
    case 'image/jpeg':
      return '.jpg';
    case 'image/png':
      return '.png';
    case 'image/webp':
      return '.webp';
    case 'image/gif':
      return '.gif';
    case 'image/avif':
      return '.avif';
    case 'image/heic':
      return '.heic';
    case 'image/heif':
      return '.heif';
    case 'image/bmp':
      return '.bmp';
    case 'video/mp4':
      return '.mp4';
    case 'video/webm':
      return '.webm';
    case 'video/quicktime':
      return '.mov';
    case 'video/x-m4v':
      return '.m4v';
    case 'video/x-matroska':
      return '.mkv';
    case 'video/mp2t':
      return '.ts';
    case 'video/mpeg':
      return '.mpg';
    case 'video/x-msvideo':
      return '.avi';
    case 'video/x-flv':
      return '.flv';
    case 'video/3gpp':
      return '.3gp';
    case 'video/x-ms-wmv':
      return '.wmv';
  }
  return null;
}

/// 拡張子から MIME を引く。分からなければ octet-stream。
String mimeForName(String name) {
  var n = name;
  for (final c in ['?', '#']) {
    final i = n.indexOf(c);
    if (i >= 0) n = n.substring(0, i);
  }
  final dot = n.lastIndexOf('.');
  return _mimeForExt(dot < 0 ? '' : n.substring(dot + 1).toLowerCase());
}

/// ? と # で切らない版。端末から上げる名前用（URL 用の飾り切り落としはしない）。
String mimeForDeviceName(String name) {
  final dot = name.lastIndexOf('.');
  return _mimeForExt(dot < 0 ? '' : name.substring(dot + 1).toLowerCase());
}

String _mimeForExt(String ext) {
  switch (ext) {
    case 'mp4':
    case 'm4v':
      return 'video/mp4';
    case 'webm':
      return 'video/webm';
    case 'mkv':
      return 'video/x-matroska';
    case 'mov':
      return 'video/quicktime';
    case 'ts':
      return 'video/mp2t';
    case 'mp3':
      return 'audio/mpeg';
    case 'm4a':
    case 'aac':
      return 'audio/aac';
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'png':
      return 'image/png';
    case 'webp':
      return 'image/webp';
    case 'gif':
      return 'image/gif';
    case 'avif':
      return 'image/avif';
    case 'heic':
      return 'image/heic';
    case 'heif':
      return 'image/heif';
    case 'bmp':
      return 'image/bmp';
  }
  return 'application/octet-stream';
}

/// 一覧は拡張子でメディアを拾うので、拡張子の無い名前は見えないまま保存されてしまう。
/// URL の飾りを落とし、足りなければ MIME から拡張子を借りる。
String normalizeUploadName(String displayName, String mime) {
  var clean = displayName;
  for (final c in ['?', '#']) {
    final i = clean.indexOf(c);
    if (i >= 0) clean = clean.substring(0, i);
  }
  clean = clean.substring(clean.lastIndexOf('/') + 1).trim();
  if (hasListedExtension(clean)) return clean;
  final base = clean.isEmpty ? 'upload' : clean;
  final ext = extForMime(mime);
  if (ext == null) return base;
  final dot = base.lastIndexOf('.');
  return (dot < 0 ? base : base.substring(0, dot)) + ext;
}

/// 端末から上げる時の名前。URL 用と違い ? と # で切らない。
/// / の後ろを取る・前後の空白を落とす・MIME から拡張子を借りる所は normalizeUploadName と同じ。
String normalizeDeviceName(String name, String mime) {
  var clean =
      name.substring(name.lastIndexOf('/') + 1).trim();
  if (hasListedExtension(clean)) return clean;
  final base = clean.isEmpty ? 'upload' : clean;
  final ext = extForMime(mime);
  if (ext == null) return base;
  final dot = base.lastIndexOf('.');
  return (dot < 0 ? base : base.substring(0, dot)) + ext;
}



/// 上げた後にギャラリーの一覧に出るか。hasListedExtension(normalizeDeviceName(name, mime))。
bool isListedUpload(String name, String mime) =>
    hasListedExtension(normalizeDeviceName(name, mime));

/// 同名キーが既にある時の候補名。`name.mp4` → `name (2).mp4`。
String suffixedName(String name, int n) {
  if (n <= 1) return name;
  final dot = name.lastIndexOf('.');
  return dot > 0
      ? '${name.substring(0, dot)} ($n)${name.substring(dot)}'
      : '$name ($n)';
}
