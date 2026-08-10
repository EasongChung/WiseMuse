import 'package:flutter/material.dart';

import 'features/follow/asr_demo_page.dart';

/// [v0.1.0] 智启陪读 WiseMuse 应用壳。
///
/// 当前 home 为 Vosk 离线识别 PoC 验证页；后续 Phase 3+ 接入正式首页。
void main() {
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
      home: const AsrDemoPage(),
    );
  }
}
