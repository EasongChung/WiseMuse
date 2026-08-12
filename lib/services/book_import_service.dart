import 'dart:io';
import 'dart:ui';

import '../core/debug/app_log.dart';
import '../core/models/book.dart';
import '../core/models/sentence.dart';
import '../core/storage/book_dao.dart';
import '../core/storage/database.dart';
import '../core/storage/file_store.dart';
import '../core/storage/sentence_dao.dart';
import 'import_service.dart';
import 'ocr_geometry_service.dart';
import 'ocr_service.dart';
import 'pdf_service.dart';
import 'sentence_splitter.dart';

/// [v0.2.0] 教材导入编排：复制原文件 → 解析/OCR → 切句 → 写库。
///
/// 数据流：
/// - **PDF 有文本层**：PdfService.extractTexts → 逐页 splitTextToSentences →
///   Sentence(page=i)；原文件保留（原文模式 PDFView）。
/// - **PDF 扫描件**（抛 PdfHasNoTextLayerException）：逐页 renderPage → OCR →
///   页文本 → Sentence(page=i)（文本模式为验收主路径）。
/// - **docx**：ImportService 提取文本 → Sentence(page=0)；原文件保留（原文 HTML）。
/// - **txt**：提取文本 → Sentence(page=0)。
/// - **图片**（camera/gallery）：OCR → blocks → OcrGeometryService.buildSentences →
///   Sentence(text + geometry JSON)，page=0。
///
/// 失败回滚：删除已复制原文件 + 清空已入库句子，再 rethrow（由页面 toast）。
class BookImportService {
  static const _tag = 'import';

  final PdfService _pdf = PdfService();
  final OcrService _ocr = OcrService();
  final ImportService _import = ImportService();

  /// 导入文档（PDF/docx/txt）。成功返回入库的 Book。
  Future<Book> importFile(String path) async {
    final fileName = _fileName(path);
    AppLog.d(_tag, '导入文档: $fileName');
    try {
      final result = await _import.importFile(path, pdfExtractor: _extractPdfText);
      // PDF：按页切句；docx/txt：整篇 page=0
      final sentences = <Sentence>[];
      if (result.pageTexts != null) {
        for (var i = 0; i < result.pageTexts!.length; i++) {
          _appendSentences(sentences, result.pageTexts![i], page: i);
        }
      } else {
        _appendSentences(sentences, result.content, page: 0);
      }
      final pageCount = result.source == BookSource.pdf ? await _pdf.getPageCount(path) : null;
      return _persist(
        title: result.title,
        source: result.source,
        originalPath: path,
        pageCount: pageCount,
        sentences: sentences,
      );
    } on PdfHasNoTextLayerException {
      AppLog.d(_tag, '扫描件 PDF，走逐页 OCR');
      final sentences = await _ocrPdfPages(path);
      final pageCount = await _pdf.getPageCount(path);
      return _persist(
        title: fileName,
        source: BookSource.pdf,
        originalPath: path,
        pageCount: pageCount,
        sentences: sentences,
      );
    }
  }

  /// 导入图片（拍照/相册）。OCR 后文本 + 归一化几何一并入库。
  Future<Book> importImage(String path, BookSource source) async {
    AppLog.d(_tag, '导入图片: $source');
    final title = source == BookSource.camera ? '拍照识别' : '相册识别';
    final sentences = <Sentence>[];
    final result = await _ocr.recognizeFile(path);
    if (result == null) {
      throw Exception('识别失败：图片无法识别出文字');
    }
    if (result.text.trim().isNotEmpty) {
      // 按 OCR 文本切句，geometry 由块几何反查（见下）
      _appendSentences(sentences, result.text, page: 0);
      return _persist(
        title: title,
        source: source,
        originalPath: path,
        pageCount: 1,
        sentences: _attachGeometry(sentences, result),
      );
    }
    return _persist(
      title: title,
      source: source,
      originalPath: path,
      pageCount: 1,
      sentences: sentences,
    );
  }

  // ===== 扫描件 PDF 逐页 OCR =====

  Future<List<Sentence>> _ocrPdfPages(String path) async {
    final count = await _pdf.getPageCount(path);
    final pages = count ?? 0;
    final sentences = <Sentence>[];
    for (var i = 0; i < pages; i++) {
      AppLog.d(_tag, '扫描 PDF 第 $i 页 OCR');
      final png = await _pdf.renderPage(path, i, scale: 1.5);
      if (png == null) continue;
      // renderPage 返回 PNG 字节，OcrBridge 按文件路径识别；
      // 此处把 PNG 写临时文件再识别。
      final tmp = await _writeTempPng(png);
      try {
        final result = await _ocr.recognizeFile(tmp);
        if (result != null && result.text.trim().isNotEmpty) {
          _appendSentences(sentences, result.text, page: i);
        }
      } finally {
        try { await File(tmp).delete(); } catch (_) {}
      }
    }
    return sentences;
  }

