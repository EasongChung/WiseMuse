import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/debug/app_log.dart';
import '../../core/models/book.dart';
import '../../core/storage/book_dao.dart';
import '../../core/storage/database.dart';
import '../../core/theme/app_theme.dart';
import '../../services/book_import_service.dart';
import '../../services/picker_service.dart';
import '../../services/rag/rag_retrieval_service.dart';
import '../../widgets/import_sheet.dart';
import '../reader/reader_page.dart';

/// [v0.3.0] [v0.1.48] 书架 Tab：支持后台流式导入、卡片页数位置进度显示、即时加入书架。
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _tag = 'home';

  List<Book> _books = const [];
  bool _loading = true;
  bool _importing = false;

  Map<String, bool> _ragStatus = const {};
  Timer? _progressTimer;

  @override
  void initState() {
    super.initState();
    _refresh();
    // 轮询导入状态（加快刷新频率为 800ms，确保第一时间捕获新建的书籍和页数更新）
    _progressTimer = Timer.periodic(const Duration(milliseconds: 800), (_) {
      if (_importing || _books.any((b) => b.importStatus == 1)) {
        _refreshQuietly();
      }
    });
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshQuietly() async {
    try {
      final db = await DatabaseProvider.database;
      final list = await BookDao(db).getAll();
      if (!mounted) return;
      setState(() => _books = list);
    } catch (_) {}
  }

  Future<void> _refreshRagStatus() async {
    if (_books.isEmpty) {
      _ragStatus = const {};
      return;
    }
    try {
      final status = await RagRetrievalService.instance.getIndexStatus(_books);
      if (mounted) setState(() => _ragStatus = status);
    } catch (_) {}
  }

  Future<void> _buildRagIndex(Book book) async {
    AppLog.d(_tag, '开始构建 RAG 索引: ${book.title}');
    final count = await RagRetrievalService.instance.buildIndex(book);
    if (mounted) {
      if (count > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('「${book.title}」知识库已构建完成（$count 个片段）')),
        );
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('「${book.title}」无可索引内容，跳过')));
      }
      unawaited(_refreshRagStatus());
    }
  }

  Future<void> _refresh() async {
    try {
      final db = await DatabaseProvider.database;
      final list = await BookDao(db).getAll();
      if (!mounted) return;
      setState(() {
        _books = list;
        _loading = false;
      });
      unawaited(_refreshRagStatus());
    } catch (e, s) {
      AppLog.e(_tag, '加载书架失败: $e\n$s');
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _onImport() async {
    if (_importing) return;
    final action = await ImportSheet.show(context);
    if (action == null || !mounted) return;

    setState(() => _importing = true);
    try {
      // 启动异步导入
      _runImport(action)
          .then((book) {
            if (book != null) {
              _refresh();
              unawaited(_buildRagIndex(book));
            }
          })
          .catchError((e) {
            if (mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text('导入失败：$e')));
              _refresh();
            }
          })
          .whenComplete(() {
            if (mounted) setState(() => _importing = false);
          });

      // 选定文件后立即连续拉取两次，确保新建的初始书籍瞬间在书架呈现
      await Future.delayed(const Duration(milliseconds: 150));
      await _refresh();
      await Future.delayed(const Duration(milliseconds: 300));
      await _refresh();
    } catch (e) {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<Book?> _runImport(ImportAction action) async {
    switch (action) {
      case ImportAction.camera:
        final path = await PickerService().pickFromCamera();
        if (path == null) return null;
        return BookImportService().importImage(path, BookSource.camera);
      case ImportAction.gallery:
        final path = await PickerService().pickFromGallery();
        if (path == null) return null;
        return BookImportService().importImage(path, BookSource.gallery);
      case ImportAction.file:
        final result = await ImportSheet.pickDocument();
        if (result == null || result.files.isEmpty) return null;
        final path = result.files.single.path;
        if (path == null) return null;
        return BookImportService().importFile(path);
    }
  }

  Future<void> _deleteBook(Book book) async {
    try {
      final db = await DatabaseProvider.database;
      await BookDao(db).delete(book.id);
      unawaited(RagRetrievalService.instance.deleteIndex(book.id));
      AppLog.d(_tag, '删除书籍: ${book.title}');
      await _refresh();
    } catch (e, s) {
      AppLog.e(_tag, '删除失败: $e\n$s');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我的书架')),
      body: _buildBody(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _importing ? null : _onImport,
        icon: const Icon(Icons.add),
        label: const Text(
          '导入',
          style: TextStyle(
            fontFamily: 'ZCOOLKuaiLe',
            fontSize: 16,
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_books.isEmpty) {
      return _buildEmptyShelf();
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        mainAxisSpacing: 14,
        crossAxisSpacing: 14,
        childAspectRatio: 0.82,
      ),
      itemCount: _books.length,
      itemBuilder: (context, index) {
        final book = _books[index];
        final isIndexed = _ragStatus[book.id] ?? false;
        return _BookCard(
          book: book,
          isIndexed: isIndexed,
          onTap: () async {
            if (book.importStatus == 1) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('书籍正在后台解析/OCR中，请稍候…')),
              );
              return;
            }
            await Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => ReaderPage(book: book)),
            );
            await _refresh();
          },
          onDelete: () => _deleteBook(book),
          onBuildIndex: () => _buildRagIndex(book),
        );
      },
    );
  }

  Widget _buildEmptyShelf() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 96,
            height: 96,
            decoration: const BoxDecoration(
              color: StudyPalette.parchmentDeep,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.auto_stories_outlined,
              size: 48,
              color: StudyPalette.spineWord,
            ),
          ),
          const SizedBox(height: 18),
          Text('书架空空如也', style: titleStyle(fontSize: 20)),
          const SizedBox(height: 8),
          const Text(
            '点右下角「导入」，放入课本、图片或文档',
            style: TextStyle(color: StudyPalette.inkSoft),
          ),
        ],
      ),
    );
  }
}

