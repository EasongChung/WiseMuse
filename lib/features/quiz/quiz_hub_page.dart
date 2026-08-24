import 'package:flutter/material.dart';

import '../../core/debug/app_log.dart';
import '../../core/models/book.dart';
import '../../core/storage/book_dao.dart';
import '../../core/storage/database.dart';
import '../../core/storage/knowledge_point_dao.dart';
import '../../core/storage/quiz_attempt_dao.dart';
import '../../core/storage/word_entry_dao.dart';
import '../../core/theme/app_theme.dart';
import '../../widgets/top_toast.dart';
import 'quiz_page.dart';
import 'quiz_scorer.dart';

/// 章节关卡元数据。
class ChapterQuizInfo {
  ChapterQuizInfo({
    required this.chapter,
    required this.pointCount,
    this.bestScore,
    this.attemptCount = 0,
  });

  final int chapter;
  final int pointCount;
  final double? bestScore;
  final int attemptCount;

  String get chapterName => chapter <= 0 ? '全书综合' : '第 $chapter 单元';
}

/// [v0.3.0] [v0.1.62] 章节测验首页：选书 → 单元关卡列表（含星级/历史高分） → 综合测验 / 错题强化特训。
class QuizHubPage extends StatefulWidget {
  const QuizHubPage({super.key});

  @override
  State<QuizHubPage> createState() => _QuizHubPageState();
}

class _QuizHubPageState extends State<QuizHubPage> {
  static const _tag = 'quiz_hub';

  List<Book> _books = const [];
  Book? _selectedBook;
  List<ChapterQuizInfo> _chapters = const [];
  int _wrongWordCount = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final db = await DatabaseProvider.database;
      final books = await BookDao(db).getAll();
      final wordDao = WordEntryDao(db);
      final unmastered = await wordDao.getUnmastered(threshold: 3);

      Book? selected = _selectedBook;
      if (selected == null && books.isNotEmpty) {
        selected = books.first;
      } else if (selected != null && !books.any((b) => b.id == selected?.id)) {
        selected = books.isNotEmpty ? books.first : null;
      }

      if (!mounted) return;
      setState(() {
        _books = books;
        _selectedBook = selected;
        _wrongWordCount = unmastered.length;
      });

