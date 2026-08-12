import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../core/models/book.dart';

/// 文档解析结果。
class ImportResult {
  ImportResult({
    required this.content,
    required this.source,
    required this.title,
    this.pageTexts,
  });

  final String content;

  /// 来源类型（映射到 BookSource）。
  final BookSource source;

  final String title;

  /// 多页面文件的分页文本（索引=页码-1）；非 PDF/单页为 null。
  final List<String>? pageTexts;
}

/// PDF 文本层提取结果。
class PdfExtractResult {
  PdfExtractResult({required this.content, required this.pageTexts});

  final String content;
  final List<String> pageTexts;
}

/// PDF 无文本层（扫描件/纯图片版）时抛出的专用异常。
///
/// 上层（BookImportService）捕获后走逐页渲染 + OCR 流程。
class PdfHasNoTextLayerException implements Exception {
  const PdfHasNoTextLayerException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// PDF 文本层提取函数签名（Dart 侧注入，便于测试与桥接）。
///
/// 返回 [PdfExtractResult]；扫描件抛 [PdfHasNoTextLayerException]；
/// 其他错误抛 Exception。
typedef PdfTextExtractor = Future<PdfExtractResult> Function(String path);

/// 文档导入服务：解析 .docx / .pdf / .txt 为纯文本。
///
/// PDF 文本层通过注入的 [pdfExtractor] 获取（本服务不直接依赖原生通道），
/// 便于单测用假提取函数覆盖「有文本层」与「扫描件抛异常」两分支。
class ImportService {
  /// 按文件扩展名解析文本内容。
  ///
  /// [pdfExtractor] 为 PDF 文本层提取函数；未注入时走 [PdfServiceBridge]。
  Future<ImportResult> importFile(
    String path, {
    PdfTextExtractor? pdfExtractor,
  }) async {
    final file = File(path);
    if (!await file.exists()) {
      throw Exception('文件不存在');
    }
    final name = _fileName(path);
    final ext = _ext(path);

    switch (ext) {
      case 'docx':
        return ImportResult(
          content: await _readDocx(file),
          source: BookSource.word,
          title: name,
        );
      case 'pdf':
        return _readPdf(file, pdfExtractor);
      case 'txt':
      case 'text':
      case 'md':
        return ImportResult(
          content: await _readTxt(file),
          source: BookSource.txt,
          title: name,
        );
      case 'doc':
        throw Exception('暂不支持旧版 .doc，请另存为 .docx 后再导入');
      default:
        throw Exception('不支持的文件类型：.$ext');
    }
  }

  /// 自研 docx 文本提取（docx = zip + WordprocessingML XML）。
  ///
  /// 提取 `word/document.xml` 的 `<w:t>` 文本，段落 `<w:p>` 之间换行。
  Future<String> _readDocx(File file) async {
    // 大文件防御：>50MB 拒绝（避免 readAsBytes OOM）
    if (await file.length() > 50 * 1024 * 1024) {
      throw Exception('docx 文件过大（>50MB），暂不支持导入');
    }
    final bytes = await file.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    ArchiveFile? entry;
    for (final f in archive.files) {
      if (f.name == 'word/document.xml') {
        entry = f;
        break;
      }
    }
    if (entry == null) {
      throw Exception('docx 缺少 word/document.xml，文件可能已损坏');
    }
    final xmlText = utf8.decode(entry.content, allowMalformed: true);

    const wNs = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
    final doc = XmlDocument.parse(xmlText);
    final buffer = StringBuffer();
    for (final p in doc.findAllElements('p', namespace: wNs)) {
      final text =
          p.findAllElements('t', namespace: wNs).map((t) => t.innerText).join();
      if (text.trim().isNotEmpty) buffer.writeln(text.trim());
    }
    final result = buffer.toString().trim();
    if (result.isEmpty) {
      throw Exception('docx 未提取到文本，请确认文件内容');
    }
    return result;
  }

  /// 按页提取 PDF 文本层，返回带分页文本的 [ImportResult]。
  ///
  /// 整份无文本 → 抛 [PdfHasNoTextLayerException]（上层走扫描件 OCR）。
  Future<ImportResult> _readPdf(
    File file,
    PdfTextExtractor? pdfExtractor,
  ) async {
    final extractor = pdfExtractor ?? _defaultPdfExtractor;
    final result = await extractor(file.path);
    return ImportResult(
      content: result.content,
      source: BookSource.pdf,
      title: _fileName(file.path),
      pageTexts: result.pageTexts,
    );
  }

  /// 默认 PDF 提取器（未注入时提示）。
  ///
  /// ImportService 本身不接触原生通道；实际提取由 BookImportService 注入
  /// （调用 PdfService 桥）。单测注入假提取函数覆盖两分支。
  Future<PdfExtractResult> _defaultPdfExtractor(String path) async {
    throw Exception('PDF 文本提取需注入 pdfExtractor（见 BookImportService）');
  }

  Future<String> _readTxt(File file) async {
    // 大文件防御
    if (await file.length() > 50 * 1024 * 1024) {
      throw Exception('TXT 文件过大（>50MB），暂不支持导入');
    }
    final bytes = await file.readAsBytes();
    try {
      return utf8.decode(bytes, allowMalformed: false).trim();
    } on FormatException catch (e) {
      throw FormatException(
        'TXT 不是有效的 UTF-8 文本，请先转换为 UTF-8 编码后再导入。',
        e,
      );
    }
  }

  String _fileName(String path) {
    final parts = path.split(RegExp(r'[/\\]'));
    return parts.isEmpty ? '文档' : parts.last;
  }

  String _ext(String path) {
    final name = _fileName(path);
    final dot = name.lastIndexOf('.');
    if (dot < 0) return '';
    return name.substring(dot + 1).toLowerCase();
  }
}
