import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/ui/theme.dart';

// デザイン Foundation / Main ボードのナビ値を ThemeData から読んで固定する。
// ピクセル比較(Ahem)ではなく解決後のテーマ値を見る。
void main() {
  final theme = buildAppTheme();
  final nav = theme.navigationBarTheme;

  test('ナビの文字: 未選択 #9C9AA8 w500 / 選択 #F2F0EA w700、12／16 字間 0', () {
    final off = nav.labelTextStyle!.resolve(<WidgetState>{})!;
    final on = nav.labelTextStyle!.resolve({WidgetState.selected})!;
    expect(off.color, const Color(0xFF9C9AA8));
    expect(off.fontWeight, FontWeight.w500);
    expect(on.color, const Color(0xFFF2F0EA));
    expect(on.fontWeight, FontWeight.w700);
    for (final s in [off, on]) {
      expect(s.fontSize, 12);
      expect(s.height, 16 / 12);
      expect(s.letterSpacing, 0);
    }
  });

  test('ナビのアイコン色は文字色と同じ', () {
    expect(
      nav.iconTheme!.resolve(<WidgetState>{})!.color,
      const Color(0xFF9C9AA8),
    );
    expect(
      nav.iconTheme!.resolve({WidgetState.selected})!.color,
      const Color(0xFFF2F0EA),
    );
  });

  test('ナビのバーは #14141D 高さ80、ピルは rgba(228,185,91,.2)', () {
    expect(nav.backgroundColor, const Color(0xFF14141D));
    expect(nav.height, 80);
    expect(nav.indicatorColor, const Color.fromRGBO(228, 185, 91, 0.2));
  });

  test('success / onAccent トークン', () {
    expect(AppColors.success, const Color(0xFF7FD1A8));
    expect(AppColors.onAccent, const Color(0xFF1A1408));
    expect(theme.colorScheme.onPrimary, AppColors.onAccent);
  });

  test('画面タイトルは 20／28 w700 で letterSpacing なし', () {
    final t = theme.appBarTheme.titleTextStyle!;
    expect(t.fontSize, 20);
    expect(t.height, 28 / 20);
    expect(t.fontWeight, FontWeight.w700);
    expect(t.letterSpacing, isNull);
  });

  testWidgets('NavigationBar に適用されると 56x30 r15 のピルと 12／16 の文字で描かれる', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          bottomNavigationBar: NavigationBar(
            selectedIndex: 0,
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.photo_outlined),
                label: 'a',
              ),
              NavigationDestination(
                icon: Icon(Icons.settings_outlined),
                label: 'b',
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(NavigationBar)).height, 80);

    // テーマの値ではなく、NavigationBar が実際に組んだ選択中のインジケータを測る
    final indicator = find.byType(NavigationIndicator).first;
    final ink = find.descendant(of: indicator, matching: find.byType(Ink));
    final frame = tester.getRect(ink);
    final shape = tester.widget<NavigationIndicator>(indicator).shape!;
    final path = shape.getOuterPath(frame);
    final pill = path.getBounds();
    expect(pill.size, const Size(56, 30));
    expect(pill.center, frame.center);
    // 角を 45 度の向きに 4.2px 入った点は外、4.6px 入った点は内。半径 14.3〜15.7 の間に限られる
    for (final corner in [pill.topLeft, pill.bottomRight]) {
      final inward = corner == pill.topLeft ? 1.0 : -1.0;
      expect(path.contains(corner + Offset(4.2, 4.2) * inward), isFalse);
      expect(path.contains(corner + Offset(4.6, 4.6) * inward), isTrue);
    }

    // 実際に描画された段落の色・太さ・字間・行の高さで、テーマが届いていることを見る
    final off = tester
        .renderObject<RenderParagraph>(find.text('b'))
        .text
        .style!;
    final on = tester.renderObject<RenderParagraph>(find.text('a')).text.style!;
    expect(off.color, AppColors.textDim);
    expect(off.fontWeight, FontWeight.w500);
    expect(on.color, AppColors.textPrimary);
    expect(on.fontWeight, FontWeight.w700);
    for (final s in [off, on]) {
      expect(s.letterSpacing, 0);
      expect(s.height, 16 / 12);
    }
    final label = tester.getRect(find.text('a'));
    expect(label.height, 16);
    // デザインのピルと文字の間は 4px
    expect(label.top - pill.bottom, 4);
  });
}
