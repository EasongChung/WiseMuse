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

  // ===== [v0.1.35] 深色模式色板变体 =====

  /// 深色背景（接近黑色暖调）。
  static const darkBg = Color(0xFF1A1C1E);

  /// 深色卡片底（略亮于背景）。
  static const darkCard = Color(0xFF252729);

  /// 深色文字（暖白）。
  static const darkInk = Color(0xFFE8E0D5);

  /// 深色次级文字。
  static const darkInkSoft = Color(0xFF9E9488);

  /// 深色边框。
  static const darkBorder = Color(0xFF3A3430);

  /// [v0.1.35] 列表项/卡片背景（明暗自适应），替代 inline `Colors.white.withAlpha(N)`。
  /// 在 build 方法中调用以保证 [context] 持有正确的 [Brightness]。
  static Color surfaceWithAlpha(BuildContext context, {double alpha = 0.6}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = isDark ? darkCard : const Color(0xFFFFFFFF);
    return base.withValues(alpha: alpha);
  }

  /// [v0.1.35] 表层文字颜色（明暗自适应）。
  static Color onSurfaceResolved(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark ? darkInk : ink;
  }
}

/// 全局 [ThemeData]「暖色书房」。
///
/// [brightness] 控制明暗色板（默认 [Brightness.light]）。
/// 页面中强调性大标题可用 [titleStyle] 显式指定。
ThemeData buildStudyTheme({Brightness brightness = Brightness.light}) {
  final isDark = brightness == Brightness.dark;

  final bg = isDark ? StudyPalette.darkBg : StudyPalette.parchment;
  final cardBg =
      isDark ? StudyPalette.darkCard : Colors.white.withValues(alpha: 0.72);
  final surface = isDark ? StudyPalette.darkCard : StudyPalette.parchmentDeep;
  final onSurface = isDark ? StudyPalette.darkInk : StudyPalette.ink;
  final onSurfaceSoft =
      isDark ? StudyPalette.darkInkSoft : StudyPalette.inkSoft;
  final outline = isDark ? StudyPalette.darkBorder : StudyPalette.linen;

  final scheme = ColorScheme.fromSeed(
    seedColor: StudyPalette.ember,
    brightness: brightness,
  ).copyWith(
    primary: StudyPalette.ember,
    onPrimary: Colors.white,
    secondary: StudyPalette.moss,
    onSecondary: Colors.white,
    surface: surface,
    onSurface: onSurface,
    onSurfaceVariant: onSurfaceSoft,
    error: const Color(0xFFB6482E),
    outline: outline,
  );

  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: bg,
  );

  return base.copyWith(
    appBarTheme: AppBarTheme(
      backgroundColor: bg,
      foregroundColor: onSurface,
      elevation: 0,
      scrolledUnderElevation: 1,
      shadowColor:
          isDark ? Colors.black26 : StudyPalette.ink.withValues(alpha: 0.06),
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontFamily: 'ZCOOLKuaiLe',
        fontSize: 22,
        color: onSurface,
        letterSpacing: 1.2,
      ),
    ),
    cardTheme: CardThemeData(
      color: cardBg,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: outline),
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
        foregroundColor: onSurface,
        side: BorderSide(color: outline, width: 1.4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: StudyPalette.ember),
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: surface,
      selectedColor: StudyPalette.emberSoft,
      side: BorderSide(color: outline),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      labelStyle: TextStyle(color: onSurface),
      secondaryLabelStyle: TextStyle(color: onSurface),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: StudyPalette.ember,
      foregroundColor: Colors.white,
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: isDark ? StudyPalette.darkCard : StudyPalette.ink,
      contentTextStyle: const TextStyle(color: Colors.white),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    dividerTheme: DividerThemeData(color: outline, space: 1),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor:
          isDark ? StudyPalette.darkBg : Colors.white.withValues(alpha: 0.8),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: StudyPalette.ember, width: 1.6),
      ),
      labelStyle: TextStyle(color: onSurfaceSoft),
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
