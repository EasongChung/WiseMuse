import 'package:flutter/material.dart';

import '../../core/storage/database.dart';
import '../../core/storage/knowledge_point_dao.dart';
import '../../core/storage/sentence_dao.dart';
import '../../core/storage/word_entry_dao.dart';
import '../../core/theme/app_theme.dart';
import '../../widgets/knowledge_scope_picker.dart';
import '../assistant/tutor_panel.dart';
import '../dictation/dictation_page.dart';
import '../follow/follow_page.dart';
import '../quiz/quiz_hub_page.dart';
import '../../widgets/top_toast.dart';

/// [v0.3.0] 练习页：跟读/听写/章节测验三入口卡片。
///
/// 暖色书房统一风格，每入口以卡片形式展示图标与简介。
class PracticePage extends StatelessWidget {
  const PracticePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('练习')),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 标题
            Text('今日练习', style: titleStyle(fontSize: 18)),
            const SizedBox(height: 20),

            // 跟读
            _buildEntryCard(
              context,
              icon: Icons.record_voice_over_outlined,
              color: StudyPalette.ember,
              title: '跟读练习',
              subtitle: '从知识库选课 → 播放原文 → 跟读录音 → AI 评分',
              onTap: () => _openFollowPractice(context),
            ),
            const SizedBox(height: 12),

            // 听写
            _buildEntryCard(
              context,
              icon: Icons.edit_note_outlined,
              color: StudyPalette.spinePdf,
              title: '听写',
              subtitle: '听原文 → 默写 → 自动批改',
              onTap:
                  () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const DictationPage()),
                  ),
            ),
            const SizedBox(height: 12),

            // 章节测验（S6 预留）
            _buildEntryCard(
              context,
              icon: Icons.quiz_outlined,
              color: StudyPalette.spineWord,
              title: '章节测验',
              subtitle: '三题型：朗读评分 / 听音选字 / AI 选择题',
              onTap:
                  () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const QuizHubPage()),
                  ),
            ),
            const SizedBox(height: 12),

            // AI 助教推荐
            _buildEntryCard(
              context,
              icon: Icons.auto_awesome,
              color: StudyPalette.moss,
              title: 'AI 助教',
              subtitle: '今日推荐复习知识点评讲',
              onTap:
                  () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder:
                          (_) => Scaffold(
                            appBar: AppBar(title: const Text('AI 助教')),
                            body: const SingleChildScrollView(
                              padding: EdgeInsets.all(16),
                              child: TutorPanel(),
                            ),
                          ),
                    ),
                  ),
            ),
          ],
        ),
      ),
    );
  }

  /// [v0.1.61] 儿童化跟读练习入口：支持选择课文全篇、生词本或知识库重点词句。
  Future<void> _openFollowPractice(BuildContext context) async {
    final choice = await showDialog<String>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('选择跟读内容'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(
                    Icons.menu_book,
                    color: StudyPalette.ember,
                  ),
                  title: const Text('课文/章节跟读'),
                  subtitle: const Text('从已导入的教材中选课全篇跟读'),
                  onTap: () => Navigator.pop(ctx, 'book'),
                ),
                ListTile(
                  leading: const Icon(
                    Icons.bookmark_outline,
                    color: StudyPalette.moss,
                  ),
                  title: const Text('重点生词跟读'),
                  subtitle: const Text('练习生词本中未掌握的发音'),
                  onTap: () => Navigator.pop(ctx, 'wordbook'),
                ),
                ListTile(
                  leading: const Icon(
                    Icons.psychology_outlined,
                    color: StudyPalette.spinePdf,
                  ),
                  title: const Text('知识库词句跟读'),
                  subtitle: const Text('按诗词、成语、重点句进行练习'),
                  onTap: () => Navigator.pop(ctx, 'knowledge'),
                ),
              ],
            ),
          ),
    );
    if (choice == null || !context.mounted) return;

    if (choice == 'book') {
      final scope = await KnowledgeScopePicker.show(context);
      if (scope == null || !context.mounted) return;

      final db = await DatabaseProvider.database;
      final sentenceDao = SentenceDao(db);
      var sentences = await sentenceDao.getByBook(scope.bookId);
      if (scope.page != null && scope.page! > 0) {
        sentences = sentences.where((s) => s.page == scope.page).toList();
      }
      if (scope.chapter != null && scope.chapter! > 0) {
        sentences = sentences.where((s) => s.chapter == scope.chapter).toList();
      }

      var texts =
          sentences
              .map((s) => s.text)
              .where((t) => t.trim().isNotEmpty)
              .toList();
      if (texts.isEmpty) {
        final kpDao = KnowledgePointDao(db);
        final points = await kpDao.getByBook(scope.bookId);
        texts =
            points
                .map((p) => p.text)
                .where((t) => t.trim().isNotEmpty)
                .toList();
      }

      if (texts.isEmpty) {
        if (context.mounted) TopToast.show(context, '所选范围内暂无可用句子');
        return;
      }

      if (!context.mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder:
              (_) => FollowPage(
                sentences: texts,
                title: scope.bookTitle,
                bookId: scope.bookId,
                pageNumber: scope.page,
              ),
        ),
      );
    } else if (choice == 'wordbook') {
      try {
        final db = await DatabaseProvider.database;
        final unmastered = await WordEntryDao(db).getUnmastered(threshold: 3);
        var words =
            unmastered
                .map((w) => w.word)
                .where((t) => t.trim().isNotEmpty)
                .toList();
        if (words.isEmpty) {
          words = const ['苹果', '春天', '认真', '美丽', '学习', '太阳', '温暖', '快乐'];
          if (context.mounted) TopToast.show(context, '生词本暂无未掌握生词，已加载常用字词');
        }
        if (!context.mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => FollowPage(sentences: words, title: '重点生词跟读'),
          ),
        );
      } catch (e) {
        if (context.mounted) TopToast.show(context, '加载生词本失败');
      }
    } else if (choice == 'knowledge') {
      try {
        final db = await DatabaseProvider.database;
        final points = await KnowledgePointDao(db).getAll();
        final words =
            points
                .take(20)
                .map((kp) => kp.text)
                .where((t) => t.trim().isNotEmpty)
                .toList();
        if (words.isEmpty) {
          if (context.mounted) TopToast.show(context, '知识库暂无内容');
          return;
        }
        if (!context.mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => FollowPage(sentences: words, title: '知识库重点词句跟读'),
          ),
        );
      } catch (e) {
        if (context.mounted) TopToast.show(context, '加载知识库失败');
      }
    }
  }

  Widget _buildEntryCard(
    BuildContext context, {
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              // 图标容器
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: color, size: 26),
              ),
              const SizedBox(width: 14),
              // 文字
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: StudyPalette.onSurfaceResolved(context),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontSize: 12,
                        color: StudyPalette.inkSoft,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: StudyPalette.inkSoft),
            ],
          ),
        ),
      ),
    );
  }
}