  Future<String> _writeTempPng(List<int> bytes) async {
    final dir = await Directory.systemTemp.createTemp('wm_ocr_');
    final f = File('${dir.path}${Platform.pathSeparator}page.png');
    await f.writeAsBytes(bytes, flush: true);
    return f.path;
  }

  // ===== PDF 文本层提取（注入 ImportService） =====

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
  }) {
    final sentences = splitTextToSentences(text);
    for (var i = 0; i < sentences.length; i++) {
      // bookId 在 _persist 里统一绑定；此处用占位避免泄漏临时状态
      out.add(
        Sentence.create(
          bookId: '',
          page: page,
          chapter: 0,
          index: i,
          text: sentences[i],
        ),
      );
    }
  }

  /// 给图片书句子附加 OCR 归一化几何（按文本近似匹配句级矩形）。
  ///
  /// OcrGeometryService 输出的 OcrSentence 有 rects（归一化），按文本与
  /// 已切句子对齐（先精确、再包含）。返回**新列表**（geometry 是 final 字段，
  /// 不可原地改，需重建 Sentence），几何写入 Sentence.geometry JSON。
  List<Sentence> _attachGeometry(List<Sentence> sentences, OcrResult result) {
    final blocks = result.blocks;
    if (blocks.isEmpty) return sentences;
    // 图片宽高未知时无法归一化；此处用块外接框的最大坐标作为虚拟图像尺寸。
    var maxX = 1.0;
    var maxY = 1.0;
    for (final b in blocks) {
      if (b.boundingBox.right > maxX) maxX = b.boundingBox.right;
      if (b.boundingBox.bottom > maxY) maxY = b.boundingBox.bottom;
    }
    final ocrSentences = OcrGeometryService.buildSentences(
      blocks,
      imageWidth: maxX,
      imageHeight: maxY,
    );
    // 按文本匹配，重建带几何的句子
    return sentences.map((s) {
      final hit = ocrSentences.where((o) {
        return o.text.contains(s.text) || s.text.contains(o.text);
      }).toList();
      if (hit.isEmpty) return s;
      final rects = <Rect>[];
      for (final h in hit) {
        rects.addAll(h.rects);
      }
      return Sentence.create(
        bookId: s.bookId,
        page: s.page,
        chapter: s.chapter,
        index: s.index,
        text: s.text,
        geometry: encodeSentenceGeometry(rects),
      );
    }).toList();
  }

  // ===== 入库与回滚 =====

  Future<Book> _persist({
    required String title,
    required BookSource source,
    required String originalPath,
    int? pageCount,
    required List<Sentence> sentences,
  }) async {
    AppLog.d(_tag, '入库: $title（$source，${sentences.length} 句）');
    String? copied;
    String? bookId;
    try {
      // 1) 复制原文件到私有目录（大文件流式）
      copied = await FileStore.copyToOriginals(originalPath, _ext(originalPath));
      // 2) 建 Book
      final book = Book.create(
        title: title,
        source: source,
        originalFilePath: copied,
      );
      if (pageCount != null) {
        book.pageCount = pageCount;
      }
      bookId = book.id;
      // 3) 写库（Book + 句子事务）
      final db = await DatabaseProvider.database;
      final fixed = sentences
          .map((s) => Sentence.create(
                bookId: book.id,
                page: s.page,
                chapter: s.chapter,
                index: s.index,
                text: s.text,
                geometry: s.geometry,
              ))
          .toList();
      await BookDao(db).insert(book);
      await SentenceDao(db).insertAll(fixed);
      AppLog.d(_tag, '入库成功: ${book.id}');
      return book;
    } catch (e, s) {
      AppLog.e(_tag, '入库失败: $e\n$s');
      // 回滚：删除复制件 + 清句子 + 删 Book（若已插入）
      if (copied != null) {
        try { await FileStore.delete(copied); } catch (_) {}
      }
      if (bookId != null) {
        try {
          final db = await DatabaseProvider.database;
          await BookDao(db).delete(bookId);
        } catch (_) {}
      }
      rethrow;
    }
  }

  // ===== 工具 =====

  String _fileName(String path) {
    final parts = path.split(RegExp(r'[/\\]'));
    return parts.isEmpty ? '文档' : parts.last;
  }

  String _ext(String path) {
    final name = _fileName(path);
    final dot = name.lastIndexOf('.');
    if (dot < 0) return 'bin';
    final e = name.substring(dot + 1).toLowerCase();
    return e.isEmpty ? 'bin' : e;
  }
}
