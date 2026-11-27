import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';

/// 大きい応答を1MiBの断片で返す口。実際に流れた量を数えて、
/// 上限で切った時に後ろを読み続けない事を確かめる。
/// 断片は [release] で許した分だけ流す。dio は応答の本体を受け取った直後から読み手より先に
/// 読み始めてしまうので、時間で流すと「切るまでに何ms 掛かったか」で流れた量が変わり、
/// 負荷の高い実行で上限の判定が揺れる。流す量を呼び出し側が決めれば、結果は時間に依らない
class _BigBodyAdapter implements HttpClientAdapter {
  _BigBodyAdapter({this.declareLength = true});

  final bool declareLength;
  int emitted = 0;

  static const chunk = 1024 * 1024;
  static const total = 40 * chunk;

  int _credits = 0;
  Completer<void>? _waiting;

  /// 断片を [n] 個ぶん流してよいことにする
  void release(int n) {
    _credits += n;
    final w = _waiting;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<void> _acquire() async {
    while (_credits == 0) {
      final w = _waiting = Completer<void>();
      await w.future;
    }
    _credits--;
  }

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    Stream<Uint8List> body() async* {
      var sent = 0;
      while (sent < total) {
        await _acquire();
        sent += chunk;
        emitted = sent;
        yield Uint8List(chunk);
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
    // 転送層の内側で先に1断片だけ流れる分は許す。それ以上は流さないので、
    // 本体を読もうとする実装なら待ち続けて timeout になり、このテストが落ちる
    adapter.release(1);
    final api = _client(adapter);
    await expectLater(
      api
          .fetchBytes('https://w.example/m/big.jpg', maxBytes: limit)
          .timeout(const Duration(seconds: 10)),
      throwsA(isA<TooLargeError>()),
    );
    // ヘッダで弾くので本体を消費しない
    expect(adapter.emitted, lessThanOrEqualTo(_BigBodyAdapter.chunk));
  });

  test('上限を超える応答は content-length が無くても途中で切って TooLargeError',
      () async {
    final adapter = _BigBodyAdapter(declareLength: false);
    final api = _client(adapter);
    Object? error;
    var done = false;
    final call = api
        .fetchBytes('https://w.example/m/big.jpg', maxBytes: limit)
        .then<void>((_) => done = true, onError: (Object e) {
      error = e;
      done = true;
    });
    // 1断片ずつ流し、そのたびに読み手が追いつくまで待つ。切れたらそこで流すのをやめる
    for (var i = 0; i < _BigBodyAdapter.total ~/ _BigBodyAdapter.chunk && !done; i++) {
      adapter.release(1);
      await pumpEventQueue(times: 50);
    }
    await call.timeout(const Duration(seconds: 10));
    expect(error, isA<TooLargeError>());
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
