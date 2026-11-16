import 'package:flutter/material.dart';

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

  /// 押せる物の枠（入力欄・枠線ボタン）。地との差 3:1 以上。border は飾りの区切り線専用
  static const borderStrong = Color(0xFF6E6C7C);

  /// メディアの上に重ねる黒の濃さは2段だけ。バー（細い帯）は 55%、パネル（面）は 80%
  static const scrimBar = Color(0x8C000000);
  static const scrimPanel = Color(0xCC000000);

  /// スクリムの上の文字。本文用と補足用の2段
  static const onScrimText = Color(0xEBFFFFFF);
  static const onScrimDim = Color(0xCCFFFFFF);
}

/// Foundation「文字（提案）」の5段。画面への大きさ直書きはこれへ寄せる。
/// PIN の入力欄（24）は例外としてテーマへ入れない。
class AppText {
  /// 画面の見出し。20／28 Bold
  static const title = TextStyle(
    fontSize: 20,
    height: 28 / 20,
    fontWeight: FontWeight.w700,
  );

  /// シート見出し・空の状態の見出し。16／24 Bold
  static const heading = TextStyle(
    fontSize: 16,
    height: 24 / 16,
    fontWeight: FontWeight.w700,
  );

  /// 本文・行の主表示。15／22
  static const body = TextStyle(fontSize: 15, height: 22 / 15);

  /// ボタン・日付見出しの太い小字。14／20 Bold
  static const label = TextStyle(
    fontSize: 14,
    height: 20 / 14,
    fontWeight: FontWeight.w700,
  );

  /// 補足・タブ名・操作バー名。12／16
  static const caption = TextStyle(fontSize: 12, height: 16 / 12);
}

/// 角丸は3段。8 はタイルの選択・小さい部品、14 はボタン・入力欄、16 はカード・シート
class AppRadius {
  static const small = 8.0;
  static const medium = 14.0;
  static const large = 16.0;
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
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.bg,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
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
      contentTextStyle: const TextStyle(color: AppColors.textPrimary),
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
}
