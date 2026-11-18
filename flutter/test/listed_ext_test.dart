import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/webdl/listed_ext.g.dart';
import 'package:r2_gallery/src/webdl/media_name.dart';

void main() {
  test('生成表の全拡張子を一覧に出る名前として扱う', () {
    for (final e in [...listedImageExt, ...listedVideoExt]) {
      expect(hasListedExtension('a.$e'), isTrue, reason: e);
      expect(hasListedExtension('A.${e.toUpperCase()}'), isTrue, reason: e);
    }
  });

  test('表に無い形式は一覧に出ない名前として扱う', () {
    for (final e in ['dng', 'tiff', 'raw', 'svg']) {
      expect(hasListedExtension('a.$e'), isFalse, reason: e);
    }
  });

  test('HEIC・HEIF・BMP は一覧に出る名前として扱う', () {
    expect(hasListedExtension('IMG_1.heic'), isTrue);
    expect(hasListedExtension('a.HEIF'), isTrue);
    expect(hasListedExtension('scan.bmp'), isTrue);
    expect(normalizeUploadName('IMG_1.HEIC', 'image/heic'), 'IMG_1.HEIC');
    expect(normalizeUploadName('photo', 'image/heic'), 'photo.heic');
    expect(normalizeUploadName('photo', 'image/bmp'), 'photo.bmp');
  });
}
