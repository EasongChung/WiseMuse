import 'package:flutter/material.dart';

import 'core/debug/app_log.dart';
import 'core/theme/app_theme.dart';
import 'features/home/home_page.dart';

/// [v0.3.0] 智启陪读 WiseMuse 应用壳。
///
/// home 为书架首页（Phase 2 导入与识别）；跟读练习页经首页 AppBar 进入。
/// 主题「暖色书房」见 [buildStudyTheme]（羊皮纸底 + 墨青文字 + 亮橙 CTA）。
Future<void> main() async {
  // 测试期：先起日志（落盘），确保后续任何崩溃前的步骤都有记录。
  await AppLog.init();
  runApp(const WiseMuseApp());
}

class WiseMuseApp extends StatelessWidget {
  const WiseMuseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '智启陪读',
      debugShowCheckedModeBanner: false,
      theme: buildStudyTheme(),
      home: const HomePage(),
    );
  }
}
