import 'package:flutter/material.dart';

import '../../core/debug/app_log.dart';
import '../../core/models/book.dart';
import '../../core/storage/book_dao.dart';
import '../../core/storage/database.dart';
import '../../services/book_import_service.dart';
import '../../services/picker_service.dart';
import '../../widgets/import_sheet.dart';
import '../debug/log_page.dart';
import '../follow/follow_page.dart';
import '../reader/reader_page.dart';

/// [v0.2.0] 书架首页：教材列表 + 导入入口。
///
/// - AppBar：跟读练习（保留既有链路）/ 日志入口
/// - body：BookDao 列表（点击进 ReaderPage，Dismissible 删除）
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
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => ReaderPage(book: book)),
      );
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

  Future<void> _deleteBook(Book book) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
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
    if (confirmed != true || !mounted) return;
    try {
      final db = await DatabaseProvider.database;
      await BookDao(db).delete(book.id);
      AppLog.d(_tag, '删除教材: ${book.title}');
      await _refresh();
    } catch (e, s) {
      AppLog.e(_tag, '删除失败: $e\n$s');
    }
  }

  void _openFollow() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const FollowPage()),
    );
  }

  void _openLog() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const LogPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('我的书架'),
        actions: [
          IconButton(
            tooltip: '跟读练习',
            icon: const Icon(Icons.record_voice_over_outlined),
            onPressed: _openFollow,
          ),
          IconButton(
            tooltip: '运行日志',
            icon: const Icon(Icons.bug_report_outlined),
            onPressed: _openLog,
          ),
        ],
      ),
      body: Stack(
        children: [
          _buildBody(),
          if (_importing)
            Container(
              color: Colors.black38,
              alignment: Alignment.center,
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 12),
                  Text('导入中…', style: TextStyle(color: Colors.white)),
                ],
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _importing ? null : _onImport,
        icon: const Icon(Icons.add),
        label: const Text('导入'),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_books.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.auto_stories_outlined,
              size: 72,
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 16),
            const Text('书架空空如也', style: TextStyle(fontSize: 16)),
            const SizedBox(height: 8),
            const Text('点击右下角导入课本、图片或文档'),
          ],
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _books.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final book = _books[index];
        return Dismissible(
          key: ValueKey(book.id),
          direction: DismissDirection.endToStart,
          background: Container(
            color: Colors.red.shade300,
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 20),
            child: const Icon(Icons.delete_outline, color: Colors.white),
          ),
          confirmDismiss: (_) => showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('删除教材'),
              content: Text('确定删除「${book.title}」吗？'),
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
          ),
          onDismissed: (_) => _deleteBook(book),
          child: ListTile(
            leading: CircleAvatar(
              child: Icon(_sourceIcon(book.source)),
            ),
            title: Text(book.title),
            subtitle: Text(
              '${book.source.label}'
              '${book.pageCount != null ? ' · ${book.pageCount} 页' : ''}',
            ),
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => ReaderPage(book: book)),
              );
              await _refresh();
            },
          ),
        );
      },
    );
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
