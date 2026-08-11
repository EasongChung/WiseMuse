import 'package:flutter/material.dart';

import 'core/debug/app_log.dart';
import 'features/follow/follow_page.dart';

/// [v0.1.0] 智启陪读 WiseMuse 应用壳。
///
/// 当前 home 为跟读练习页（Vosk PoC 已验收）；后续 Phase 3+ 接入正式首页。
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
      home: const FollowPage(),
    );
  }
}