class _BookCard extends StatelessWidget {
  const _BookCard({
    required this.book,
    required this.isIndexed,
    required this.onTap,
    required this.onDelete,
    required this.onBuildIndex,
  });

  final Book book;
  final bool isIndexed;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onBuildIndex;

  @override
  Widget build(BuildContext context) {
    final spine = StudyPalette.spineFor(book.source);
    final isImporting = book.importStatus == 1;
    final isFailed = book.importStatus == 2;

    return GestureDetector(
      onTap: onTap,
      onLongPress: () => _confirmDelete(context),
      child: Container(
        decoration: BoxDecoration(
          color: (Theme.of(context).brightness == Brightness.dark
                  ? StudyPalette.darkCard
                  : Colors.white)
              .withValues(alpha: 0.75),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: StudyPalette.linen),
          boxShadow: [
            BoxShadow(
              color: StudyPalette.ink.withValues(alpha: 0.08),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 书脊 + 封面
            Expanded(
              flex: 3,
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(13),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 书脊条
                    Container(width: 12, color: spine),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Container(
                        color: StudyPalette.parchmentDeep.withValues(
                          alpha: 0.55,
                        ),
                        padding: const EdgeInsets.all(10),
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: Icon(
                            _sourceIcon(book.source),
                            size: 26,
                            color: spine,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // 标题区与页数/进度区
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    book.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: StudyPalette.onSurfaceResolved(context),
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 4),
                  if (isImporting)
                    Row(
                      children: [
                        const SizedBox(
                          width: 10,
                          height: 10,
                          child: CircularProgressIndicator(strokeWidth: 1.5),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            book.importProgress ?? '识别导入中...',
                            style: const TextStyle(
                              fontSize: 11,
                              color: StudyPalette.ember,
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    )
                  else if (isFailed)
                    Text(
                      book.importProgress ?? '导入失败',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.redAccent,
                      ),
                    )
                  else
                    Text(
                      '${book.source.label}'
                      '${book.pageCount != null ? ' · ${book.pageCount} 页' : ''}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: StudyPalette.inkSoft,
                      ),
                    ),
                  const SizedBox(height: 6),
                  if (!isImporting && !isFailed) _buildRagStatus(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRagStatus() {
    if (isIndexed) {
      return const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle, size: 12, color: StudyPalette.moss),
          SizedBox(width: 4),
          Text(
            '知识库就绪',
            style: TextStyle(fontSize: 10, color: StudyPalette.moss),
          ),
        ],
      );
    }
    return const SizedBox.shrink();
  }

  void _confirmDelete(BuildContext context) {
    showDialog<void>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('删除书籍'),
            content: Text('确定要删除《${book.title}》吗？\n相关的句子和知识库索引也将被清除。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  onDelete();
                },
                child: const Text(
                  '删除',
                  style: TextStyle(color: StudyPalette.ember),
                ),
              ),
            ],
          ),
    );
  }

  IconData _sourceIcon(BookSource source) {
    switch (source) {
      case BookSource.camera:
        return Icons.camera_alt_outlined;
      case BookSource.gallery:
        return Icons.photo_library_outlined;
      case BookSource.pdf:
        return Icons.picture_as_pdf_outlined;
      case BookSource.word:
        return Icons.description_outlined;
      case BookSource.txt:
        return Icons.article_outlined;
    }
  }
}
