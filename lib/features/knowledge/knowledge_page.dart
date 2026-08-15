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

/// [v0.3.0] [v2.11.0] 知识库页：三级钻取 书→单元→课/页→知识点。
///
/// 顶部 Chips 筛选类型，主体按书/单元/课三层展开浏览，FAB 添加。
class KnowledgePage extends StatefulWidget {
  const KnowledgePage({super.key});

  @override
  State<KnowledgePage> createState() => _KnowledgePageState();
}

class _KnowledgePageState extends State<KnowledgePage> {
  static const _tag = 'knowledge';

  KnowledgeType? _filterType;
  List<Book> _books = const [];
  Map<String, Map<int, Map<int, List<KnowledgePoint>>>> _groupedPoints =
      const {};
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

      // 按 bookId → chapter(单元) → page(课/页) 三级分组
      final grouped = <String, Map<int, Map<int, List<KnowledgePoint>>>>{};
      for (final p in allPoints) {
        final bookId = p.bookId ?? '';
        final unitMap = grouped.putIfAbsent(bookId, () => {});
        final pageMap = unitMap.putIfAbsent(p.chapter ?? 0, () => {});
        pageMap.putIfAbsent(p.page ?? 0, () => []).add(p);
      }

      if (!mounted) return;
      setState(() {
        _books = books;
        _groupedPoints = grouped;
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

  /// 单元标签（chapter=0 表示无单元分配）。
  String _unitLabel(int chapter) => chapter <= 0 ? '未分类' : '第 $chapter 单元';

  /// 课/页标签（page=0 表示无页码）。
  String _pageLabel(int page) => page <= 0 ? '通用' : '第 $page 课';

  /// 统计叶子知识点数。
  int _countPoints(Map<int, Map<int, List<KnowledgePoint>>> unitMap) {
    var count = 0;
    for (final pageMap in unitMap.values) {
      for (final points in pageMap.values) {
        count += points.length;
      }
    }
    return count;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('知识库')),
      body:
          _loading
              ? const Center(child: CircularProgressIndicator())
              : Column(
                children: [
                  _buildFilterChips(),
                  const Divider(height: 1),
                  Expanded(child: _buildKnowledgeTree()),
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

  /// 知识库树：书 → 单元 → 课/页 → 知识点条目。
  Widget _buildKnowledgeTree() {
    if (_groupedPoints.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.psychology_outlined,
              size: 48,
              color: StudyPalette.inkSoft,
            ),
            const SizedBox(height: 12),
            const Text(
              '知识库暂无内容',
              style: TextStyle(color: StudyPalette.inkSoft),
            ),
            const SizedBox(height: 4),
            const Text(
              '通过「添加」手动录入或使用 AI 提取',
              style: TextStyle(fontSize: 12, color: StudyPalette.inkSoft),
            ),
          ],
        ),
      );
    }

    final sortedBooks =
        _books.where((b) => _groupedPoints.containsKey(b.id)).toList();
    final orphanKeys = _groupedPoints.keys.where(
      (k) => k.isEmpty || !_books.any((b) => b.id == k),
    );

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
      children: [
        // 已关联教材 → 三级钻取
        ...sortedBooks.map((book) => _buildBookSection(book)),
        // 未关联教材的知识点
        ...orphanKeys.map((key) => _buildOrphanSection(key)),
      ],
    );
  }

  /// 书层级：可展开显示单元列表。
  Widget _buildBookSection(Book book) {
    final unitMap = _groupedPoints[book.id] ?? {};
    if (unitMap.isEmpty) return const SizedBox.shrink();
    final totalPoints = _countPoints(unitMap);
    final sortedUnits =
        unitMap.entries.toList()..sort((a, b) => a.key.compareTo(b.key));

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: ExpansionTile(
        initiallyExpanded: false,
        leading: const Icon(
          Icons.library_books,
          size: 20,
          color: StudyPalette.spinePdf,
        ),
        title: Text(book.title, style: titleStyle(fontSize: 15)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: StudyPalette.parchmentDeep,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$totalPoints',
                style: const TextStyle(
                  fontSize: 12,
                  color: StudyPalette.inkSoft,
                ),
              ),
            ),
            const Icon(
              Icons.expand_more,
              size: 20,
              color: StudyPalette.inkSoft,
            ),
          ],
        ),
        children:
            sortedUnits
                .map((e) => _buildUnitSection(book.id, e.key, e.value))
                .toList(),
      ),
    );
  }

  /// 单元层级：可展开显示课/页列表。
  Widget _buildUnitSection(
    String bookId,
    int chapter,
    Map<int, List<KnowledgePoint>> pageMap,
  ) {
    final sortedPages =
        pageMap.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    var pageCount = 0;
    for (final points in pageMap.values) {
      pageCount += points.length;
    }

    return Padding(
      padding: const EdgeInsets.only(left: 16),
      child: ExpansionTile(
        leading: const Icon(
          Icons.folder_outlined,
          size: 18,
          color: StudyPalette.ember,
        ),
        title: Text(
          _unitLabel(chapter),
          style: const TextStyle(fontSize: 14, color: StudyPalette.ink),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: StudyPalette.emberSoft.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '$pageCount',
                style: const TextStyle(fontSize: 11, color: StudyPalette.ember),
              ),
            ),
            const Icon(
              Icons.expand_more,
              size: 18,
              color: StudyPalette.inkSoft,
            ),
          ],
        ),
        children:
            sortedPages
                .map((e) => _buildPageSection(bookId, chapter, e.key, e.value))
                .toList(),
      ),
    );
  }

  /// 课/页层级：知识点条目列表。
  Widget _buildPageSection(
    String bookId,
    int chapter,
    int page,
    List<KnowledgePoint> points,
  ) {
    return Padding(
      padding: const EdgeInsets.only(left: 32),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.only(left: 8, right: 4),
        leading: const Icon(
          Icons.description_outlined,
          size: 16,
          color: StudyPalette.spineWord,
        ),
        title: Text(
          _pageLabel(page),
          style: const TextStyle(fontSize: 13, color: StudyPalette.inkSoft),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: StudyPalette.mossSoft.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '${points.length}',
                style: const TextStyle(fontSize: 11, color: StudyPalette.moss),
              ),
            ),
            const Icon(
              Icons.expand_more,
              size: 16,
              color: StudyPalette.inkSoft,
            ),
          ],
        ),
        children: points.map((p) => _buildKnowledgeTile(p)).toList(),
      ),
    );
  }

  /// 未关联教材的知识点。
  Widget _buildOrphanSection(String bookId) {
    final unitMap = _groupedPoints[bookId] ?? {};
    if (unitMap.isEmpty) return const SizedBox.shrink();

    // 拍平所有知识点
    final points = <KnowledgePoint>[];
    for (final pageMap in unitMap.values) {
      for (final lst in pageMap.values) {
        points.addAll(lst);
      }
    }
    if (points.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Icon(
                Icons.bookmark_border,
                size: 18,
                color: StudyPalette.inkSoft,
              ),
              const SizedBox(width: 6),
              Text(
                '其他',
                style: titleStyle(fontSize: 15, color: StudyPalette.inkSoft),
              ),
            ],
          ),
        ),
        ...points.map((p) => _buildKnowledgeTile(p)),
        const SizedBox(height: 4),
      ],
    );
  }

  /// 单个知识点条目（与之前一致）。
  Widget _buildKnowledgeTile(KnowledgePoint kp) {
    return Card(
      margin: const EdgeInsets.only(bottom: 4),
      child: ListTile(
        dense: true,
        leading: Icon(
          _typeIcon(kp.type),
          color: _typeIconColor(kp.type),
          size: 22,
        ),
        title: Text(
          kp.text,
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            color: StudyPalette.ink,
          ),
        ),
        subtitle:
            kp.definition != null && kp.definition!.isNotEmpty
                ? Text(
                  kp.definition!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: StudyPalette.inkSoft,
                  ),
                )
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
      builder:
          (context) => SafeArea(
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
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('AI 提取功能即将推出')));
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('添加失败：$e')));
      }
    }
  }
}
