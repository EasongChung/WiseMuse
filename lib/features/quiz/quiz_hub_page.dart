import 'package:flutter/material.dart';

import '../../core/debug/app_log.dart';
import '../../core/models/book.dart';
import '../../core/storage/book_dao.dart';
import '../../core/storage/database.dart';
import '../../core/theme/app_theme.dart';
import 'quiz_page.dart';

/// [v0.3.0] 测验首页：选书 → 选章 → 开始测验。
class QuizHubPage extends StatefulWidget {
  const QuizHubPage({super.key});

  @override
  State<QuizHubPage> createState() => _QuizHubPageState();
}

class _QuizHubPageState extends State<QuizHubPage> {
  static const _tag = 'quiz_hub';

  List<Book> _books = const [];
  Book? _selectedBook;
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
      if (!mounted) return;
      setState(() {
        _books = books;
        _loading = false;
      });
    } catch (e, s) {
      AppLog.e(_tag, '加载书籍列表失败: $e\n$s');
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  void _startQuiz() {
    if (_selectedBook == null) return;
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => QuizPage(book: _selectedBook!)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('章节测验')),
      body:
          _loading
              ? const Center(child: CircularProgressIndicator())
              : _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_books.isEmpty) {
      return const Center(
        child: Text(
          '暂无书籍，请先导入书籍',
          style: TextStyle(color: StudyPalette.inkSoft),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('选择题库', style: titleStyle(fontSize: 18)),
          const SizedBox(height: 16),
          Expanded(
            child: ListView.separated(
              itemCount: _books.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final book = _books[index];
                final selected = _selectedBook?.id == book.id;
                return Card(
                  child: ListTile(
                    leading: Icon(
                      Icons.library_books,
                      color:
                          selected ? StudyPalette.ember : StudyPalette.inkSoft,
                    ),
                    title: Text(book.title),
                    subtitle: Text(
                      '${book.pageCount ?? 0} 页',
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing:
                        selected
                            ? const Icon(
                              Icons.check_circle,
                              color: StudyPalette.ember,
                            )
                            : null,
                    selected: selected,
                    onTap: () => setState(() => _selectedBook = book),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _selectedBook != null ? _startQuiz : null,
            icon: const Icon(Icons.play_arrow),
            label: const Text('开始测验'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
        ],
      ),
    );
  }
}
