import 'package:flutter/material.dart';

import '../../core/debug/app_log.dart';
import '../../core/models/book.dart';
import '../../core/storage/book_dao.dart';
import '../../core/storage/database.dart';
import '../../core/theme/app_theme.dart';
import '../../services/book_import_service.dart';
import '../../services/picker_service.dart';
import '../../widgets/import_sheet.dart';
import '../reader/reader_page.dart';

/// [v0.3.0] 书架 Tab body（HomeShell 的 Tab 0）。
///
/// - AppBar：标题「我的书架」
/// - body：书本形态卡片网格（书脊色按来源区分，点击进 ReaderPage）
/// - FAB：导入 → ImportSheet 三分支
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

  @override
  void initState() {
    super.initState();
    _refresh();
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
      final book = await _runImport(action);
      if (book == null || !mounted) return;
      AppLog.d(_tag, '导入成功: ${book.title}');
      await _refresh();
      if (!mounted) return;
      // 打开阅读页
      await Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => ReaderPage(book: book)));
      await _refresh();
    } catch (e, s) {
      AppLog.e(_tag, '导入失败: $e\n$s');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导入失败：$e')));
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  /// 按用户选择执行导入；用户取消（未选文件/图片）返回 null。
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

  /// 直接删除教材（不弹确认——弹窗已由 [_BookCard._confirmDelete] 完成）。
  Future<void> _deleteBook(Book book) async {
    try {
      final db = await DatabaseProvider.database;
      await BookDao(db).delete(book.id);
      AppLog.d(_tag, '删除教材: ${book.title}');
      await _refresh();
    } catch (e, s) {
      AppLog.e(_tag, '删除失败: $e\n$s');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我的书架')),
      body: Stack(
        children: [_buildBody(), if (_importing) _buildImportOverlay()],
      ),
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

  /// 导入中的全屏遮罩（暖色书房风格）。
  Widget _buildImportOverlay() {
    return Container(
      color: StudyPalette.ink.withValues(alpha: 0.35),
      alignment: Alignment.center,
      child: Card(
        color: StudyPalette.parchment,
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 28, vertical: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 32,
                height: 32,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              SizedBox(height: 14),
              Text('正在导入课本…', style: TextStyle(color: StudyPalette.ink)),
            ],
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
    // 书本形态卡片网格：两列，卡片含书脊 + 封面色 + 标题
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
        return _BookCard(
          book: book,
          onTap: () async {
            await Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => ReaderPage(book: book)),
            );
            await _refresh();
          },
          onDelete: () => _deleteBook(book),
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
            decoration: BoxDecoration(
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

/// 书本形态卡片：书脊（来源色）+ 封面色 + 标题 + 副标题。
///
/// 整体观感像一本书立在书架上，来源类型映射为不同书脊色
/// （PDF=靛蓝 / 图片=橙 / Word=苔绿 / TXT=灰紫，见 [StudyPalette.spineFor]）。
class _BookCard extends StatelessWidget {
  const _BookCard({
    required this.book,
    required this.onTap,
    required this.onDelete,
  });

  final Book book;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final spine = StudyPalette.spineFor(book.source);
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
            // 标题区
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    book.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: StudyPalette.ink,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${book.source.label}'
                    '${book.pageCount != null ? ' · ${book.pageCount} 页' : ''}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: StudyPalette.inkSoft,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('删除教材'),
            content: Text('确定删除「${book.title}」吗？相关句子会一并删除。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('删除'),
              ),
            ],
          ),
    );
    if (confirmed == true) onDelete();
  }

  IconData _sourceIcon(BookSource source) {
    switch (source) {
      case BookSource.camera:
        return Icons.photo_camera_outlined;
      case BookSource.gallery:
        return Icons.photo_library_outlined;
      case BookSource.pdf:
        return Icons.picture_as_pdf_outlined;
      case BookSource.word:
        return Icons.description_outlined;
      case BookSource.txt:
        return Icons.notes;
    }
  }
}
