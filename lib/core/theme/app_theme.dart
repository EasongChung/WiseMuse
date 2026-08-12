library;

import 'package:flutter/material.dart';

/// [v0.3.0] WiseMuse 全局主题「暖色书房」。
///
/// 设计语言（2026-08-12 用户选定）：
/// - 羊皮纸米底 + 墨青文字 + 亮橙 CTA → 温暖书卷气，家长与儿童都舒适。
/// - 标题用站酷快乐体（ZCOOL KuaiLe，圆体童趣）——**打包进 assets，离线可用**；
///   正文保持系统默认字体保证可读性。
/// - 书本来源用不同「书脊色」区分（PDF=靛蓝 / 图片=橙 / Word=苔绿 / TXT=灰紫），
///   书架卡片做成「书本」形态。
///
/// 本文件是唯一主题来源；页面一律通过 Theme.of(context) 取色，禁止散落硬编码色值。

/// 暖色书房色板。
class StudyPalette {
  StudyPalette._();

  /// 羊皮纸底（全局背景）。
  static const parchment = Color(0xFFFBF7EF);

  /// 羊皮纸加深（卡片/分段底）。
  static const parchmentDeep = Color(0xFFF3EADA);

  /// 墨青（主文字）。
  static const ink = Color(0xFF2D3A45);

  /// 墨青弱化（次级文字）。
  static const inkSoft = Color(0xFF5C6B76);

  /// 亮橙（CTA / 强调）。
  static const ember = Color(0xFFE8734A);

  /// 亮橙浅底（强调容器/选中态）。
  static const emberSoft = Color(0xFFFBE4D8);

  /// 苔绿（成功 / 通过）。
  static const moss = Color(0xFF6E9463);

  /// 苔绿浅底。
  static const mossSoft = Color(0xFFE6F0E2);

  /// 暖灰（边框 / 分隔）。
  static const linen = Color(0xFFE5DCCB);

  /// 书脊色：PDF（靛蓝）。
  static const spinePdf = Color(0xFF4A6B8A);

  /// 书脊色：图片（橙）。
  static const spineImage = Color(0xFFD9853B);

  /// 书脊色：Word（苔绿）。
  static const spineWord = Color(0xFF7A9E7E);

  /// 书脊色：TXT（灰紫）。
  static const spineTxt = Color(0xFF8A7CA8);

  /// 按 [BookSource] 取书脊色。
  static Color spineFor(Object? source) {
    switch (source?.toString()) {
      case 'BookSource.pdf':
        return spinePdf;
      case 'BookSource.camera':
      case 'BookSource.gallery':
        return spineImage;
      case 'BookSource.word':
        return spineWord;
      case 'BookSource.txt':
        return spineTxt;
      default:
        return spinePdf;
    }
  }
}

/// 全局 [ThemeData]「暖色书房」。
///
/// [useTitleFont] 为 true 时标题/数字用站酷快乐体（圆体）；正文始终系统字体。
/// 页面中强调性大标题可用 [titleStyle] 显式指定。
ThemeData buildStudyTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: StudyPalette.ember,
    brightness: Brightness.light,
  ).copyWith(
    primary: StudyPalette.ember,
    onPrimary: Colors.white,
    secondary: StudyPalette.moss,
    onSecondary: Colors.white,
    surface: StudyPalette.parchment,
    onSurface: StudyPalette.ink,
    onSurfaceVariant: StudyPalette.inkSoft,
    error: const Color(0xFFB6482E),
    outline: StudyPalette.linen,
  );

  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: StudyPalette.parchment,
  );

  return base.copyWith(
    appBarTheme: AppBarTheme(
      backgroundColor: StudyPalette.parchment,
      foregroundColor: StudyPalette.ink,
      elevation: 0,
      scrolledUnderElevation: 1,
      shadowColor: StudyPalette.ink.withValues(alpha: 0.06),
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontFamily: 'ZCOOLKuaiLe',
        fontSize: 22,
        color: StudyPalette.ink,
        letterSpacing: 1.2,
      ),
    ),
    cardTheme: CardThemeData(
      color: Colors.white.withValues(alpha: 0.72),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: StudyPalette.linen),
      ),
      margin: EdgeInsets.zero,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: StudyPalette.ember,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        textStyle: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: StudyPalette.ink,
        side: BorderSide(color: StudyPalette.linen, width: 1.4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: StudyPalette.ember),
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: StudyPalette.parchmentDeep,
      selectedColor: StudyPalette.emberSoft,
      side: BorderSide(color: StudyPalette.linen),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      labelStyle: const TextStyle(color: StudyPalette.ink),
      secondaryLabelStyle: const TextStyle(color: StudyPalette.ink),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: StudyPalette.ember,
      foregroundColor: Colors.white,
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: StudyPalette.ink,
      contentTextStyle: const TextStyle(color: Colors.white),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    dividerTheme: DividerThemeData(color: StudyPalette.linen, space: 1),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.8),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: StudyPalette.linen),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: StudyPalette.linen),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: StudyPalette.ember, width: 1.6),
      ),
      labelStyle: const TextStyle(color: StudyPalette.inkSoft),
    ),
  );
}

/// 标题样式（站酷快乐体圆体）。用于页面大标题 / 强调性数字。
TextStyle titleStyle({double fontSize = 22, Color color = StudyPalette.ink}) {
  return TextStyle(
    fontFamily: 'ZCOOLKuaiLe',
    fontSize: fontSize,
    color: color,
    letterSpacing: 1,
    height: 1.25,
  );
}
