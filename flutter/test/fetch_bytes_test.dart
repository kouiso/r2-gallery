import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';

/// 大きい応答を1MiBの断片で返す口。実際に流れた量を数えて、
/// 上限で切った時に後ろを読み続けない事を確かめる
class _BigBodyAdapter implements HttpClientAdapter {
  _BigBodyAdapter({this.declareLength = true});

  final bool declareLength;
  int emitted = 0;

  static const chunk = 1024 * 1024;
  static const total = 40 * chunk;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    Stream<Uint8List> body() async* {
      var sent = 0;
      while (sent < total) {
        sent += chunk;
        emitted = sent;
        yield Uint8List(chunk);
        // 読み手が切る隙を作るため少しずつ流す
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    }

    return ResponseBody(
      body(),
      200,
      headers: {
        if (declareLength) Headers.contentLengthHeader: ['$total'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _SmallBodyAdapter implements HttpClientAdapter {
  _SmallBodyAdapter(this.body);
  final Uint8List body;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    return ResponseBody.fromBytes(body, 200, headers: {
      Headers.contentLengthHeader: ['${body.length}'],
    });
  }

  @override
  void close({bool force = false}) {}
}

ApiClient _client(HttpClientAdapter adapter) =>
    ApiClient(dio: Dio()..httpClientAdapter = adapter, retryDelay: Duration.zero)
      ..setConnection(const Connection('https://w.example', 'tk'));

void main() {
  const limit = 32 * 1024 * 1024;

  test('上限を超える応答は content-length で読まずに TooLargeError', () async {
    final adapter = _BigBodyAdapter(declareLength: true);
    final api = _client(adapter);
    await expectLater(
      api.fetchBytes('https://w.example/m/big.jpg', maxBytes: limit),
      throwsA(isA<TooLargeError>()),
    );
    // ヘッダで弾くので本体を消費しない。転送層の内側で1断片だけ先に流れる分は許す
    expect(adapter.emitted, lessThanOrEqualTo(_BigBodyAdapter.chunk));
  });

  test('上限を超える応答は content-length が無くても途中で切って TooLargeError',
      () async {
    final adapter = _BigBodyAdapter(declareLength: false);
    final api = _client(adapter);
    await expectLater(
      api.fetchBytes('https://w.example/m/big.jpg', maxBytes: limit),
      throwsA(isA<TooLargeError>()),
    );
    // 超えた所で切るので、上限 + 流れ中の1断片を越えて読まない
    expect(adapter.emitted, lessThanOrEqualTo(limit + 2 * _BigBodyAdapter.chunk));
  });

  test('上限以下はそのまま返す', () async {
    final body = Uint8List.fromList(List.filled(1024 * 1024, 7));
    final api = _client(_SmallBodyAdapter(body));
    final got =
        await api.fetchBytes('https://w.example/m/a.jpg', maxBytes: limit);
    expect(got, body);
  });
}
