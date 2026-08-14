import 'package:flutter/material.dart';

import 'core/debug/app_log.dart';
import 'core/theme/app_theme.dart';
import 'features/home/home_shell.dart';

/// [v0.3.0] 智启陪读 WiseMuse 应用壳。
///
/// home 为 HomeShell（4 Tab 底部导航：书架/知识库/练习/我的）。
/// 主题「暖色书房」见 [buildStudyTheme]。
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
      darkTheme: buildStudyTheme(brightness: Brightness.dark),
      themeMode: ThemeMode.system,
      home: const HomeShell(),
    );
  }
}
