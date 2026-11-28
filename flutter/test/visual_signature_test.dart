import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:r2_gallery/src/duplicates/visual_signature.dart';

/// vs1 の正解値。worker/src/lib/similar/core.test.ts の GOLDEN_VS1 をそのまま写した物で、
/// 同じ入力から Web・Android・Worker が同じバイト列を出すことの約束そのもの。
/// 値を変えてよいのは方式（alg）を上げる時だけ。片方だけ直すと保存済みの署名と合わなくなる。
const _golden = <String, Map<String, String>>{
  'V1': {
    'p': '80264b56ad3a755f',
    'd': '0000000001030204',
    'm': 'd5711f43f84f3106',
    'grid':
        '050b11171d232a30363c42484f555b610e151b21272d333a40464c52585f656b181e252b31373d434a50565c62686f7522282e353b41474d535a60666c72787f'
        '2c32383e454b51575d636a70767c8288363c42484e545b61676d737a80868c923f464c52585e646b71777d838a90969c494f565c62686e747b81878d9399a0a3'
        '53595f666c72787e848b91979da3a99a5d63696f767c82888e949ba1a7ada59c676d73797f868c92989ea4abb1b0a0a670777d83898f969ca2a8aeb4b8a6aab0'
        '7a80878d93999fa5acb2b8beafaeb4ba848a90979da3a9afb5bcc2bab1b7bec48e949aa0a7adb3b9bfc5c4b5bbc1c7cd989ea4aab0b7bdc3c9cdbbbfc5cbd1d7',
    'color': '3e3951be39b03eb199beb18d',
    'wh': '00400030',
    'flags': '00',
  },
  'V2': {
    'p': '83162d740d0ef2fb',
    'd': '181c6708286328ac',
    'm': 'd6537801585ba76d',
    'grid':
        '333d696a879cacaf895e5a8e798e97b445505469aeadbd9793606c7f829c9abc62565e51bbcaaa9a8b80648179bfc0ab7a9894b8717a685da79bb4c7a071806c'
        '919aa4a8697d687a95abb9bda27b7f93acad80989aa2743fc0cac4a7a288802d4a458082a3bba6c9a86e81948b7ca6b1575f6c80c3c4a7bcae5d7769929bacad'
        '67896966c7e7a1aea46c81717da3de9a837e939bb59a889cb37b917fa296ab879e9cd0ca7273719d9295d3b6bc3d8b82b6b9a2afaa69666097b4c594b2808b52'
        '517d8a95ab9fb0ca7d5fa0838e80a2bb6c666f8ec59ea9ba9f77945982b5acae888d807cc8b3a9bf85906f6b78b2c1b88b6a8b7de793acbd8b8d4b6b8acdb5ae',
    'color': '7b93539492839d9486929494',
    'wh': '00250017',
    'flags': '00',
  },
  'V3': {
    'p': 'aaaaaaaaaaaaaaaa',
    'd': '0000190000191900',
    'm': 'd515555555555555',
    'grid':
        '1de61de61ee51ee51ee51ee61de61de6976c976c976c976c976c976c976c976cc142c142c142c142c142c142c142c1421de61de61ee51ee51ee51ee61de61de6'
        'ba49ba49ba49ba49ba49ba49ba49ba499d669d669d669d669d669d669d669d661de61de61ee51ee51ee51ee61de61de6dc27dc27dc26dd26dd27dc27dc27dc27'
        '7d867d867d867d867d867d867d867d8637cc38cb38cb38cb38cb38cb37cc37cce51ee51ee61de61de61de61ee51ee51e5aa95aa95aa95ba85aa95aa95aa95aa9'
        '5aa95aa95aa95ba85aa95aa95aa95aa9e51ee51ee61de61de61de61ee51ee51e37cc38cb38cb38cb38cb38cb37cc37cc788b788b788a798a798b788b788b788b',
    'color': '818181828282818181828282',
    'wh': '0200016a',
    'flags': '00',
  },
  'V4': {
    'p': '8000000000000000',
    'd': '0000000000000000',
    'm': '8000000000000000',
    'grid':
        '80808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080'
        '80808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080'
        '80808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080'
        '80808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080808080',
    'color': '808080808080808080808080',
    'wh': '00640064',
    'flags': '01',
  },
};

String _goldenHex(String name) {
  final g = _golden[name]!;
  return g['p']! +
      g['d']! +
      g['m']! +
      g['grid']! +
      g['color']! +
      g['wh']! +
      g['flags']!;
}

typedef _Px = List<int>;

Uint8List _rgbaOf(int w, int h, _Px Function(int x, int y) f) {
  final b = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      b.setAll((y * w + x) * 4, f(x, y));
    }
  }
  return b;
}

