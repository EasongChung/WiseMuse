import 'dart:io';

import '../core/debug/app_log.dart';
import '../core/models/book.dart';
import '../core/models/sentence.dart';
import '../core/storage/book_dao.dart';
import '../core/storage/database.dart';
import '../core/storage/file_store.dart';
import '../core/storage/sentence_dao.dart';
import '../core/utils/pinyin_filter_util.dart';
import 'import_service.dart';
import 'ocr_geometry_service.dart';
import 'ocr_service.dart';
import 'pdf_service.dart';
import 'sentence_splitter.dart';

/// [v0.2.0] [v0.1.48] 书籍导入编排：支持流式后台进度更新与拼音智能过滤。
class BookImportService {
  static const _tag = 'import';

  final PdfService _pdf = PdfService();
  final OcrService _ocr = OcrService();
  final ImportService _import = ImportService();

  /// 导入文档（PDF/docx/txt）。成功返回入库的 Book。
  Future<Book> importFile(
    String path, {
    void Function(String message, double progress)? onProgress,
  }) async {
    final fileName = _fileName(path);
    AppLog.d(_tag, '导入文档: $fileName');
    final db = await DatabaseProvider.database;
    final bookDao = BookDao(db);

    // 1) 先创建 Book 实体并存库（importStatus: 1 导入中）
    final copied = await FileStore.copyToOriginals(path, _ext(path));
    final initialSource =
        path.toLowerCase().endsWith('.pdf')
            ? BookSource.pdf
            : (path.toLowerCase().endsWith('.docx')
                ? BookSource.word
                : BookSource.txt);

    final initialBook = Book.create(
      title: fileName,
      source: initialSource,
      originalFilePath: copied,
      importStatus: 1,
      importProgress: '准备解析...',
    );
    await bookDao.insert(initialBook);

    try {
      onProgress?.call('正在解析文件...', 0.1);
      await bookDao.updateImportStatus(
        initialBook.id,
        status: 1,
        progress: '正在解析文件...',
      );

      final result = await _import.importFile(
        path,
        pdfExtractor: _extractPdfText,
      );

      final sentences = <Sentence>[];
      if (result.pageTexts != null) {
        for (var i = 0; i < result.pageTexts!.length; i++) {
          final cleaned = PinyinFilterUtil.clean(result.pageTexts![i]);
          _appendSentences(sentences, cleaned, page: i, bookId: initialBook.id);
        }
      } else {
        final cleaned = PinyinFilterUtil.clean(result.content);
        _appendSentences(sentences, cleaned, page: 0, bookId: initialBook.id);
      }

      final pageCount =
          result.source == BookSource.pdf
              ? await _pdf.getPageCount(path)
              : (result.pageTexts?.length ?? 1);

      await SentenceDao(db).insertAll(sentences);
      await bookDao.updateImportStatus(
        initialBook.id,
        status: 0,
        progress: null,
        pageCount: pageCount,
      );

      initialBook.pageCount = pageCount;
      initialBook.importStatus = 0;
      initialBook.importProgress = null;
      initialBook.title = result.title;
      await bookDao.update(initialBook);

      AppLog.d(_tag, '文档导入完成: ${initialBook.id}');
      return initialBook;
    } on PdfHasNoTextLayerException {
      AppLog.d(_tag, '扫描件 PDF，走逐页 OCR');
      try {
        final sentences = await _ocrPdfPages(
          path,
          bookId: initialBook.id,
          onProgress: (done, total) async {
            final msg = '识别中 $done/$total 页';
            onProgress?.call(msg, done / total);
            await bookDao.updateImportStatus(
              initialBook.id,
              status: 1,
              progress: msg,
            );
          },
        );
        final pageCount = await _pdf.getPageCount(path) ?? 1;
        await SentenceDao(db).insertAll(sentences);
        await bookDao.updateImportStatus(
          initialBook.id,
          status: 0,
          progress: null,
          pageCount: pageCount,
        );

        initialBook.pageCount = pageCount;
        initialBook.importStatus = 0;
        initialBook.importProgress = null;
        await bookDao.update(initialBook);
        return initialBook;
      } catch (e, s) {
        AppLog.e(_tag, '扫描件 OCR 失败: $e\n$s');
        await bookDao.updateImportStatus(
          initialBook.id,
          status: 2,
          progress: 'OCR 失败',
        );
        rethrow;
      }
    } catch (e, s) {
      AppLog.e(_tag, '导入文档失败: $e\n$s');
      await bookDao.updateImportStatus(
        initialBook.id,
        status: 2,
        progress: '解析失败',
      );
      rethrow;
    }
  }

