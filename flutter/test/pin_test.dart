import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/store/pin.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('設定した PIN は照合を通り、違う PIN は通らない', () async {
    await PinLock.setPin('123456');
    expect(await PinLock.verify('123456'), isTrue);
    expect(await PinLock.verify('654321'), isFalse);
  });

  test('照合のハッシュ計算は compute に任され、保留中も UI isolate のイベントループは進み続ける', () async {
    await PinLock.setPin('123456');
    final real = PinLock.computeImpl;
    addTearDown(() => PinLock.computeImpl = real);

    // compute を偽物にして、コールバックを呼び出し側では一切実行せず保留したままにする。
    // 実時間ではなく順序で見る: 同期計算なら verify はここで返り切るか tick が進まない
    final calls = <Object?>[];
    final release = Completer<Object?>();
    PinLock.computeImpl = <M, R>(cb, message, {debugLabel}) {
      calls.add(message);
      return release.future.then((v) => v as R);
    };

    var ticks = 0;
    final ticker =
        Timer.periodic(const Duration(milliseconds: 1), (_) => ticks++);
    addTearDown(ticker.cancel);
    var done = false;
    final result = PinLock.verify('123456').whenComplete(() => done = true);

    // verify は Kv 読み出しのあとで compute を呼ぶ。呼ばれるまで待つ
    while (calls.isEmpty && !done) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(calls, hasLength(1), reason: 'ハッシュは compute 経由で呼ばれる');
    final before = ticks;
    while (ticks < before + 3) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(done, isFalse, reason: 'ハッシュ未完了のうちは verify も未完了');
    expect(calls, hasLength(1));
    final msg = calls.single as ({String pin, List<int> salt, int iterations});
    expect(msg.iterations, 210000);

    release.complete(pbkdf2Sha256('123456', msg.salt, msg.iterations));
    expect(await result, isTrue);
  });
}
