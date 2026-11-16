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
    for (final e in ['heic', 'heif', 'dng', 'bmp']) {
      expect(hasListedExtension('a.$e'), isFalse, reason: e);
    }
  });
}
