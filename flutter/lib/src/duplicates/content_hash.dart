import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../transfer/transfer_queue.dart';

/// 中身の SHA-256 を16進で返す関数。テストで差し替えて、どれを計算したかを数えるための口。
typedef UploadHasher = Future<String> Function(UploadSource source);

/// Web でメモリ上のバイト列を区切る大きさ。区切りごとに画面へ順番を返し、数百MBでも固まらせない。
const hashChunkBytes = 1024 * 1024;

/// ストリームを流しながら計算する。大きい動画を丸ごとメモリへ載せないため。
Future<String> sha256OfStream(Stream<List<int>> data) async =>
    (await sha256.bind(data).first).toString();

/// メモリ上のバイト列。[chunk] ごとに区切って足し、合間に一度待つ（Web は別スレッドが使えない）。
Future<String> sha256OfBytes(Uint8List bytes,
    {int chunk = hashChunkBytes}) async {
  final out = _DigestSink();
  final input = sha256.startChunkedConversion(out);
  for (var i = 0; i < bytes.length; i += chunk) {
    final end = i + chunk > bytes.length ? bytes.length : i + chunk;
    input.add(Uint8List.sublistView(bytes, i, end));
    if (end < bytes.length) await Future<void>.delayed(Duration.zero);
  }
  input.close();
  return out.value.toString();
}

Future<String> _hashPath(String path) => sha256OfStream(File(path).openRead());

/// 選んだファイルの中身のハッシュ。端末のパスは別の isolate で読み、画面の描画を止めない。
/// content:// などの読み口は関数を isolate へ渡せないので、こちらでストリームのまま読む。
Future<String> hashUploadSource(UploadSource s) async {
  final bytes = s.bytes;
  if (bytes != null) return sha256OfBytes(bytes);
  final path = s.path;
  if (path != null && !kIsWeb) return compute(_hashPath, path);
  final reader = s.reader;
  if (reader != null) return sha256OfStream(reader());
  throw const FileSystemException('読み込めるファイルがありません');
}

class _DigestSink implements Sink<Digest> {
  Digest? _value;
  Digest get value => _value!;
  @override
  void add(Digest data) => _value = data;
  @override
  void close() {}
}

