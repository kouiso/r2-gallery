import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// サムネの長辺。worker は 512px 前提で保存する。
const _thumbLongEdge = 512;

/// 原本から縮小サムネ（長辺 512px の JPEG）を作る。作れなければ null。
///
/// 純 Dart の decodeImage は 12MP で ~48MB の RGBA を全部展開するうえ遅いので、
/// エンジンのコーデックに縮小サイズで decode させる（JPEG は DCT 縮小で原寸を作らずに済む）。
/// 縮小済みの小さな画素だけ別 isolate で JPEG に詰める。
Future<Uint8List?> makeImageThumb(Uint8List bytes) async {
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
    } finally {
      buffer.dispose();
    }
    final landscape = descriptor.width > descriptor.height;
    final longEdge = landscape ? descriptor.width : descriptor.height;
    // 小さい画像は拡大せず、そのままの寸法で詰める
    final shrink = longEdge > _thumbLongEdge;
    codec = await descriptor.instantiateCodec(
      targetWidth: shrink && landscape ? _thumbLongEdge : null,
      targetHeight: shrink && !landscape ? _thumbLongEdge : null,
    );
    image = (await codec.getNextFrame()).image;
    final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (rgba == null) return null;
    return await compute(
      _encodeJpg,
      (
        width: image.width,
        height: image.height,
        rgba: rgba.buffer.asUint8List(rgba.offsetInBytes, rgba.lengthInBytes),
      ),
    );
  } on Exception {
    // 壊れた画像や未対応形式はサムネ無しとして扱う（呼び出し側は null を作らない扱いにしている）
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
  }
}

Uint8List _encodeJpg(({int width, int height, Uint8List rgba}) a) {
  final image = img.Image.fromBytes(
    width: a.width,
    height: a.height,
    bytes: a.rgba.buffer,
    bytesOffset: a.rgba.offsetInBytes,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  return Uint8List.fromList(img.encodeJpg(image, quality: 82));
}
