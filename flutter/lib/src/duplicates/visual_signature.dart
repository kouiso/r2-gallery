import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// 見た目の照合 "vs1" の Dart 版。正は worker/src/lib/similar/core.ts で、ここはそれにバイト単位で合わせる。
///
/// Web でも Android でも同じ画素から同じ署名を出すため、復号は package:image だけで行い
/// （Web ではエンジンの ImageDescriptor が使えない #58）、復号の後は整数演算だけにする。
/// Web の int は double なので、ビット演算は 2^32 未満の値にしか使わず、64 bit のハッシュはバイトで持つ。

const vs1SigBytes = 297;
const vs1FlagFlat = 1;
const vs1FlagFromOriginal = 2;
const vs1FlagMultiFrame = 4;

const _offP = 0;
const _offD = 8;
const _offM = 16;
const _offGrid = 24;
const _offColor = 280;
const _offW = 292;
const _offH = 294;
const _offFlags = 296;

/// C[u][x] = round(16384*cos((2x+1)*u*π/64))、u<8・x<32 を u ごとに並べた物。
/// 式から作らず core.ts と同じ定数を持つ: cos の最後の桁は実行系ごとに違い得るので、表を共有して揃える。
const vs1CosTable = <int>[
  16384, 16384, 16384, 16384, 16384, 16384, 16384, 16384, 16384, 16384, 16384, 16384, 16384, 16384,
  16384, 16384, 16384, 16384, 16384, 16384, 16384, 16384, 16384, 16384, 16384, 16384, 16384, 16384,
  16384, 16384, 16384, 16384, 16364, 16207, 15893, 15426, 14811, 14053, 13160, 12140, 11003, 9760,
  8423, 7005, 5520, 3981, 2404, 804, -804, -2404, -3981, -5520, -7005, -8423, -9760, -11003, -12140,
  -13160, -14053, -14811, -15426, -15893, -16207, -16364, 16305, 15679, 14449, 12665, 10394, 7723,
  4756, 1606, -1606, -4756, -7723, -10394, -12665, -14449, -15679, -16305, -16305, -15679, -14449,
  -12665, -10394, -7723, -4756, -1606, 1606, 4756, 7723, 10394, 12665, 14449, 15679, 16305, 16207,
  14811, 12140, 8423, 3981, -804, -5520, -9760, -13160, -15426, -16364, -15893, -14053, -11003,
  -7005, -2404, 2404, 7005, 11003, 14053, 15893, 16364, 15426, 13160, 9760, 5520, 804, -3981, -8423,
  -12140, -14811, -16207, 16069, 13623, 9102, 3196, -3196, -9102, -13623, -16069, -16069, -13623,
  -9102, -3196, 3196, 9102, 13623, 16069, 16069, 13623, 9102, 3196, -3196, -9102, -13623, -16069,
  -16069, -13623, -9102, -3196, 3196, 9102, 13623, 16069, 15893, 12140, 5520, -2404, -9760, -14811,
  -16364, -14053, -8423, -804, 7005, 13160, 16207, 15426, 11003, 3981, -3981, -11003, -15426,
  -16207, -13160, -7005, 804, 8423, 14053, 16364, 14811, 9760, 2404, -5520, -12140, -15893, 15679,
  10394, 1606, -7723, -14449, -16305, -12665, -4756, 4756, 12665, 16305, 14449, 7723, -1606, -10394,
  -15679, -15679, -10394, -1606, 7723, 14449, 16305, 12665, 4756, -4756, -12665, -16305, -14449,
  -7723, 1606, 10394, 15679, 15426, 8423, -2404, -12140, -16364, -13160, -3981, 7005, 14811, 15893,
  9760, -804, -11003, -16207, -14053, -5520, 5520, 14053, 16207, 11003, 804, -9760, -15893, -14811,
  -7005, 3981, 13160, 16364, 12140, 2404, -8423, -15426,
];

bool _isDim(int v) => v >= 1 && v <= 65535;

