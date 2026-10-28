/// 表示用の整形。KMP版 Format.kt / Mime.kt と同じ規則。日付は grid/day_label.dart。
library;

/// サイズ表示。KMP 版と同じ二進接頭辞で、小数1桁は切り捨て（ゴミ箱の行・情報シートで共通）。
String formatBytes(int b) {
  const kb = 1024, mb = 1024 * 1024, gb = 1024 * 1024 * 1024;
  // 小数1桁は切り捨て（KMP版と同じ表示に揃える）
  if (b >= gb) return '${b * 10 ~/ gb ~/ 10}.${b * 10 ~/ gb % 10} GB';
  if (b >= mb) return '${b * 10 ~/ mb ~/ 10}.${b * 10 ~/ mb % 10} MB';
  if (b >= kb) return '${b ~/ kb} KB';
  return '$b B';
}

/// 拡張子から MIME。分からないものは octet-stream（端末への書き出しでは対象外にする）。
String mimeFor(String name) {
  var n = name;
  final q = n.indexOf('?');
  if (q >= 0) n = n.substring(0, q);
  final h = n.indexOf('#');
  if (h >= 0) n = n.substring(0, h);
  final dot = n.lastIndexOf('.');
  final ext = dot < 0 ? '' : n.substring(dot + 1).toLowerCase();
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
    default:
      return 'application/octet-stream';
  }
}
