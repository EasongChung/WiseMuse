import 'package:flutter/material.dart';

import '../../core/debug/app_log.dart';
import '../../core/models/book.dart';
import '../../core/models/knowledge_point.dart';
import '../../core/storage/book_dao.dart';
import '../../core/storage/database.dart';
import '../../core/storage/knowledge_point_dao.dart';
import '../../core/theme/app_theme.dart';
import 'knowledge_detail_sheet.dart';
import 'knowledge_edit_sheet.dart';

/// [v0.3.0] 知识库页：按类型筛选 + 按书浏览 + FAB 提取/手动添加。
///
/// 顶部 Chips 筛选类型，下部按书分组展示知识点列表。
class KnowledgePage extends StatefulWidget {
  const KnowledgePage({super.key});

  @override
  State<KnowledgePage> createState() => _KnowledgePageState();
}

class _KnowledgePageState extends State<KnowledgePage> {
  static const _tag = 'knowledge';

  KnowledgeType? _filterType;
  List<Book> _books = const [];
  Map<String, List<KnowledgePoint>> _bookPoints = const {};
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
      final dao = KnowledgePointDao(db);
      final allPoints = await dao.getAll(type: _filterType);

      // 按 bookId 分组
      final grouped = <String, List<KnowledgePoint>>{};
      for (final p in allPoints) {
        grouped.putIfAbsent(p.bookId ?? '', () => []).add(p);
      }

