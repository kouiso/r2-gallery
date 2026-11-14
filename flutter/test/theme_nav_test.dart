import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/ui/theme.dart';

// デザイン Foundation / Main ボードのナビ値を ThemeData から読んで固定する。
// ピクセル比較(Ahem)ではなく解決後のテーマ値を見る。
void main() {
  final theme = buildAppTheme();
  final nav = theme.navigationBarTheme;

  test('ナビの文字: 未選択 #9C9AA8 w500 / 選択 #F2F0EA w700', () {
    final off = nav.labelTextStyle!.resolve(<WidgetState>{})!;
    final on = nav.labelTextStyle!.resolve({WidgetState.selected})!;
    expect(off.color, const Color(0xFF9C9AA8));
    expect(off.fontWeight, FontWeight.w500);
    expect(on.color, const Color(0xFFF2F0EA));
    expect(on.fontWeight, FontWeight.w700);
    expect(on.fontSize, 12);
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

  test('ナビのピルは 56x30 (64x32 の枠の内側)', () {
    final path = nav.indicatorShape!.getOuterPath(
      const Rect.fromLTWH(0, 0, 64, 32),
    );
    expect(path.getBounds(), const Rect.fromLTWH(4, 1, 56, 30));
  });

  test('success / onAccent トークン', () {
    expect(AppColors.success, const Color(0xFF7FD1A8));
    expect(AppColors.onAccent, const Color(0xFF1A1408));
    expect(theme.colorScheme.onPrimary, AppColors.onAccent);
  });

  test('画面タイトルは w700 で letterSpacing なし', () {
    final t = theme.appBarTheme.titleTextStyle!;
    expect(t.fontWeight, FontWeight.w700);
    expect(t.letterSpacing, isNull);
  });

  testWidgets('NavigationBar に適用されると 56x30 のピルで描かれる', (tester) async {
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
    // 実際に描画された段落の色・太さで、ウィジェットにテーマが届いていることを見る
    final off = tester
        .renderObject<RenderParagraph>(find.text('b'))
        .text
        .style!;
    final on = tester.renderObject<RenderParagraph>(find.text('a')).text.style!;
    expect(off.color, AppColors.textDim);
    expect(off.fontWeight, FontWeight.w500);
    expect(on.color, AppColors.textPrimary);
    expect(on.fontWeight, FontWeight.w700);
  });
}