/// 箱平均の格子。割り振りは core.ts と同じ floor(x*GW/w)。元が格子より小さくて空いたマスは、
/// 対応する 1 画素を採る。和は大きな元画像だと 2^32 を超えるが、2^53 未満なので Web の double でも正確
Uint8List _boxGrid(Uint8List src, int ch, int w, int h, int gw, int gh) {
  final cells = gw * gh;
  final sums = List<int>.filled(cells * ch, 0);
  final counts = List<int>.filled(cells, 0);
  final colOf = List<int>.generate(w, (x) => (x * gw) ~/ w);
  var p = 0;
  for (var y = 0; y < h; y++) {
    final rowCell = ((y * gh) ~/ h) * gw;
    for (var x = 0; x < w; x++) {
      final cell = rowCell + colOf[x];
      counts[cell]++;
      final s = cell * ch;
      for (var c = 0; c < ch; c++) {
        sums[s + c] += src[p++];
      }
    }
  }
  final out = Uint8List(cells * ch);
  for (var cy = 0; cy < gh; cy++) {
    for (var cx = 0; cx < gw; cx++) {
      final cell = cy * gw + cx;
      final n = counts[cell];
      if (n > 0) {
        for (var c = 0; c < ch; c++) {
          out[cell * ch + c] = sums[cell * ch + c] ~/ n;
        }
      } else {
        final px = (cx * w) ~/ gw;
        final py = (cy * h) ~/ gh;
        final q = (py * w + px) * ch;
        for (var c = 0; c < ch; c++) {
          out[cell * ch + c] = src[q + c];
        }
      }
    }
  }
  return out;
}

/// 32x32 輝度の低周波 8x8 を整数の DCT で取り、中央値と比べる（imagehash と同じく DC 込み）。
/// 途中の値は 2^53 未満に収まるので、Web の double でも Android の int64 でも同じ値になる
Uint8List _pHashOf(Uint8List g32, bool mirror) {
  final r = List<int>.filled(8 * 32, 0);
  for (var u = 0; u < 8; u++) {
    for (var y = 0; y < 32; y++) {
      var s = 0;
      for (var x = 0; x < 32; x++) {
        s += vs1CosTable[u * 32 + x] * g32[y * 32 + (mirror ? 31 - x : x)];
      }
      r[u * 32 + y] = s;
    }
  }
  final d = List<int>.filled(64, 0);
  for (var v = 0; v < 8; v++) {
    for (var u = 0; u < 8; u++) {
      var s = 0;
      for (var y = 0; y < 32; y++) {
        s += vs1CosTable[v * 32 + y] * r[u * 32 + y];
      }
      d[v * 8 + u] = s;
    }
  }
  final sorted = [...d]..sort();
  // 中央値を 2 倍のまま比べて割り算を避ける（割ると Web と端末で丸めが分かれ得る）
  final m2 = sorted[31] + sorted[32];
  final out = Uint8List(8);
  for (var i = 0; i < 64; i++) {
    if (2 * d[i] > m2) out[i >> 3] |= 0x80 >> (i & 7);
  }
  return out;
}

Uint8List _dHashOf(Uint8List g98) {
  final out = Uint8List(8);
  for (var r = 0; r < 8; r++) {
    for (var c = 0; c < 8; c++) {
      final i = r * 8 + c;
      if (g98[r * 9 + c] > g98[r * 9 + c + 1]) out[i >> 3] |= 0x80 >> (i & 7);
    }
  }
  return out;
}

/// 標準偏差 6 未満を単色とみなす。単色同士はハッシュが偶然揃うので Worker は比べない
bool _isFlatGrid(Uint8List g32) {
  var s = 0;
  var q = 0;
  for (var i = 0; i < 1024; i++) {
    final v = g32[i];
    s += v;
    q += v * v;
  }
  return 1024 * q - s * s < 36 * 1024 * 1024;
}

