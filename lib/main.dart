import 'package:flutter/material.dart';

import 'core/debug/app_log.dart';
import 'features/home/home_page.dart';

/// [v0.2.0] 智启陪读 WiseMuse 应用壳。
///
/// home 为书架首页（Phase 2 导入与识别）；跟读练习页经首页 AppBar 进入。
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
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3F72AF)),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}
