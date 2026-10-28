import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:get_thumbnail_video/index.dart';
import 'package:get_thumbnail_video/video_thumbnail.dart';

import 'image_thumb.dart';

/// 動画の先頭付近の1コマを縮小webpにする。KMP 版と同じく署名URLや端末内のファイルから端末側で抜くので動画を丸ごと落とさない
Future<Uint8List?> videoThumb(String urlOrPath) async {
  if (kIsWeb) return null;
  final data = await VideoThumbnail.thumbnailData(
    video: urlOrPath,
    imageFormat: ImageFormat.WEBP,
    maxWidth: 512,
    timeMs: 1000,
    quality: 75,
  );
  return data.isEmpty ? null : data;
}

/// ネットから取り込んで端末に置いたファイルのサムネ。動画は端末のファイルから1コマ抜き、
/// 画像は丸ごと decode するので大きすぎるものは諦める（一覧のバックフィルが後で補う）。
Future<Uint8List?> thumbFromFile(File file, String mime) async {
  if (kIsWeb) return null;
  if (mime.startsWith('video/')) return videoThumb(file.path);
  if (!mime.startsWith('image/')) return null;
  if (await file.length() > 32 * 1024 * 1024) return null;
  return makeImageThumb(await file.readAsBytes());
}