/// 素の（乗算済みでない）RGBA から 297 バイトの署名を作る。EXIF の向きは呼ぶ側で直してから渡す。
/// [extraFlags] は [vs1FlagFromOriginal] / [vs1FlagMultiFrame] だけが効く（単色は中で決める）。
Uint8List vs1FromRgba(int w, int h, Uint8List rgba, [int extraFlags = 0]) {
  if (!_isDim(w) || !_isDim(h)) throw RangeError('vs1_bad_size');
  final n = w * h;
  if (rgba.length < n * 4) throw RangeError('vs1_short_rgba');
  final luma = Uint8List(n);
  final rgb = Uint8List(n * 3);
  for (var p = 0; p < n; p++) {
    final q = p * 4;
    var r = rgba[q];
    var g = rgba[q + 1];
    var b = rgba[q + 2];
    final a = rgba[q + 3];
    if (a != 255) {
      // 透過は白の上に置いてから見る。黒の上だと、透過 PNG と白地の JPEG が別物に見える
      final bg = 255 * (255 - a) + 127;
      r = (r * a + bg) ~/ 255;
      g = (g * a + bg) ~/ 255;
      b = (b * a + bg) ~/ 255;
    }
    rgb[p * 3] = r;
    rgb[p * 3 + 1] = g;
    rgb[p * 3 + 2] = b;
    luma[p] = (77 * r + 150 * g + 29 * b) >> 8;
  }
  final g32 = _boxGrid(luma, 1, w, h, 32, 32);
  final g98 = _boxGrid(luma, 1, w, h, 9, 8);
  final g16 = _boxGrid(luma, 1, w, h, 16, 16);
  final c22 = _boxGrid(rgb, 3, w, h, 2, 2);
  final out = Uint8List(vs1SigBytes);
  out.setAll(_offP, _pHashOf(g32, false));
  out.setAll(_offD, _dHashOf(g98));
  out.setAll(_offM, _pHashOf(g32, true));
  out.setAll(_offGrid, g16);
  out.setAll(_offColor, c22);
  out[_offW] = w >> 8;
  out[_offW + 1] = w & 255;
  out[_offH] = h >> 8;
  out[_offH + 1] = h & 255;
  out[_offFlags] = (_isFlatGrid(g32) ? vs1FlagFlat : 0) |
      (extraFlags & (vs1FlagFromOriginal | vs1FlagMultiFrame));
  return out;
}

/// Worker へ送る形（base64url、詰め物なし）。297 バイトは 3 の倍数なので、ちょうど 396 文字になる
String encodeVs1(Uint8List sig) => base64Url.encode(sig).replaceAll('=', '');

/// 画像ファイルのバイト列から署名を作る。読めない・寸法が範囲外なら null（呼ぶ側は decode の失敗として記録する）。
/// 端末では別 isolate で回す: 512px でも復号と格子づくりで数十 ms かかり、6 並列で画面が引っかかるため。
/// Web は isolate が使えないので同じ流れをそのまま回す。
Future<Uint8List?> vs1FromEncoded(Uint8List bytes,
    {bool fromOriginal = false}) async {
  final arg = (bytes: bytes, flags: fromOriginal ? vs1FlagFromOriginal : 0);
  if (kIsWeb) return _vs1FromEncodedSync(arg);
  return compute(_vs1FromEncodedSync, arg);
}

Uint8List? _vs1FromEncodedSync(({Uint8List bytes, int flags}) a) {
  try {
    final decoded = img.decodeImage(a.bytes);
    if (decoded == null || !decoded.isValid) return null;
    final multi = decoded.numFrames > 1;
    // 向きを直してから見る。sharp 側の .rotate() と同じ向きの画素にしないと、縦横が入れ替わった別物になる
    final baked = img.bakeOrientation(decoded);
    final rgba = _rgba8(baked);
    return vs1FromRgba(baked.width, baked.height, rgba,
        a.flags | (multi ? vs1FlagMultiFrame : 0));
  } on Object {
    // 壊れた画像・未対応形式・寸法が範囲外（RangeError）はまとめて「読めない」とする
    return null;
  }
}

/// 先頭の 1 コマを 8 bit の RGBA に揃える。パレット・16 bit・アルファ無しも同じ並びにしてから数える
Uint8List _rgba8(img.Image image) {
  final plain = image.format == img.Format.uint8 &&
      image.numChannels == 4 &&
      !image.hasPalette;
  final src = plain
      ? image
      : image.convert(
          format: img.Format.uint8, numChannels: 4, noAnimation: true);
  return src.getBytes(order: img.ChannelOrder.rgba);
}
