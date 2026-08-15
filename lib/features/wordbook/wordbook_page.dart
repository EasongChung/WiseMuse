import 'package:flutter/material.dart';

import '../../core/debug/app_log.dart';
import '../../core/models/knowledge_point.dart';
import '../../core/models/word_entry.dart';
import '../../core/storage/database.dart';
import '../../core/storage/knowledge_point_dao.dart';
import '../../core/storage/word_entry_dao.dart';
import '../../core/theme/app_theme.dart';
import '../../widgets/review_card.dart';
import '../../widgets/knowledge_scope_picker.dart';
import '../stats/stats_page.dart';
import '../../services/spaced_repetition_service.dart';

/// [v0.1.0] 生词本页面：查看、复习、管理已标记的词语。
///
/// AppBar 含「复习」按钮进入复习模式（[ReviewCard] 逐个浏览）。
/// 列表按掌握度升序 → 优先展示未掌握词。
class WordBookPage extends StatefulWidget {
  const WordBookPage({super.key});

  @override
  State<WordBookPage> createState() => _WordBookPageState();
}

class _WordBookPageState extends State<WordBookPage> {
  static const _tag = 'wordbook';

  List<WordEntry> _words = const [];
  int _dueCount = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final db = await DatabaseProvider.database;
      final list = await WordEntryDao(db).getAll();
      final due = await SpacedRepetitionService.getDueWords();
      if (!mounted) return;
      setState(() {
        _words = list;
        _dueCount = due.length;
        _loading = false;
      });
    } catch (e, s) {
      AppLog.e(_tag, '加载生词本失败: $e\n$s');
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _deleteWord(WordEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('移出生词本'),
            content: Text('确定移除「${entry.word}」？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                style: FilledButton.styleFrom(
                  backgroundColor: StudyPalette.ember,
                ),
                child: const Text('移除'),
              ),
            ],
          ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final db = await DatabaseProvider.database;
      await WordEntryDao(db).delete(entry.id);
      AppLog.d(_tag, '移除生词: ${entry.word}');
      await _refresh();
    } catch (e) {
      AppLog.e(_tag, '移除生词失败: $e');
    }
  }

  void _openReview() {
    if (_words.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder:
            (_) => ReviewCard(
              words: _words,
              onComplete: () {
                AppLog.d(_tag, '复习完成');
                _refresh();
              },
            ),
      ),
    );
  }

  /// [v2.11.0] 从知识库选择范围进行复习。
  Future<void> _openKnowledgeReview() async {
    final scope = await KnowledgeScopePicker.show(context);
    if (scope == null || !mounted) return;
    try {
      final db = await DatabaseProvider.database;
      final dao = KnowledgePointDao(db);
      final points = await dao.getByBook(scope.bookId);
      var filtered = points;
      if (scope.chapter != null && scope.chapter! > 0) {
        filtered = filtered.where((p) => p.chapter == scope.chapter).toList();
      }
      if (scope.page != null && scope.page! > 0) {
        filtered = filtered.where((p) => p.page == scope.page).toList();
      }
      final unmastered = filtered.where((p) => p.mastery < 3).toList();
      if (unmastered.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('该范围无不掌握知识点')));
        }
        return;
      }
      final entries =
          unmastered
              .map(
                (p) => WordEntry.create(
                  word: p.text,
                  lang: p.type == KnowledgeType.english ? 'en' : 'zh',
                  fromBookId: p.bookId,
                ),
              )
              .toList();
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder:
              (_) => ReviewCard(
                words: entries,
                onComplete: () {
                  AppLog.d(_tag, '知识库复习完成');
                },
              ),
        ),
      );
    } catch (e) {
      AppLog.e(_tag, '加载知识库复习失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('生词本'),
        actions: [
          IconButton(
            tooltip: '学习统计',
            icon: const Icon(Icons.insights_outlined),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const StatsPage()),
              );
            },
          ),
          if (_words.isNotEmpty)
            IconButton(
              tooltip: '复习',
              icon: const Icon(Icons.autorenew_outlined),
              onPressed: _openReview,
            ),
          // [v2.11.0] 从知识库复习
          IconButton(
            tooltip: '从知识库复习',
            icon: const Icon(Icons.auto_stories_outlined),
            onPressed: _openKnowledgeReview,
          ),
        ],
      ),
      body:
          _loading
              ? const Center(child: CircularProgressIndicator())
              : _words.isEmpty
              ? _buildEmpty()
              : Column(
                children: [_buildDueCard(), Expanded(child: _buildList())],
              ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.menu_book_outlined,
            size: 64,
            color: StudyPalette.inkSoft.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          Text('生词本空空如也', style: titleStyle(fontSize: 18)),
          const SizedBox(height: 8),
          const Text(
            '在阅读页标记生词，或跟读分 <80 后自动加入',
            style: TextStyle(color: StudyPalette.inkSoft),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildDueCard() {
    if (_dueCount <= 0) return const SizedBox.shrink();
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      color: StudyPalette.ember.withValues(alpha: 0.1),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _openReview,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Icon(Icons.autorenew, color: StudyPalette.ember, size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '今日待复习',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: StudyPalette.ember,
                      ),
                    ),
                    Text(
                      '$_dueCount 个词到期，点击开始复习',
                      style: const TextStyle(
                        fontSize: 13,
                        color: StudyPalette.inkSoft,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.arrow_forward_ios,
                size: 16,
                color: StudyPalette.ember,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildList() {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
      itemCount: _words.length,
      itemBuilder: (context, index) {
        final entry = _words[index];
        return _WordCard(entry: entry, onDelete: () => _deleteWord(entry));
      },
    );
  }
}

/// 生词卡片：词 + 掌握度星标 + 来源教材 + 长按删除。
class _WordCard extends StatelessWidget {
  const _WordCard({required this.entry, required this.onDelete});

  final WordEntry entry;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final masteryColor =
        entry.mastery >= 4
            ? StudyPalette.moss
            : entry.mastery >= 2
            ? StudyPalette.ember
            : StudyPalette.inkSoft;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: StudyPalette.surfaceWithAlpha(context, alpha: 0.8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onLongPress: onDelete,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              // 掌握度星标
              Container(
                width: 40,
                alignment: Alignment.center,
                child: Text(
                  _masteryEmoji(entry.mastery),
                  style: const TextStyle(fontSize: 20),
                ),
              ),
              const SizedBox(width: 12),
              // 词内容
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.word,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: StudyPalette.ink,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '掌握度 ${entry.mastery}/5  ·  '
                      '错 ${entry.wrongCount} 次'
                      '${entry.fromBookId != null ? '  ·  来自教材' : ''}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: StudyPalette.inkSoft,
                      ),
                    ),
                  ],
                ),
              ),
              // 掌握度色条
              Container(
                width: 4,
                height: 36,
                decoration: BoxDecoration(
                  color: masteryColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _masteryEmoji(int m) {
    if (m >= 4) return '💪';
    if (m >= 2) return '📖';
    return '🔴';
  }
}