  /// 导入图片（拍照/相册）。
  Future<Book> importImage(
    String path,
    BookSource source, {
    void Function(String message, double progress)? onProgress,
  }) async {
    AppLog.d(_tag, '导入图片: $source');
    final title = source == BookSource.camera ? '拍照识别' : '相册识别';
    final db = await DatabaseProvider.database;
    final bookDao = BookDao(db);

    final copied = await FileStore.copyToOriginals(path, _ext(path));
    final initialBook = Book.create(
      title: title,
      source: source,
      originalFilePath: copied,
      importStatus: 1,
      importProgress: '识别文字中...',
    );
    await bookDao.insert(initialBook);

    try {
      onProgress?.call('识别文字中...', 0.3);
      final result = await _ocr.recognizeFile(path);
      if (result == null) {
        throw Exception('识别失败：图片无法识别出文字');
      }

      final width = result.width?.toDouble() ?? 0;
      final height = result.height?.toDouble() ?? 0;
      final sentences = <Sentence>[];

      if (width > 0 && height > 0) {
        final ocrSentences = OcrGeometryService.buildSentences(
          result.blocks,
          imageWidth: width,
          imageHeight: height,
        );
        for (var i = 0; i < ocrSentences.length; i++) {
          final o = ocrSentences[i];
          final cleaned = PinyinFilterUtil.clean(o.text);
          if (cleaned.trim().isEmpty) continue;
          sentences.add(
            Sentence.create(
              bookId: initialBook.id,
              page: 0,
              chapter: 0,
              index: i,
              text: cleaned,
              geometry: encodeSentenceGeometry(o.rects),
            ),
          );
        }
      } else {
        AppLog.w(_tag, 'OCR 未返回图片尺寸，退化为纯文本切句');
        final cleaned = PinyinFilterUtil.clean(result.text);
        _appendSentences(sentences, cleaned, page: 0, bookId: initialBook.id);
      }

      await SentenceDao(db).insertAll(sentences);
      await bookDao.updateImportStatus(
        initialBook.id,
        status: 0,
        progress: null,
        pageCount: 1,
      );

      initialBook.pageCount = 1;
      initialBook.importStatus = 0;
      initialBook.importProgress = null;
      await bookDao.update(initialBook);
      return initialBook;
    } catch (e, s) {
      AppLog.e(_tag, '图片识别失败: $e\n$s');
      await bookDao.updateImportStatus(
        initialBook.id,
        status: 2,
        progress: '识别失败',
      );
      rethrow;
    }
  }

  // ===== 扫描件 PDF 逐页 OCR =====

  Future<List<Sentence>> _ocrPdfPages(
    String path, {
    required String bookId,
    void Function(int done, int total)? onProgress,
  }) async {
    final count = await _pdf.getPageCount(path);
    final pages = count ?? 0;
    final sentences = <Sentence>[];
    for (var i = 0; i < pages; i++) {
      AppLog.d(_tag, '扫描 PDF 第 $i 页 OCR');
      final png = await _pdf.renderPage(path, i, scale: 1.5);
      if (png == null) continue;
      final tmp = await _writeTempPng(png);
      try {
        final result = await _ocr.recognizeFile(tmp);
        if (result != null && result.text.trim().isNotEmpty) {
          final cleaned = PinyinFilterUtil.clean(result.text);
          _appendSentences(sentences, cleaned, page: i, bookId: bookId);
        }
      } finally {
        try {
          await File(tmp).delete();
        } catch (_) {}
      }
      onProgress?.call(i + 1, pages);
    }
    return sentences;
  }

  Future<String> _writeTempPng(List<int> bytes) async {
    final dir = await Directory.systemTemp.createTemp('wm_ocr_');
    final f = File('${dir.path}${Platform.pathSeparator}page.png');
    await f.writeAsBytes(bytes, flush: true);
    return f.path;
  }

  // ===== PDF 文本层提取 =====

  Future<PdfExtractResult> _extractPdfText(String path) async {
    final pages = await _pdf.extractTexts(path);
    if (pages == null) {
      throw Exception('无法读取 PDF 文本层');
    }
    final joined = pages.join('\n\n').trim();
    if (joined.isEmpty) {
      throw const PdfHasNoTextLayerException('该 PDF 是扫描件（无文本层）。');
    }
    return PdfExtractResult(content: joined, pageTexts: pages);
  }

  // ===== 句子构造与几何 =====

  void _appendSentences(
    List<Sentence> out,
    String text, {
    required int page,
    required String bookId,
  }) {
    final sentences = splitTextToSentences(text);
    for (var i = 0; i < sentences.length; i++) {
      out.add(
        Sentence.create(
          bookId: bookId,
          page: page,
          chapter: 0,
          index: i,
          text: sentences[i],
        ),
      );
    }
  }

  String _fileName(String path) {
    final name = path.split(Platform.pathSeparator).last;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  String _ext(String path) {
    final dot = path.lastIndexOf('.');
    return dot >= 0 ? path.substring(dot) : '';
  }
}
