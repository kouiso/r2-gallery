import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:r2_gallery/src/upload/image_thumb.dart';

Uint8List _png(int w, int h) {
  final image = img.Image(width: w, height: h);
  img.fill(image, color: img.ColorRgb8(200, 80, 40));
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<img.Image> thumbOf(Uint8List src) async {
    final out = await makeImageThumb(src);
    expect(out, isNotNull);
    final decoded = img.decodeJpg(out!);
    expect(decoded, isNotNull);
    return decoded!;
  }

  test('横長は長辺 512px に縮めて JPEG にする', () async {
    final t = await thumbOf(_png(2000, 1000));
    expect((t.width, t.height), (512, 256));
  });

  test('縦長も長辺 512px に縮める', () async {
    final t = await thumbOf(_png(600, 1200));
    expect((t.width, t.height), (256, 512));
  });

  test('512px より小さい画像は拡大しない', () async {
    final t = await thumbOf(_png(200, 100));
    expect((t.width, t.height), (200, 100));
  });

  test('画像として読めないバイト列はサムネ無し（null）にする', () async {
    expect(await makeImageThumb(Uint8List.fromList([1, 2, 3, 4])), isNull);
  });
}