      if (selected != null) {
        await _loadChaptersForBook(selected);
      } else {
        setState(() => _loading = false);
      }
    } catch (e, s) {
      AppLog.e(_tag, '加载书籍列表失败: $e\n$s');
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadChaptersForBook(Book book) async {
    try {
      final db = await DatabaseProvider.database;
      final kpDao = KnowledgePointDao(db);
      final attemptDao = QuizAttemptDao(db);

      final points = await kpDao.getByBook(book.id);
      final chapterMap = <int, int>{};
      for (final p in points) {
        final ch = p.chapter ?? 0;
        chapterMap[ch] = (chapterMap[ch] ?? 0) + 1;
      }

      final list = <ChapterQuizInfo>[];
      for (final entry in chapterMap.entries) {
        final ch = entry.key;
        final count = entry.value;
        final best = await attemptDao.bestByChapter(book.id, ch);
        final attempts = await attemptDao.countByChapter(book.id, ch);
        list.add(
          ChapterQuizInfo(
            chapter: ch,
            pointCount: count,
            bestScore: best?.totalScore,
            attemptCount: attempts,
          ),
        );
      }

      list.sort((a, b) => a.chapter.compareTo(b.chapter));

      if (mounted) {
        setState(() {
          _chapters = list;
          _loading = false;
        });
      }
    } catch (e) {
      AppLog.e(_tag, '加载章节测验状态失败: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  void _startQuiz({int? chapter, bool isWrongWordMode = false}) {
    if (_selectedBook == null && !isWrongWordMode) return;
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder:
                (_) => QuizPage(
                  book:
                      _selectedBook ??
                      Book(
                        id: 'wrong_words',
                        title: '错题强化特训',
                        source: BookSource.txt,
                        createdAt: 0,
                        updatedAt: 0,
                      ),
                  chapter: chapter,
                  isWrongWordMode: isWrongWordMode,
                ),
          ),
        )
        .then((_) => _load());
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(title: const Text('章节练习与测验')),
      body:
          _loading
              ? const Center(child: CircularProgressIndicator())
              : _books.isEmpty
              ? _buildEmptyState()
              : Column(
                children: [
                  _buildBookSelectorHeader(isDark),
                  Expanded(child: _buildChapterListView(isDark)),
                ],
              ),
    );
  }

  Widget _buildEmptyState() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.menu_book, size: 48, color: StudyPalette.inkSoft),
          SizedBox(height: 12),
          Text('暂无书籍，请先在书架导入教材', style: TextStyle(color: StudyPalette.inkSoft)),
        ],
      ),
    );
  }

  Widget _buildBookSelectorHeader(bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: isDark ? StudyPalette.darkCard : StudyPalette.parchmentDeep,
      child: Row(
        children: [
          const Icon(Icons.library_books, color: StudyPalette.ember, size: 20),
          const SizedBox(width: 8),
          const Text(
            '当前教材：',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                isExpanded: true,
                value: _selectedBook?.id,
                items:
                    _books.map((b) {
                      return DropdownMenuItem(
                        value: b.id,
                        child: Text(
                          b.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                      );
                    }).toList(),
                onChanged: (id) {
                  if (id == null) return;
                  final book = _books.firstWhere((b) => b.id == id);
                  setState(() {
                    _selectedBook = book;
                    _loading = true;
                  });
                  _loadChaptersForBook(book);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChapterListView(bool isDark) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 30),
      children: [
        // 顶部专项卡片行：全书综合测验 + 错词强化特训
        Row(
          children: [
            Expanded(
              child: _buildQuickActionCard(
                icon: Icons.track_changes,
                color: StudyPalette.ember,
                title: '全书综合测验',
                subtitle: '综合各单元知识点',
                onTap: () => _startQuiz(),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildQuickActionCard(
                icon: Icons.bolt,
                color: StudyPalette.spinePdf,
                title: '错题消灭特训',
                subtitle: '$_wrongWordCount 个待强化词',
                onTap:
                    _wrongWordCount > 0
                        ? () => _startQuiz(isWrongWordMode: true)
                        : () => TopToast.show(context, '太棒了！暂无待强化的错词'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            Text('单元关卡列表', style: titleStyle(fontSize: 16)),
            const Spacer(),
            Text(
              '共 ${_chapters.length} 个单元',
              style: const TextStyle(fontSize: 12, color: StudyPalette.inkSoft),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (_chapters.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text(
                '该书籍暂无章节知识点，可在知识库中先提取知识点',
                style: TextStyle(fontSize: 12, color: StudyPalette.inkSoft),
              ),
            ),
          )
        else
          ..._chapters.map((ch) => _buildChapterCard(ch, isDark)),
      ],
    );
  }

  Widget _buildQuickActionCard({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: color.withValues(alpha: 0.3)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: color, size: 20),
              ),
              const SizedBox(height: 8),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(
                  fontSize: 11,
                  color: StudyPalette.inkSoft,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildChapterCard(ChapterQuizInfo ch, bool isDark) {
    final bestScore = ch.bestScore;
    final stars = bestScore != null ? QuizScorer.starRating(bestScore) : 0;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: StudyPalette.linen),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: CircleAvatar(
          backgroundColor: StudyPalette.emberSoft,
          child: Text(
            '${ch.chapter <= 0 ? 0 : ch.chapter}',
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: StudyPalette.ember,
            ),
          ),
        ),
        title: Text(
          ch.chapterName,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        subtitle: Row(
          children: [
            Text(
              '${ch.pointCount} 个考点',
              style: const TextStyle(fontSize: 12, color: StudyPalette.inkSoft),
            ),
            const SizedBox(width: 8),
            if (ch.attemptCount > 0)
              Text(
                '· 已练 ${ch.attemptCount} 次',
                style: const TextStyle(
                  fontSize: 12,
                  color: StudyPalette.inkSoft,
                ),
              ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (bestScore != null) ...[
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: List.generate(5, (i) {
                      return Icon(
                        i < stars ? Icons.star : Icons.star_border,
                        size: 14,
                        color:
                            i < stars
                                ? StudyPalette.ember
                                : StudyPalette.inkSoft,
                      );
                    }),
                  ),
                  Text(
                    '最高 ${bestScore.toStringAsFixed(0)}分',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color:
                          bestScore >= 80
                              ? StudyPalette.moss
                              : StudyPalette.ember,
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 8),
            ],
            const Icon(
              Icons.arrow_forward_ios,
              size: 14,
              color: StudyPalette.inkSoft,
            ),
          ],
        ),
        onTap: () => _startQuiz(chapter: ch.chapter),
      ),
    );
  }
}
