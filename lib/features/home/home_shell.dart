import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../ai_chat/ai_chat_page.dart';
import '../home/home_page.dart';
import '../knowledge/knowledge_page.dart';
import '../practice/practice_page.dart';
import '../profile/profile_page.dart';

/// [v0.3.0] [v0.1.48] 底部导航壳（5 Tab：书架/知识库/练习/问AI/我的）。
///
/// IndexedStack 保留各 Tab 状态，切 Tab 不销毁。
/// 主题沿用「暖色书房」。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _selectedIndex = 0;

  final List<Widget> _pages = const [
    HomePage(),
    KnowledgePage(),
    PracticePage(),
    AiChatPage(),
    ProfilePage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _selectedIndex, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (i) => setState(() => _selectedIndex = i),
        backgroundColor:
            Theme.of(context).brightness == Brightness.dark
                ? StudyPalette.darkCard
                : StudyPalette.parchment,
        indicatorColor:
            Theme.of(context).brightness == Brightness.dark
                ? StudyPalette.ember.withValues(alpha: 0.35)
                : StudyPalette.emberSoft,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.library_books_outlined),
            selectedIcon: Icon(Icons.library_books),
            label: '书架',
          ),
          NavigationDestination(
            icon: Icon(Icons.psychology_outlined),
            selectedIcon: Icon(Icons.psychology),
            label: '知识库',
          ),
          NavigationDestination(
            icon: Icon(Icons.edit_note_outlined),
            selectedIcon: Icon(Icons.edit_note),
            label: '练习',
          ),
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: '问AI',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: '我的',
          ),
        ],
      ),
    );
  }
}
