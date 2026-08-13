import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../debug/log_page.dart';
import '../settings/settings_page.dart';
import '../wordbook/wordbook_page.dart';

/// [v0.3.0] 个人中心页（我的 Tab）。
///
/// 列表入口：生词本 / 学习统计 / 运行日志 / 设置。
class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 头像区域
            Center(
              child: Column(
                children: [
                  CircleAvatar(
                    radius: 36,
                    backgroundColor: StudyPalette.emberSoft,
                    child: const Icon(Icons.person,
                        size: 40, color: StudyPalette.ember),
                  ),
                  const SizedBox(height: 10),
                  const Text('小读者',
                      style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: StudyPalette.ink)),
                  const SizedBox(height: 4),
                  const Text('坚持学习，天天向上',
                      style:
                          TextStyle(fontSize: 13, color: StudyPalette.inkSoft)),
                ],
              ),
            ),
            const SizedBox(height: 28),

            // 功能入口列表
            Card(
              child: Column(
                children: [
                  _buildEntry(
                    context,
                    icon: Icons.menu_book_outlined,
                    title: '生词本',
                    subtitle: '查看和管理不熟悉的词语',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => const WordBookPage()),
                    ),
                  ),
                  const Divider(height: 1, indent: 56),
                  _buildEntry(
                    context,
                    icon: Icons.bar_chart_outlined,
                    title: '学习统计',
                    subtitle: '学习记录与进度',
                    onTap: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('学习统计即将推出')),
                      );
                    },
                  ),
                  const Divider(height: 1, indent: 56),
                  _buildEntry(
                    context,
                    icon: Icons.bug_report_outlined,
                    title: '运行日志',
                    subtitle: '查看应用运行日志',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => const LogPage()),
                    ),
                  ),
                  const Divider(height: 1, indent: 56),
                  _buildEntry(
                    context,
                    icon: Icons.settings_outlined,
                    title: '设置',
                    subtitle: '翻译引擎、朗读参数、AI 配置',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => const SettingsPage()),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEntry(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(icon, color: StudyPalette.ember, size: 24),
      title: Text(title,
          style: const TextStyle(
              fontWeight: FontWeight.w600, color: StudyPalette.ink)),
      subtitle: Text(subtitle,
          style: const TextStyle(fontSize: 12, color: StudyPalette.inkSoft)),
      trailing: const Icon(Icons.chevron_right, color: StudyPalette.inkSoft),
      onTap: onTap,
    );
  }
}