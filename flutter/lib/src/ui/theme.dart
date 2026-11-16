import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// OS の CJK fallback による地域別の字形差を避け、同梱の日本語字形を優先する。
class AppTypography {
  static const fontFamily = 'R2GalleryJP';
  static const locale = Locale('ja', 'JP');
  static const fallback = ['sans-serif'];

  static void registerLicense() {
    LicenseRegistry.addLicense(() async* {
      final license = await rootBundle.loadString('assets/fonts/OFL.txt');
      yield LicenseEntryWithLineBreaks(['R2 Gallery JP (Noto Sans CJK JP)'], license);
    });
  }
}

TextTheme _japaneseTextTheme(TextTheme base) {
  TextStyle? ja(TextStyle? style) => style?.copyWith(locale: AppTypography.locale);
  return base.copyWith(
    displayLarge: ja(base.displayLarge),
    displayMedium: ja(base.displayMedium),
    displaySmall: ja(base.displaySmall),
    headlineLarge: ja(base.headlineLarge),
    headlineMedium: ja(base.headlineMedium),
    headlineSmall: ja(base.headlineSmall),
    titleLarge: ja(base.titleLarge),
    titleMedium: ja(base.titleMedium),
    titleSmall: ja(base.titleSmall),
    bodyLarge: ja(base.bodyLarge),
    bodyMedium: ja(base.bodyMedium),
    bodySmall: ja(base.bodySmall),
    labelLarge: ja(base.labelLarge),
    labelMedium: ja(base.labelMedium),
    labelSmall: ja(base.labelSmall),
  );
}

/// ダーク基調のギャラリー向けテーマ。アクセントは暖かいゴールド。
/// 「夜に見るプライベートな金庫」をイメージした落ち着いた配色。
class AppColors {
  static const bg = Color(0xFF0A0A0F);
  static const surface = Color(0xFF14141D);
  static const surfaceHigh = Color(0xFF1E1E2B);
  static const border = Color(0xFF2A2A3A);
  static const accent = Color(0xFFE4B95B);
  static const accentSoft = Color(0x33E4B95B);
  static const textPrimary = Color(0xFFF2F0EA);
  static const textDim = Color(0xFF9C9AA8);
  static const danger = Color(0xFFE0605E);
  // Foundation ボードの success / onAccent。settings_tab・gallery_tab・
  // selection_widgets にはまだ同じ値の直書きが残っており、画面側の作業で置き換える
  static const success = Color(0xFF7FD1A8);
  static const onAccent = Color(0xFF1A1408);
}

/// デザインのナビ選択ピルは 56x30 / r15 だが、M3 のインジケータ枠は 64x32 固定で
/// サイズをテーマから渡せない。枠の中に描く図形側を小さくして合わせる。
class _NavPillBorder extends ShapeBorder {
  const _NavPillBorder();

  static const _inset = EdgeInsets.symmetric(horizontal: 4, vertical: 1);

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      getOuterPath(rect, textDirection: textDirection);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) => Path()
    ..addRRect(
      RRect.fromRectAndRadius(
        _inset.deflateRect(rect),
        const Radius.circular(15),
      ),
    );

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}

  @override
  ShapeBorder scale(double t) => this;
}

ThemeData buildAppTheme() {
  final scheme = ColorScheme.dark(
    surface: AppColors.surface,
    primary: AppColors.accent,
    onPrimary: AppColors.onAccent,
    secondary: AppColors.accent,
    error: AppColors.danger,
    onSurface: AppColors.textPrimary,
    surfaceContainerHighest: AppColors.surfaceHigh,
    outline: AppColors.border,
  );
  final theme = ThemeData(
    useMaterial3: true,
    fontFamily: AppTypography.fontFamily,
    fontFamilyFallback: AppTypography.fallback,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.bg,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontFamily: AppTypography.fontFamily,
        fontFamilyFallback: AppTypography.fallback,
        locale: AppTypography.locale,
        color: AppColors.textPrimary,
        fontSize: 20,
        // Foundation の title は 20／28。指定しないと行の高さが書体任せになる
        height: 28 / 20,
        fontWeight: FontWeight.w700,
      ),
    ),
    cardTheme: CardThemeData(
      color: AppColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.border),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.surfaceHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: AppColors.surfaceHigh,
      contentTextStyle: const TextStyle(
        color: AppColors.textPrimary,
        fontFamily: AppTypography.fontFamily,
        fontFamilyFallback: AppTypography.fallback,
        locale: AppTypography.locale,
      ),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    tabBarTheme: const TabBarThemeData(
      labelColor: AppColors.accent,
      unselectedLabelColor: AppColors.textDim,
      indicatorColor: AppColors.accent,
      dividerColor: Colors.transparent,
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: AppColors.surface,
      selectedItemColor: AppColors.accent,
      unselectedItemColor: AppColors.textDim,
      type: BottomNavigationBarType.fixed,
      elevation: 0,
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 80,
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      indicatorColor: AppColors.accentSoft,
      indicatorShape: const _NavPillBorder(),
      // デザインのピルと文字の間は 4px。ピルは枠の下端から 1px 内側にあるので、
      // 既定の 4 から 1 引く
      labelPadding: const EdgeInsets.only(top: 3),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        // Foundation の caption は 12／16 で字間なし。指定しないと bodyMedium の
        // 字間 0.25・行の高さ 1.43 を引き継ぐ
        return TextStyle(
          fontSize: 12,
          height: 16 / 12,
          letterSpacing: 0,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          color: selected ? AppColors.textPrimary : AppColors.textDim,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 22,
          color: states.contains(WidgetState.selected)
              ? AppColors.textPrimary
              : AppColors.textDim,
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.accent,
        foregroundColor: AppColors.onAccent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surfaceHigh,
      hintStyle: const TextStyle(color: AppColors.textDim),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppColors.accent, width: 1.6),
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AppColors.accent,
    ),
  );
  return theme.copyWith(
    textTheme: _japaneseTextTheme(theme.textTheme),
    primaryTextTheme: _japaneseTextTheme(theme.primaryTextTheme),
  );
}