      if (!mounted) return;
      setState(() {
        _books = books;
        _bookPoints = grouped;
        _loading = false;
      });
    } catch (e, s) {
      AppLog.e(_tag, '加载知识库失败: $e\n$s');
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Color _typeIconColor(KnowledgeType type) {
    switch (type) {
      case KnowledgeType.word:
        return StudyPalette.ember;
      case KnowledgeType.idiom:
        return StudyPalette.spinePdf;
      case KnowledgeType.english:
        return StudyPalette.spineWord;
      case KnowledgeType.poem:
        return StudyPalette.spineTxt;
    }
  }

  IconData _typeIcon(KnowledgeType type) {
    switch (type) {
      case KnowledgeType.word:
        return Icons.text_fields;
      case KnowledgeType.idiom:
        return Icons.auto_awesome;
      case KnowledgeType.english:
        return Icons.translate;
      case KnowledgeType.poem:
        return Icons.auto_stories;
    }
  }

  String _masteryLabel(int mastery) {
    if (mastery <= 0) return '未掌握';
    if (mastery <= 2) return '生疏';
    if (mastery <= 4) return '熟悉';
    return '已掌握';
  }

  Color _masteryColor(int mastery) {
    if (mastery <= 0) return StudyPalette.ember;
    if (mastery <= 2) return StudyPalette.emberSoft;
    if (mastery <= 4) return StudyPalette.mossSoft;
    return StudyPalette.moss;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('知识库')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _buildFilterChips(),
                const Divider(height: 1),
                Expanded(child: _buildKnowledgeList()),
              ],
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddMenu,
        icon: const Icon(Icons.add),
        label: const Text(
          '添加',
          style: TextStyle(fontFamily: 'ZCOOLKuaiLe', fontSize: 16),
        ),
      ),
    );
  }

  Widget _buildFilterChips() {
    const allTypes = <KnowledgeType?>[
      null,
      KnowledgeType.word,
      KnowledgeType.idiom,
      KnowledgeType.english,
      KnowledgeType.poem,
    ];
    const typeLabels = <String>['全部', '词语', '成语', '英语', '诗词'];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: List.generate(allTypes.length, (i) {
            final selected = _filterType == allTypes[i];
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                label: Text(typeLabels[i]),
                selected: selected,
                onSelected: (_) {
                  setState(() {
                    _filterType = allTypes[i];
                    _loading = true;
                  });
                  _load();
                },
              ),
            );
          }),
        ),
      ),
    );
  }

  Widget _buildKnowledgeList() {
    if (_bookPoints.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.psychology_outlined,
                size: 48, color: StudyPalette.inkSoft),
            const SizedBox(height: 12),
            const Text('知识库暂无内容',
                style: TextStyle(color: StudyPalette.inkSoft)),
            const SizedBox(height: 4),
            const Text('通过「添加」手动录入或使用 AI 提取',
                style: TextStyle(fontSize: 12, color: StudyPalette.inkSoft)),
          ],
        ),
      );
    }

    final sortedBooks = _books.where((b) => _bookPoints.containsKey(b.id)).toList();
    // 未关联教材的知识点（bookId=''或不在 _books 中）
    final orphanKeys =
        _bookPoints.keys.where((k) => k.isEmpty || !_books.any((b) => b.id == k));

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
      children: [
        // 已关联教材的分组
        ...sortedBooks.map((book) => _buildBookSection(book)),
        // 未关联教材的知识点
        ...orphanKeys.map((key) => _buildOrphanSection(key)),
      ],
    );
  }

  Widget _buildBookSection(Book book) {
    final points = _bookPoints[book.id] ?? [];
    if (points.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Icon(Icons.library_books, size: 18, color: StudyPalette.spinePdf),
              const SizedBox(width: 6),
              Text(book.title, style: titleStyle(fontSize: 15)),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: StudyPalette.parchmentDeep,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${points.length}',
                  style: const TextStyle(
                      fontSize: 12, color: StudyPalette.inkSoft),
                ),
              ),
            ],
          ),
        ),
        ...points.map((p) => _buildKnowledgeTile(p)),
        const SizedBox(height: 4),
      ],
    );
  }

  Widget _buildOrphanSection(String bookId) {
    final points = _bookPoints[bookId] ?? [];
    if (points.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Icon(Icons.bookmark_border,
                  size: 18, color: StudyPalette.inkSoft),
              const SizedBox(width: 6),
              Text('其他', style: titleStyle(fontSize: 15, color: StudyPalette.inkSoft)),
            ],
          ),
        ),
        ...points.map((p) => _buildKnowledgeTile(p)),
        const SizedBox(height: 4),
      ],
    );
  }

  Widget _buildKnowledgeTile(KnowledgePoint kp) {
    return Card(
      margin: const EdgeInsets.only(bottom: 4),
      child: ListTile(
        dense: true,
        leading: Icon(_typeIcon(kp.type),
            color: _typeIconColor(kp.type), size: 22),
        title: Text(kp.text,
            style: const TextStyle(
                fontWeight: FontWeight.w600, color: StudyPalette.ink)),
        subtitle: kp.definition != null && kp.definition!.isNotEmpty
            ? Text(kp.definition!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 12, color: StudyPalette.inkSoft))
            : null,
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: _masteryColor(kp.mastery),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            _masteryLabel(kp.mastery),
            style: TextStyle(fontSize: 11, color: StudyPalette.ink),
          ),
        ),
        onTap: () => _showDetail(kp),
      ),
    );
  }

  Future<void> _showDetail(KnowledgePoint kp) async {
    final result = await KnowledgeDetailSheet.show(context, kp);
    if (result == true) _load();
  }

  void _showAddMenu() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.auto_awesome),
              title: const Text('AI 提取知识点'),
              subtitle: const Text('从已有教材中自动提取'),
              onTap: () {
                Navigator.pop(context);
                _showAiExtract();
              },
            ),
            const Divider(height: 1, indent: 16),
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('手动添加'),
              subtitle: const Text('自行录入词语/成语/单词/诗词'),
              onTap: () {
                Navigator.pop(context);
                _showManualAdd();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showAiExtract() async {
    // TODO(S4+): 选书 → 调用 KnowledgeExtractionService.extractBook → 刷新
    // MVP 暂跳选书弹窗，提示功能开发中
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('AI 提取功能即将推出')),
    );
  }

  Future<void> _showManualAdd() async {
    final result = await KnowledgeEditSheet.show(context, books: _books);
    if (result != null && mounted) {
      try {
        final db = await DatabaseProvider.database;
        await KnowledgePointDao(db).insert(result);
        AppLog.d(_tag, '手动添加知识点: ${result.text}');
        _load();
      } catch (e, s) {
        AppLog.e(_tag, '添加知识点失败: $e\n$s');
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('添加失败：$e')),
        );
      }
    }
  }
}