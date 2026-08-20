import 'package:flutter/material.dart';

import '../../core/debug/app_log.dart';
import '../../core/models/book.dart';
import '../../core/models/knowledge_point.dart';
import '../../core/storage/book_dao.dart';
import '../../core/storage/database.dart';
import '../../core/storage/knowledge_point_dao.dart';
import '../../core/storage/sentence_dao.dart';
import '../../core/theme/app_theme.dart';
import '../../services/knowledge_extraction_service.dart';
import 'knowledge_detail_sheet.dart';
import 'knowledge_edit_sheet.dart';
import '../../widgets/top_toast.dart';

enum KnowledgeSortOrder {
  updatedAtDesc('最近更新'),
  titleAsc('书名 (A-Z)'),
  countDesc('知识点数量');

  const KnowledgeSortOrder(this.label);
  final String label;
}

/// [v0.3.0] [v0.1.49] 知识库页：直接按页组织（书→页→知识点），支持书籍条目下方进度条与后台提取。
class KnowledgePage extends StatefulWidget {
  const KnowledgePage({super.key});

  @override
  State<KnowledgePage> createState() => _KnowledgePageState();
}

class _KnowledgePageState extends State<KnowledgePage> {
  static const _tag = 'knowledge';

  KnowledgeType? _filterType;
  KnowledgeSortOrder _sortOrder = KnowledgeSortOrder.updatedAtDesc;
  List<Book> _books = const [];
  Map<String, Map<int, List<KnowledgePoint>>> _groupedPoints = const {};
  bool _loading = true;

  KnowledgeTaskProgress? _backgroundProgress;

  @override
  void initState() {
    super.initState();
    KnowledgeExtractionService.instance.addListener(_onProgressUpdate);
    _load();
  }

  @override
  void dispose() {
    KnowledgeExtractionService.instance.removeListener(_onProgressUpdate);
    super.dispose();
  }

  void _onProgressUpdate(KnowledgeTaskProgress p) {
    if (mounted) {
      setState(() => _backgroundProgress = p);
      if (!p.isRunning && p.done == p.total) {
        _load();
      }
    }
  }

