import 'package:flutter/material.dart';

import '../core/models/book.dart';
import '../core/models/knowledge_point.dart';
import '../core/storage/book_dao.dart';
import '../core/storage/database.dart';
import '../core/storage/knowledge_point_dao.dart';
import '../core/theme/app_theme.dart';

/// [v2.11.0] 知识库范围选择结果。
class KnowledgeScope {
  const KnowledgeScope({
    required this.bookId,
    required this.bookTitle,
    this.chapter,
    this.page,
  });

  final String bookId;
  final String bookTitle;
  final int? chapter;
  final int? page;

  /// 单元标签。
  String? get unitLabel =>
      chapter == null || chapter! <= 0 ? null : '第 $chapter 单元';

  /// 课/页标签。
  String? get lessonLabel => page == null || page! <= 0 ? null : '第 $page 课';
}

/// [v2.11.0] 三级范围选择弹窗：书→单元→课/页。
///
/// 返回 [KnowledgeScope] 或 null（取消）。
class KnowledgeScopePicker {
  static Future<KnowledgeScope?> show(BuildContext context) {
    return showModalBottomSheet<KnowledgeScope>(
      context: context,
      isScrollControlled: true,
      backgroundColor: StudyPalette.parchment,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => const _ScopePickerContent(),
    );
  }
}

class _ScopePickerContent extends StatefulWidget {
  const _ScopePickerContent();

  @override
  State<_ScopePickerContent> createState() => _ScopePickerContentState();
}

class _ScopePickerContentState extends State<_ScopePickerContent> {
  static const _tag = 'scope_picker';

  // 数据
  List<Book> _books = const [];
  Map<String, Map<int, Map<int, List<KnowledgePoint>>>> _grouped = const {};
  bool _loading = true;

  // 选中状态（层级下标）
  String? _selectedBookId;
  int? _selectedChapter;
  int? _selectedPage;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final db = await DatabaseProvider.database;
      final books = await BookDao(db).getAll();
      final dao = KnowledgePointDao(db);
      final allPoints = await dao.getAll();

      final grouped = <String, Map<int, Map<int, List<KnowledgePoint>>>>{};
      for (final p in allPoints) {
        final bookId = p.bookId ?? '';
        final unitMap = grouped.putIfAbsent(bookId, () => {});
        final pageMap = unitMap.putIfAbsent(p.chapter ?? 0, () => {});
        pageMap.putIfAbsent(p.page ?? 0, () => []).add(p);
      }

      if (!mounted) return;
      setState(() {
        _books = books.where((b) => grouped.containsKey(b.id)).toList();
        _grouped = grouped;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _confirm() {
    if (_selectedBookId == null) return;
    final book = _books.firstWhere((b) => b.id == _selectedBookId);
    Navigator.of(context).pop(
      KnowledgeScope(
        bookId: book.id,
        bookTitle: book.title,
        chapter: _selectedChapter,
        page: _selectedPage,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.55,
      child: Column(
        children: [
          // 拖拽指示器
          Center(
            child: Container(
              width: 32,
              height: 4,
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              decoration: BoxDecoration(
                color: StudyPalette.linen,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              children: [
                Text('选择练习范围', style: titleStyle(fontSize: 16)),
                const Spacer(),
                if (_selectedBookId != null)
                  TextButton(
                    onPressed: _confirm,
                    child: const Text('确定', style: TextStyle(fontSize: 14)),
                  )
                else
                  TextButton.icon(
                    icon: const Icon(Icons.close, size: 16),
                    label: const Text('取消', style: TextStyle(fontSize: 12)),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (_loading)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else
            Expanded(child: _buildSelection()),
        ],
      ),
    );
  }

  Widget _buildSelection() {
    if (_selectedBookId == null) return _buildBookList();
    if (_selectedChapter == null) return _buildUnitList();
    return _buildLessonList();
  }

  Widget _buildBookList() {
    if (_books.isEmpty) {
      return const Center(
        child: Text('知识库暂无内容', style: TextStyle(color: StudyPalette.inkSoft)),
      );
    }
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      children:
          _books.map((book) {
            final unitMap = _grouped[book.id] ?? {};
            return ListTile(
              leading: const Icon(
                Icons.library_books,
                color: StudyPalette.spinePdf,
              ),
              title: Text(
                book.title,
                style: const TextStyle(color: StudyPalette.ink),
              ),
              trailing: const Icon(
                Icons.chevron_right,
                color: StudyPalette.inkSoft,
              ),
              onTap: () => setState(() => _selectedBookId = book.id),
            );
          }).toList(),
    );
  }

  Widget _buildUnitList() {
    final unitMap = _grouped[_selectedBookId!] ?? {};
    final sorted =
        unitMap.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    return Column(
      children: [
        // 返回上一级
        ListTile(
          dense: true,
          leading: const Icon(
            Icons.arrow_back,
            size: 18,
            color: StudyPalette.ember,
          ),
          title: Text(
            '返回选书',
            style: TextStyle(fontSize: 13, color: StudyPalette.ember),
          ),
          onTap: () => setState(() => _selectedBookId = null),
        ),
        const Divider(height: 1),
        // 「全部单元」选项
        ListTile(
          title: const Text('全部单元', style: TextStyle(color: StudyPalette.ink)),
          trailing: const Icon(
            Icons.chevron_right,
            color: StudyPalette.inkSoft,
          ),
          onTap: () => setState(() => _selectedChapter = 0),
        ),
        ...sorted.map((e) {
          final label = e.key <= 0 ? '未分类' : '第 ${e.key} 单元';
          return ListTile(
            title: Text(label, style: const TextStyle(color: StudyPalette.ink)),
            trailing: const Icon(
              Icons.chevron_right,
              color: StudyPalette.inkSoft,
            ),
            onTap: () => setState(() => _selectedChapter = e.key),
          );
        }),
      ],
    );
  }

  Widget _buildLessonList() {
    final unitMap = _grouped[_selectedBookId!] ?? {};
    final pageMap = unitMap[_selectedChapter!] ?? {};
    final sorted =
        pageMap.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    return Column(
      children: [
        ListTile(
          dense: true,
          leading: const Icon(
            Icons.arrow_back,
            size: 18,
            color: StudyPalette.ember,
          ),
          title: Text(
            '返回选单元',
            style: TextStyle(fontSize: 13, color: StudyPalette.ember),
          ),
          onTap: () => setState(() => _selectedChapter = null),
        ),
        const Divider(height: 1),
        // 「全部课」选项
        ListTile(
          title: const Text('全部课/页', style: TextStyle(color: StudyPalette.ink)),
          onTap: () {
            setState(() => _selectedPage = 0);
            _confirm();
          },
        ),
        ...sorted.map((e) {
          final label = e.key <= 0 ? '通用' : '第 ${e.key} 课';
          return ListTile(
            title: Text(label, style: const TextStyle(color: StudyPalette.ink)),
            subtitle: Text(
              '${e.value.length} 个知识点',
              style: const TextStyle(fontSize: 11, color: StudyPalette.inkSoft),
            ),
            onTap: () {
              setState(() => _selectedPage = e.key);
              _confirm();
            },
          );
        }),
      ],
    );
  }
}
