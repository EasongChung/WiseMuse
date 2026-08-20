import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/debug/app_log.dart';
import '../../core/models/book.dart';
import '../../core/storage/book_dao.dart';
import '../../core/storage/database.dart';
import '../../core/theme/app_theme.dart';
import '../../services/rag/embedding_service.dart';
import '../../services/rag/rag_retrieval_service.dart';
import '../../services/rag/vector_index.dart';
import '../../widgets/top_toast.dart';

/// [v0.1.50] RAG 知识库独立管理页面（位于「我的」中心）：
/// 支持查看每本书籍的向量化索引状态、一键构建/重新构建 RAG 索引、清理索引。
class RagManagementPage extends StatefulWidget {
  const RagManagementPage({super.key});

  @override
  State<RagManagementPage> createState() => _RagManagementPageState();
}

class _RagManagementPageState extends State<RagManagementPage> {
  static const _tag = 'rag_mgmt';

  List<Book> _books = [];
  Map<String, bool> _indexStatus = {};
  Map<String, int> _chunkCounts = {};
  final Set<String> _busyBookIds = {};
  bool _loading = true;
  bool _cloudReady = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final db = await DatabaseProvider.database;
      final books = await BookDao(db).getAll();
      final status = await RagRetrievalService.instance.getIndexStatus(books);
      final ready = await EmbeddingService.instance.isCloudReady();

      final counts = <String, int>{};
      for (final b in books) {
        if (status[b.id] == true) {
          final chunks = await VectorIndex.instance.loadIndex(b.id);
          counts[b.id] = chunks.length;
        }
      }

      if (!mounted) return;
      setState(() {
        _books = books;
        _indexStatus = status;
        _chunkCounts = counts;
        _cloudReady = ready;
        _loading = false;
      });
    } catch (e, s) {
      AppLog.e(_tag, '加载 RAG 知识库管理页失败: $e\n$s');
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _buildIndex(Book book) async {
    if (_busyBookIds.contains(book.id)) return;
    setState(() => _busyBookIds.add(book.id));

    try {
      AppLog.d(_tag, '开始构建 RAG 向量索引: ${book.title}');
      final count = await RagRetrievalService.instance.buildIndex(book);
      if (!mounted) return;
      if (count > 0) {
        TopToast.show(context, '✅ 《${book.title}》RAG 索引构建成功（$count 个片段）');
      } else {
        TopToast.show(context, '⚠️ 《${book.title}》无可索引内容或构建未产生片段');
      }
      await _load();
    } catch (e) {
      if (mounted) {
        TopToast.show(context, '❌ 构建索引失败: $e');
      }
    } finally {
      if (mounted) setState(() => _busyBookIds.remove(book.id));
    }
  }

  Future<void> _deleteIndex(Book book) async {
    final ok = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('清理 RAG 索引'),
            content: Text(
              '确定要清除《${book.title}》的向量知识库索引吗？\n（书籍正文与句子保留，随时可重新构建）',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: StudyPalette.ember,
                ),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('清除'),
              ),
            ],
          ),
    );
    if (ok != true || !mounted) return;

    setState(() => _busyBookIds.add(book.id));
    try {
      await RagRetrievalService.instance.deleteIndex(book.id);
      if (!mounted) return;
      TopToast.show(context, '已清除《${book.title}》的向量索引');
      await _load();
    } finally {
      if (mounted) setState(() => _busyBookIds.remove(book.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('RAG 向量知识库')),
      body:
          _loading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
                  children: [
                    _buildInfoCard(),
                    const SizedBox(height: 16),
                    Text('书籍知识库列表', style: titleStyle(fontSize: 16)),
                    const SizedBox(height: 8),
                    if (_books.isEmpty)
                      _buildEmptyState()
                    else
                      ..._books.map((b) => _buildBookCard(b)),
                  ],
                ),
              ),
    );
  }

  Widget _buildInfoCard() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? StudyPalette.darkCard : StudyPalette.parchmentDeep,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isDark ? StudyPalette.darkBorder : StudyPalette.linen,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.psychology, color: StudyPalette.ember, size: 22),
              const SizedBox(width: 8),
              Text('RAG 知识库检索说明', style: titleStyle(fontSize: 15)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color:
                      _cloudReady
                          ? StudyPalette.moss.withValues(alpha: 0.15)
                          : StudyPalette.ember.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _cloudReady ? 'Embedding 就绪' : '未配置 Embedding',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: _cloudReady ? StudyPalette.moss : StudyPalette.ember,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'RAG（检索增强生成）将书籍课文切片为向量，使「问AI」能够在解答时准确引用课本原文，避免 AI 幻觉。\n未配置云端向量模型时，将自动使用本地文本关键词评分降级检索。',
            style: TextStyle(
              fontSize: 12,
              color: StudyPalette.inkSoft,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
        child: Center(
          child: Column(
            children: [
              const Icon(
                Icons.auto_stories_outlined,
                size: 40,
                color: StudyPalette.inkSoft,
              ),
              const SizedBox(height: 10),
              Text('书架暂无书籍', style: titleStyle(fontSize: 15)),
              const SizedBox(height: 4),
              const Text(
                '请先前往「书架」导入课本、文档或图片',
                style: TextStyle(fontSize: 12, color: StudyPalette.inkSoft),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBookCard(Book book) {
    final isIndexed = _indexStatus[book.id] ?? false;
    final chunkCount = _chunkCounts[book.id] ?? 0;
    final isBusy = _busyBookIds.contains(book.id);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: StudyPalette.linen),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: StudyPalette.spineFor(
                  book.source,
                ).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                Icons.menu_book,
                color: StudyPalette.spineFor(book.source),
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    book.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(
                        isIndexed
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        size: 14,
                        color:
                            isIndexed
                                ? StudyPalette.moss
                                : StudyPalette.inkSoft,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        isIndexed ? '已构建知识库 ($chunkCount 个片段)' : '未构建知识库',
                        style: TextStyle(
                          fontSize: 12,
                          color:
                              isIndexed
                                  ? StudyPalette.moss
                                  : StudyPalette.inkSoft,
                          fontWeight:
                              isIndexed ? FontWeight.w500 : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (isBusy)
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else if (isIndexed)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: () => _buildIndex(book),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                    child: const Text('重新构建'),
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.delete_outline,
                      size: 18,
                      color: StudyPalette.ember,
                    ),
                    tooltip: '清除索引',
                    onPressed: () => _deleteIndex(book),
                  ),
                ],
              )
            else
              FilledButton.tonal(
                onPressed: () => _buildIndex(book),
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  textStyle: const TextStyle(fontSize: 12),
                ),
                child: const Text('构建索引'),
              ),
          ],
        ),
      ),
    );
  }
}