  Future<void> _load() async {
    try {
      final db = await DatabaseProvider.database;
      var books = await BookDao(db).getAll();
      final dao = KnowledgePointDao(db);
      final allPoints = await dao.getAll(type: _filterType);

      // 直接按 bookId → page(页码) 分组（回落至按物理页组织）
      final grouped = <String, Map<int, List<KnowledgePoint>>>{};
      for (final p in allPoints) {
        final bookId = p.bookId ?? '';
        final pageMap = grouped.putIfAbsent(bookId, () => {});
        final page = (p.page != null && p.page! > 0) ? p.page! : 0;
        pageMap.putIfAbsent(page, () => []).add(p);
      }

      // 排序逻辑
      if (_sortOrder == KnowledgeSortOrder.titleAsc) {
        books.sort((a, b) => a.title.compareTo(b.title));
      } else if (_sortOrder == KnowledgeSortOrder.countDesc) {
        books.sort((a, b) {
          final countA = _countPoints(grouped[a.id] ?? const {});
          final countB = _countPoints(grouped[b.id] ?? const {});
          return countB.compareTo(countA);
        });
      } else {
        books.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
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

  String _pageLabel(int page) => page <= 0 ? '第 1 页' : '第 $page 页';

  int _countPoints(Map<int, List<KnowledgePoint>> pageMap) {
    var count = 0;
    for (final points in pageMap.values) {
      count += points.length;
    }
    return count;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('知识库'),
        actions: [
          PopupMenuButton<KnowledgeSortOrder>(
            icon: const Icon(Icons.sort),
            tooltip: '排序方式',
            onSelected: (order) {
              setState(() {
                _sortOrder = order;
                _loading = true;
              });
              _load();
            },
            itemBuilder:
                (context) => [
                  const PopupMenuItem(
                    value: KnowledgeSortOrder.updatedAtDesc,
                    child: Text('最近更新'),
                  ),
                  const PopupMenuItem(
                    value: KnowledgeSortOrder.titleAsc,
                    child: Text('书名 (A-Z)'),
                  ),
                  const PopupMenuItem(
                    value: KnowledgeSortOrder.countDesc,
                    child: Text('知识点数量'),
                  ),
                ],
          ),
        ],
      ),
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

  Widget _buildKnowledgeTree() {
    if (_groupedPoints.isEmpty &&
        (_backgroundProgress == null || !_backgroundProgress!.isRunning)) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.psychology_outlined,
              size: 48,
              color: StudyPalette.inkSoft,
            ),
            const SizedBox(height: 12),
            Text('知识库暂无内容', style: titleStyle(fontSize: 16)),
            const SizedBox(height: 6),
            const Text(
              '点击右下角「添加」提取或录入知识点',
              style: TextStyle(fontSize: 13, color: StudyPalette.inkSoft),
            ),
          ],
        ),
      );
    }

    final booksWithPoints = <Book>[];
    for (final b in _books) {
      if (_groupedPoints.containsKey(b.id) ||
          (_backgroundProgress?.bookId == b.id &&
              _backgroundProgress!.isRunning)) {
        booksWithPoints.add(b);
      }
    }
    for (final entry in _groupedPoints.entries) {
      if (!booksWithPoints.any((b) => b.id == entry.key)) {
        booksWithPoints.add(
          Book.create(
            title: entry.key.isEmpty ? '自定义录入' : '已删除书籍',
            source: BookSource.txt,
          ),
        );
      }
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 80),
      itemCount: booksWithPoints.length,
      itemBuilder: (context, index) {
        final book = booksWithPoints[index];
        final pageMap = _groupedPoints[book.id] ?? const {};
        final isExtracting =
            _backgroundProgress != null &&
            _backgroundProgress!.bookId == book.id &&
            _backgroundProgress!.isRunning;

        return _buildBookSection(book, pageMap, isExtracting);
      },
    );
  }

  Widget _buildBookSection(
    Book book,
    Map<int, List<KnowledgePoint>> pageMap,
    bool isExtracting,
  ) {
    final totalPoints = _countPoints(pageMap);
    final sortedPages =
        pageMap.entries.toList()..sort((a, b) => a.key.compareTo(b.key));

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: StudyPalette.linen),
      ),
      child: Column(
        children: [
          ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 12),
            leading: Icon(
              Icons.menu_book,
              color: StudyPalette.spineFor(book.source),
            ),
            title: Text(book.title, style: titleStyle(fontSize: 15)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
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
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert, size: 18),
                  onSelected: (action) async {
                    if (action == 'clear') {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder:
                            (ctx) => AlertDialog(
                              title: const Text('清空知识点'),
                              content: Text('确定要清空《${book.title}》的所有知识点吗？'),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, false),
                                  child: const Text('取消'),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, true),
                                  child: const Text(
                                    '清空',
                                    style: TextStyle(color: Colors.red),
                                  ),
                                ),
                              ],
                            ),
                      );
                      if (ok == true) {
                        final db = await DatabaseProvider.database;
                        await db.delete(
                          'knowledge_points',
                          where: 'book_id = ?',
                          whereArgs: [book.id],
                        );
                        _load();
                      }
                    } else if (action == 're_extract') {
                      KnowledgeExtractionService.instance.extractBook(book);
                      setState(() {});
                    }
                  },
                  itemBuilder:
                      (context) => [
                        const PopupMenuItem(
                          value: 're_extract',
                          child: Text('重新提取知识库'),
                        ),
                        const PopupMenuItem(
                          value: 'clear',
                          child: Text(
                            '清空本书知识点',
                            style: TextStyle(color: Colors.red),
                          ),
                        ),
                      ],
                ),
              ],
            ),
            children:
                sortedPages.isEmpty && !isExtracting
                    ? [
                      const Padding(
                        padding: EdgeInsets.all(12),
                        child: Text(
                          '暂无知识点，可点右侧更多按钮提取',
                          style: TextStyle(
                            fontSize: 12,
                            color: StudyPalette.inkSoft,
                          ),
                        ),
                      ),
                    ]
                    : sortedPages
                        .map((e) => _buildPageSection(book.id, e.key, e.value))
                        .toList(),
          ),
          if (isExtracting) _buildBookItemProgressBar(_backgroundProgress!),
        ],
      ),
    );
  }

  Widget _buildBookItemProgressBar(KnowledgeTaskProgress p) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
      decoration: const BoxDecoration(
        color: StudyPalette.parchmentDeep,
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '正在提取知识库: 第 ${p.done}/${p.total} 页 (发现 ${p.pointCount} 个知识点)',
                  style: const TextStyle(
                    fontSize: 12,
                    color: StudyPalette.ember,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: p.progress,
              minHeight: 4,
              backgroundColor: StudyPalette.linen,
              color: StudyPalette.ember,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPageSection(
    String bookId,
    int page,
    List<KnowledgePoint> points,
  ) {
    return Padding(
      padding: const EdgeInsets.only(left: 16),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.only(left: 8, right: 8),
        leading: const Icon(
          Icons.description_outlined,
          size: 16,
          color: StudyPalette.inkSoft,
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
                color: StudyPalette.parchmentDeep,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '${points.length}',
                style: const TextStyle(
                  fontSize: 10,
                  color: StudyPalette.inkSoft,
                ),
              ),
            ),
            const Icon(
              Icons.expand_more,
              size: 16,
              color: StudyPalette.inkSoft,
            ),
          ],
        ),
        children: points.map((p) => _buildPointTile(p)).toList(),
      ),
    );
  }

  Widget _buildPointTile(KnowledgePoint kp) {
    return Container(
      margin: const EdgeInsets.only(left: 32, right: 8, top: 2, bottom: 2),
      decoration: BoxDecoration(
        color: StudyPalette.parchment.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        leading: Icon(
          _typeIcon(kp.type),
          size: 16,
          color: _typeIconColor(kp.type),
        ),
        title: Text(
          kp.text,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle:
            kp.definition != null && kp.definition!.isNotEmpty
                ? Text(
                  kp.definition!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
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
            style: TextStyle(
              fontSize: 11,
              color: StudyPalette.onSurfaceResolved(context),
            ),
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
                  subtitle: const Text('从已有书籍中后台提取'),
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
    final db = await DatabaseProvider.database;
    final sentenceDao = SentenceDao(db);
    final booksWithSentences = <Book>[];
    for (final book in _books) {
      final count = await sentenceDao.countByBook(book.id);
      if (count > 0) booksWithSentences.add(book);
    }
    if (!mounted) return;

    if (booksWithSentences.isEmpty) {
      TopToast.show(context, '没有可提取的书籍（书籍中无句子内容）');
      return;
    }

    final book = await showDialog<Book>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('选择书籍'),
            content: SizedBox(
              width: double.maxFinite,
              child: ListView(
                shrinkWrap: true,
                children:
                    booksWithSentences.map((b) {
                      return ListTile(
                        title: Text(b.title),
                        onTap: () => Navigator.pop(ctx, b),
                      );
                    }).toList(),
              ),
            ),
          ),
    );
    if (book == null || !mounted) return;

    KnowledgeExtractionService.instance.extractBook(book);
    TopToast.show(context, '已启动《${book.title}》后台提取知识点');
  }

  Future<void> _showManualAdd() async {
    final result = await KnowledgeEditSheet.show(context);
    if (result != null) _load();
  }
}
