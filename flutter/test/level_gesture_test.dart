import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/viewer/level_gesture.dart';

void main() {
  const h = 600.0;

  group('LevelGesture', () {
    test('余裕の中では動かず、越えた分だけ動く', () {
      final g = LevelGesture(base: 0.4, min: 0, max: 1);
      expect(g.update(-10, h), 0.4);
      expect(g.moved, isFalse);
      // 累計 -26px のうち余裕 16px を除いた 10px 分（10 / (600 * 0.7)）
      expect(g.update(-16, h), closeTo(0.4 + 10 / (h * LevelGesture.span), 1e-9));
      expect(g.moved, isTrue);
    });

    test('1 回で動く量は上限まで。上限で止めた分は捨てるので、指を戻すと次の更新から戻る', () {
      final g = LevelGesture(base: 0.4, min: 0, max: 1);
      // 勢いよく上へ（値が上がる向き）。1 回目は上限 5% で止まる
      expect(g.update(-100, h), closeTo(0.45, 1e-9));
      // 指が下へ戻った。以前は残りの累計のせいで 0.50 へ上がっていた
      final back = g.update(10, h);
      expect(back, lessThan(0.45));
      expect(g.update(10, h), lessThan(back));
    });

    test('素早い連続の後に指を戻すと、戻した最初の更新から下がる', () {
      final g = LevelGesture(base: 0.4, min: 0, max: 1);
      var v = 0.0;
      for (var i = 0; i < 3; i++) {
        v = g.update(-60, h);
      }
      expect(v, closeTo(0.55, 1e-9));
      for (var i = 0; i < 4; i++) {
        final next = g.update(20, h);
        expect(next, lessThan(v), reason: '戻した ${i + 1} 回目で下がる');
        v = next;
      }
    });

    test('端で止まった分も捨てる。端を越えて引いた後でも、戻せばすぐ動く', () {
      final g = LevelGesture(base: 0.98, min: 0, max: 1);
      expect(g.update(-500, h), 1.0);
      // 以前は 500px 分戻すまで 1.0 のままだった
      expect(g.update(30, h), lessThan(1.0));
    });

    test('上限に当たらない普通の動きは累計どおり。戻すと起点へ戻る', () {
      final g = LevelGesture(base: 0.5, min: 0, max: 1);
      final down = g.update(30, h); // 余裕を引いて 14px
      expect(down, closeTo(0.5 - 14 / (h * LevelGesture.span), 1e-9));
      expect(g.update(-30, h), closeTo(0.5, 1e-9));
      expect(g.moved, isFalse);
    });

    test('起点の値を端に丸める', () {
      final g = LevelGesture(base: 1.4, min: 0.02, max: 1);
      expect(g.level, 1.0);
      expect(g.moved, isFalse);
    });
  });
}
