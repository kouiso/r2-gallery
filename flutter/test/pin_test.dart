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

  test('照合のハッシュ計算中も UI isolate のイベントループは止まらない', () async {
    await PinLock.setPin('123456');

    // 10ms 周期のタイマーの間隔の最大値を測る。同期で回すとハッシュの時間ぶんそのまま空く
    var last = DateTime.now();
    var maxGapMs = 0;
    final ticker = Timer.periodic(const Duration(milliseconds: 10), (_) {
      final now = DateTime.now();
      final gap = now.difference(last).inMilliseconds;
      if (gap > maxGapMs) maxGapMs = gap;
      last = now;
    });
    last = DateTime.now();
    await PinLock.verify('123456');
    // 終わった直後のタイマーを一度走らせて、固まっていた間隔を記録させる
    await Future<void>.delayed(const Duration(milliseconds: 30));
    ticker.cancel();

    expect(maxGapMs, lessThan(100));
  });
}