// 仕様の表の式そのまま（core.test.ts の VECTORS と同じ）
final _vectors = <String, (int, int, Uint8List) Function()>{
  'V1': () => (
    64,
    48,
    _rgbaOf(
      64,
      48,
      (x, y) => [(4 * x) & 255, (5 * y) & 255, (3 * (x + y)) & 255, 255],
    ),
  ),
  'V2': () => (
    37,
    23,
    _rgbaOf(
      37,
      23,
      (x, y) => [
        (x * x + 7 * y) % 256,
        ((13 * x) ^ (29 * y)) & 255,
        (x * y) % 256,
        (x + y) % 3 == 0 ? 128 : 255,
      ],
    ),
  ),
  'V3': () => (
    512,
    362,
    _rgbaOf(512, 362, (x, y) {
      final v = (((x >> 5) + (y >> 5)) & 1) == 1 ? 230 : 30;
      final c = v + (x % 7) - 3;
      return [c, c, c, 255];
    }),
  ),
  'V4': () => (100, 100, _rgbaOf(100, 100, (_, _) => [128, 128, 128, 255])),
};

String _hex(Uint8List b) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();

int _pop8(int v) {
  var n = 0;
  for (var x = v; x != 0; x &= x - 1) {
    n++;
  }
  return n;
}

/// 8 バイトのハッシュ同士の距離。[oa]/[ob] は署名の中の位置（p=0, d=8, m=16）
int _ham(Uint8List a, int oa, Uint8List b, int ob) {
  var n = 0;
  for (var i = 0; i < 8; i++) {
    n += _pop8(a[oa + i] ^ b[ob + i]);
  }
  return n;
}

img.Image _imageOf(int w, int h, Uint8List rgba) => img.Image.fromBytes(
  width: w,
  height: h,
  bytes: rgba.buffer,
  numChannels: 4,
  order: img.ChannelOrder.rgba,
);

Uint8List _rgbaOfImage(img.Image i) => i
    .convert(format: img.Format.uint8, numChannels: 4)
    .getBytes(order: img.ChannelOrder.rgba);

/// worker 側のファイル。Flutter だけを持ち出した環境と、ファイルを読めない Web（--platform chrome で
/// double の int を確かめる時）では無いので、その時は照合を飛ばす
String? _workerSource(String rel) {
  if (kIsWeb) return null;
  final f = File('../worker/src/lib/similar/$rel');
  return f.existsSync() ? f.readAsStringSync() : null;
}

