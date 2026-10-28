import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/upload/image_thumb.dart';

/// 送られた Content-Type を記録し、あらかじめ並べたステータスを順に返す。
class _ThumbAdapter implements HttpClientAdapter {
  _ThumbAdapter(this.statuses);
  final List<int> statuses;
  final List<String?> contentTypes = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    contentTypes.add(
      options.headers['Content-Type']?.toString() ?? options.contentType,
    );
    final status = statuses[contentTypes.length - 1];
    return ResponseBody.fromString(
      jsonEncode({'ok': true}),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

(ApiClient, _ThumbAdapter) _client(List<int> statuses) {
  final adapter = _ThumbAdapter(statuses);
  final api = ApiClient(dio: Dio()..httpClientAdapter = adapter)
    ..setConnection(const Connection('https://w.example', 'tk'));
  return (api, adapter);
}

final _jpeg = Uint8List.fromList([
  0xFF,
  0xD8,
  0xFF,
  0xE0,
  0,
  0x10,
  0x4A,
  0x46,
  0x49,
]);
final _webp = Uint8List.fromList([
  ...ascii.encode('RIFF'),
  4,
  0,
  0,
  0,
  ...ascii.encode('WEBPVP8 '),
]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('サムネの表記は中身から決める', () {
    expect(thumbContentType(_jpeg), 'image/jpeg');
    expect(thumbContentType(_webp), 'image/webp');
    expect(
      thumbContentType(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47])),
      'application/octet-stream',
    );
  });

  test('画像サムネ（makeImageThumb の出力）は image/jpeg で送る', () async {
    final src = img.Image(width: 900, height: 600);
    img.fill(src, color: img.ColorRgb8(10, 120, 200));
    final thumb = await makeImageThumb(Uint8List.fromList(img.encodePng(src)));
    final (api, adapter) = _client([201]);
    await api.putThumb('review', 'a.png', thumb!);
    expect(adapter.contentTypes, ['image/jpeg']);
  });

  test('動画サムネの WEBP は image/webp で送る', () async {
    final (api, adapter) = _client([201]);
    await api.putThumb('review', 'a.mp4', _webp);
    expect(adapter.contentTypes, ['image/webp']);
  });

  test('JPEG を受けん前の worker に 415 で断られたら、従来の webp 表記で送り直す', () async {
    final (api, adapter) = _client([415, 201]);
    await api.putThumb('review', 'a.jpg', _jpeg);
    expect(adapter.contentTypes, ['image/jpeg', 'image/webp']);
  });

  test('WEBP が 415 で断られたら送り直さず失敗にする', () async {
    final (api, adapter) = _client([415, 201]);
    await expectLater(
      api.putThumb('review', 'a.mp4', _webp),
      throwsA(isA<ApiError>()),
    );
    expect(adapter.contentTypes, ['image/webp']);
  });
}
