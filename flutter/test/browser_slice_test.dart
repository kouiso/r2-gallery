import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/ui/browser_surface.dart';

void main() {
  test('再走査の結果は 200 件ずつに分かれ、1件も欠けず順序も保たれる', () {
    final pairs = <Object?>[
      for (var i = 0; i < 450; i++) ['v', 'https://x/$i.mp4'],
    ];
    final slices = sliceMessagePairs(pairs);
    expect(slices.map((s) => s.length), [200, 200, 50]);
    expect(slices.expand((s) => s).toList(), pairs);
  });

  test('空と上限ちょうどは余計な空の通知を作らない', () {
    expect(sliceMessagePairs(const []), isEmpty);
    expect(sliceMessagePairs(List<Object?>.filled(200, 1)), hasLength(1));
  });
}
