import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';

/// 呼ばれたメソッドを記録し、あらかじめ並べた応答（例外 or ステータス）を順に返す。
class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this.script);
  final List<Object> script;
  final List<String> methods = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    methods.add(options.method);
    final step = script.length >= methods.length
        ? script[methods.length - 1]
        : script.last;
    if (step is int) {
      return ResponseBody.fromString(
        jsonEncode({'libraries': <Object>[]}),
        step,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    throw DioException.connectionError(
        requestOptions: options, reason: 'boom');
  }

  @override
  void close({bool force = false}) {}
}

const _fail = 'connection-error';

(ApiClient, _ScriptedAdapter) _client(List<Object> script) {
  final adapter = _ScriptedAdapter(script);
  final dio = Dio()..httpClientAdapter = adapter;
  final api = ApiClient(dio: dio, retryDelay: Duration.zero)
    ..setConnection(const Connection('https://w.example', 'tk'));
  return (api, adapter);
}

void main() {
  test('GET は接続エラーを 2 回まで再試行して、通れば成功にする', () async {
    final (api, adapter) = _client([_fail, _fail, 200]);
    final libs = await api.libraries();
    expect(libs, isEmpty);
    expect(adapter.methods, ['GET', 'GET', 'GET']);
  });

  test('GET は 2 回再試行してもだめなら ApiError で返す（それ以上は粘らない）', () async {
    final (api, adapter) = _client([_fail]);
    await expectLater(api.libraries(), throwsA(isA<ApiError>()));
    expect(adapter.methods.length, 3);
  });

  test('GET は 5xx も再試行する', () async {
    final (api, adapter) = _client([503, 200]);
    await api.libraries();
    expect(adapter.methods.length, 2);
  });

  test('GET でも 4xx は再試行しない', () async {
    final (api, adapter) = _client([404, 200]);
    await expectLater(api.libraries(), throwsA(isA<ApiError>()));
    expect(adapter.methods.length, 1);
  });

  test('POST は接続エラーでも再試行しない（二重実行になり得る）', () async {
    final (api, adapter) = _client([_fail, 200]);
    await expectLater(api.trash('review', 'a.jpg'), throwsA(isA<ApiError>()));
    expect(adapter.methods, ['POST']);
  });

  test('PUT は接続エラー・5xx のどちらでも再試行しない（ストリーム本文は再送できない）', () async {
    final (api, adapter) = _client([_fail, 200]);
    await expectLater(
        api.putThumb('review', 'a.jpg', Uint8List.fromList([1, 2, 3])),
        throwsA(isA<ApiError>()));
    final (api2, adapter2) = _client([503, 200]);
    await expectLater(
        api2.putObject('review', 'a.jpg', Uint8List.fromList([1, 2, 3]),
            'image/jpeg'),
        throwsA(isA<ApiError>()));
    expect(adapter.methods, ['PUT']);
    expect(adapter2.methods, ['PUT']);
  });
}
