import 'package:flutter/material.dart';

import '../../core/storage/database.dart';
import '../../core/storage/knowledge_point_dao.dart';
import '../../core/storage/sentence_dao.dart';
import '../../core/theme/app_theme.dart';
import '../../widgets/follow_sheet.dart';
import '../../widgets/knowledge_scope_picker.dart';
import '../assistant/tutor_panel.dart';
import '../dictation/dictation_page.dart';
import '../quiz/quiz_hub_page.dart';

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

  /// [v0.1.42] 从知识库范围选择课文并直接弹出跟读 BottomSheet
  Future<void> _openFollowPractice(BuildContext context) async {
    final scope = await KnowledgeScopePicker.show(context);
    if (scope == null || !context.mounted) return;

    final db = await DatabaseProvider.database;
    // 优先从 SentenceDao 获取句子
    final sentenceDao = SentenceDao(db);
    var sentences = await sentenceDao.getByBook(scope.bookId);
    if (scope.page != null && scope.page! > 0) {
      sentences = sentences.where((s) => s.page == scope.page).toList();
    }
    if (scope.chapter != null && scope.chapter! > 0) {
      sentences = sentences.where((s) => s.chapter == scope.chapter).toList();
    }

    String? targetSentence;
    if (sentences.isNotEmpty) {
      targetSentence = sentences.first.text;
    } else {
      // 兜底从 KnowledgePointDao 获取
      final kpDao = KnowledgePointDao(db);
      final points = await kpDao.getByBook(scope.bookId);
      if (points.isNotEmpty) {
        targetSentence = points.first.text;
      }
    }

    if (targetSentence == null || targetSentence.trim().isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('所选范围内暂无可用句子')));
      }
      return;
    }

    if (!context.mounted) return;
    await FollowSheetContent.show(
      context,
      sentence: targetSentence,
      bookId: scope.bookId,
      bookTitle: scope.bookTitle,
      pageNumber: scope.page,
    );
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