void main() {
  group('vs1FromRgba', () {
    for (final name in _golden.keys) {
      test('$name は W1 の正解バイト列と一致する', () {
        final (w, h, rgba) = _vectors[name]!();
        final sig = vs1FromRgba(w, h, rgba);
        expect(sig.length, vs1SigBytes);
        expect(_hex(sig), _goldenHex(name));
      });
    }

    test('単色の V4 だけに flat が立つ', () {
      for (final name in _golden.keys) {
        final (w, h, rgba) = _vectors[name]!();
        expect(
          vs1FromRgba(w, h, rgba)[296] & vs1FlagFlat,
          name == 'V4' ? vs1FlagFlat : 0,
        );
      }
    });

    test('呼ぶ側の印は fromOriginal と multiFrame だけを足す', () {
      final (w, h, rgba) = _vectors['V1']!();
      final sig = vs1FromRgba(
        w,
        h,
        rgba,
        vs1FlagFromOriginal | vs1FlagMultiFrame | vs1FlagFlat | 0xf0,
      );
      expect(sig[296], vs1FlagFromOriginal | vs1FlagMultiFrame);
      expect(_hex(sig.sublist(0, 296)), _goldenHex('V1').substring(0, 592));
    });

    test('範囲外の寸法と足りない画素は弾く', () {
      expect(() => vs1FromRgba(0, 10, Uint8List(0)), throwsRangeError);
      expect(
        () => vs1FromRgba(65536, 1, Uint8List(65536 * 4)),
        throwsRangeError,
      );
      expect(() => vs1FromRgba(4, 4, Uint8List(63)), throwsRangeError);
    });

    test('base64url の 396 文字で送る', () {
      final s = encodeVs1(vs1FromRgba(64, 48, _vectors['V1']!().$3));
      expect(s.length, 396);
      expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(s), isTrue);
    });
  });

  group('COS 表', () {
    test('round(16384*cos((2x+1)uπ/64)) と一致する', () {
      expect(vs1CosTable.length, 256);
      for (var u = 0; u < 8; u++) {
        for (var x = 0; x < 32; x++) {
          expect(
            vs1CosTable[u * 32 + x],
            (16384 * math.cos((2 * x + 1) * u * math.pi / 64)).round(),
            reason: 'u=$u x=$x',
          );
        }
      }
    });

    test('core.ts の COS_TABLE と同じ並び', () {
      final src = _workerSource('core.ts');
      if (src == null) {
        markTestSkipped('worker のソースが無い');
        return;
      }
      final m = RegExp(
        r'COS_TABLE[^=]*=\s*Object\.freeze\(\[([-\d,\s]+)\]',
      ).firstMatch(src);
      expect(m, isNotNull);
      final ts = m!
          .group(1)!
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .map(int.parse)
          .toList();
      expect(ts, vs1CosTable);
    });

    test('core.test.ts の正解値と同じ 16 進を持つ', () {
      final src = _workerSource('core.test.ts');
      if (src == null) {
        markTestSkipped('worker のソースが無い');
        return;
      }
      for (final name in _golden.keys) {
        final block = RegExp('$name: \\{([^}]*)\\}').firstMatch(src);
        expect(block, isNotNull, reason: name);
        final hexes = RegExp(
          r'"([0-9a-f]+)"',
        ).allMatches(block!.group(1)!).map((m) => m.group(1)!).join();
        expect(hexes, _goldenHex(name), reason: name);
      }
    });
  });

  group('vs1FromEncoded', () {
    test('PNG を通しても画素が同じなら正解値と同じ（V1, V2 の透過込み）', () async {
      for (final name in ['V1', 'V2']) {
        final (w, h, rgba) = _vectors[name]!();
        final png = img.encodePng(_imageOf(w, h, rgba));
        final sig = await vs1FromEncoded(png);
        expect(_hex(sig!), _goldenHex(name), reason: name);
      }
    });

    test('JPEG q82 を通した V3 は pHash 2 以内', () async {
      final (w, h, rgba) = _vectors['V3']!();
      final base = vs1FromRgba(w, h, rgba);
      final jpg = img.encodeJpg(_imageOf(w, h, rgba), quality: 82);
      final decoded = img.decodeImage(jpg)!;
      final viaRgba = vs1FromRgba(
        decoded.width,
        decoded.height,
        _rgbaOfImage(decoded),
      );
      expect(_ham(base, 0, viaRgba, 0), lessThanOrEqualTo(2));
      final viaEncoded = await vs1FromEncoded(jpg);
      expect(_ham(base, 0, viaEncoded!, 0), lessThanOrEqualTo(2));
    });

    test('半分に縮めても pHash 4 以内', () async {
      final (w, h, rgba) = _vectors['V3']!();
      final base = vs1FromRgba(w, h, rgba);
      final half = img.copyResize(
        _imageOf(w, h, rgba),
        width: w ~/ 2,
        interpolation: img.Interpolation.average,
      );
      final sig = vs1FromRgba(half.width, half.height, _rgbaOfImage(half));
      expect(_ham(base, 0, sig, 0), lessThanOrEqualTo(4));
    });

    test('左右反転した物の p は元の m と 4 以内', () async {
      // 左右で形が違う絵でないと、反転しても p が揃って確かめにならない
      final (w, h, rgba) = (
        200,
        150,
        _rgbaOf(200, 150, (x, y) {
          final v = x < 60 ? 220 : ((x * 3 + y) & 255);
          return [v, (v + y) & 255, 255 - v, 255];
        }),
      );
      final base = vs1FromRgba(w, h, rgba);
      final flipped = img.flipHorizontal(
        _imageOf(w, h, Uint8List.fromList(rgba)),
      );
      final png = img.encodePng(flipped);
      final sig = await vs1FromEncoded(png);
      expect(_ham(sig!, 0, base, 16), lessThanOrEqualTo(4));
      expect(_ham(sig, 0, base, 0), greaterThan(10));
    });

    test('単色は flat、原本から作った物は fromOriginal が立つ', () async {
      final (w, h, rgba) = _vectors['V4']!();
      final png = img.encodePng(_imageOf(w, h, rgba));
      final sig = await vs1FromEncoded(png, fromOriginal: true);
      expect(sig![296], vs1FlagFlat | vs1FlagFromOriginal);
      final plain = await vs1FromEncoded(png);
      expect(plain![296], vs1FlagFlat);
    });

    test('動く画像は先頭の 1 コマで作り multiFrame を立てる', () async {
      final (w, h, rgba) = _vectors['V1']!();
      final first = _imageOf(w, h, rgba);
      final anim = img.Image.from(first)
        ..addFrame(img.Image(width: w, height: h));
      final sig = await vs1FromEncoded(img.encodeGif(anim));
      final still = await vs1FromEncoded(img.encodeGif(first));
      expect(sig![296] & vs1FlagMultiFrame, vs1FlagMultiFrame);
      expect(still![296] & vs1FlagMultiFrame, 0);
      // 2 コマ目（真っ黒）は混ぜず、1 コマだけの時と同じ見た目になる
      expect(_hex(sig.sublist(0, 296)), _hex(still.sublist(0, 296)));
    });

    test('EXIF の向きを直してから作る', () async {
      final (w, h, rgba) = _vectors['V1']!();
      final image = _imageOf(w, h, rgba);
      image.exif.imageIfd.orientation = 6;
      final jpg = img.encodeJpg(image, quality: 95);
      final sig = await vs1FromEncoded(jpg);
      // 90 度回すので幅と高さが入れ替わる
      expect(_hex(sig!.sublist(292, 296)), '00300040');
    });

    test('画像でないバイト列は null', () async {
      expect(await vs1FromEncoded(Uint8List.fromList([1, 2, 3, 4])), isNull);
    });
  });
}
