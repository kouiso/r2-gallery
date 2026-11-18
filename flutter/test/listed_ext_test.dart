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

  test('isListedUpload はキューが付ける名前で決める', () {
    // 拡張子が無く MIME で分かる物は止めない（キューが拡張子を付ける）
    expect(isListedUpload('photo', 'image/jpeg'), isTrue);
    // 拡張子も MIME も分からない物は止める
    expect(isListedUpload('photo', 'application/octet-stream'), isFalse);
    expect(isListedUpload('a.dng', 'image/x-adobe-dng'), isFalse);
  });

  test('端末の名前は # と ? を含んでもそのまま・拡張子から MIME になる', () {
    expect(normalizeDeviceName('夏 #1.jpg', 'image/jpeg'), '夏 #1.jpg');
    expect(normalizeDeviceName('写真?.png', 'image/png'), '写真?.png');
    expect(mimeForDeviceName('夏 #1.jpg'), 'image/jpeg');
    // / の後ろを取る・MIME から拡張子を借りる所は URL 用と同じ
    expect(normalizeDeviceName('a/b/c.heic', 'image/heic'), 'c.heic');
    expect(normalizeDeviceName('photo', 'image/heic'), 'photo.heic');
  });
}
