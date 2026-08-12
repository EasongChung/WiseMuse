import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wisemuse/core/models/book.dart';
import 'package:wisemuse/services/import_service.dart';

void main() {
  group('ImportService TXT', () {
    test('导入有效 UTF-8 文本', () async {
      final dir = await Directory.systemTemp.createTemp('wm_import_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}${Platform.pathSeparator}valid.txt');
      await file.writeAsString('有效文本');

      final result = await ImportService().importFile(file.path);

      expect(result.content, '有效文本');
      expect(result.source, BookSource.txt);
    });

    test('非 UTF-8 字节报错而非乱码', () async {
      final dir = await Directory.systemTemp.createTemp('wm_import_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}${Platform.pathSeparator}invalid.txt');
      await file.writeAsBytes([0x81, 0x81, 0x81], flush: true);

      expect(
        () => ImportService().importFile(file.path),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('UTF-8'),
          ),
        ),
      );
    });
  });

  group('ImportService docx', () {
    const wNs = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';

    Future<File> makeDocx(String documentXml) async {
      final dir = await Directory.systemTemp.createTemp('wm_docx_import_');
      addTearDown(() => dir.delete(recursive: true));
      final archive =
          Archive()..add(
            ArchiveFile.string(
              'word/document.xml',
              '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
                  '<w:document xmlns:w="$wNs"><w:body>$documentXml</w:body></w:document>',
            ),
          );
      final bytes = ZipEncoder().encodeBytes(archive);
      final file = File('${dir.path}${Platform.pathSeparator}test.docx');
      await file.writeAsBytes(bytes, flush: true);
      return file;
    }

    test('提取 w:t 文本, 段落间换行', () async {
      final file = await makeDocx(
        '<w:p><w:r><w:t>第一段</w:t></w:r></w:p>'
        '<w:p><w:r><w:t>第二段</w:t></w:r></w:p>',
      );
      final result = await ImportService().importFile(file.path);

      expect(result.content, contains('第一段'));
      expect(result.content, contains('第二段'));
      expect(
        result.content.split('\n').where((l) => l.isNotEmpty),
        hasLength(2),
      );
      expect(result.source, BookSource.word);
    });

    test('缺 document.xml 抛异常', () async {
      final dir = await Directory.systemTemp.createTemp('wm_docx_bad_');
      addTearDown(() => dir.delete(recursive: true));
      final archive =
          Archive()
            ..add(ArchiveFile.bytes('word/media/x.png', utf8.encode('xxxx')));
      final bytes = ZipEncoder().encodeBytes(archive);
      final file = File('${dir.path}${Platform.pathSeparator}broken.docx');
      await file.writeAsBytes(bytes, flush: true);

      await expectLater(
        () => ImportService().importFile(file.path),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('ImportService PDF', () {
    test('有文本层: 注入提取函数, 返回分页文本', () async {
      final dir = await Directory.systemTemp.createTemp('wm_pdf_ok_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}${Platform.pathSeparator}ok.pdf');
      await file.writeAsBytes([1, 2, 3], flush: true);

      Future<PdfExtractResult> extractor(String path) async => PdfExtractResult(
        content: '第一页内容。\n\n第二页内容。',
        pageTexts: ['第一页内容。', '第二页内容。'],
      );

      final result = await ImportService().importFile(
        file.path,
        pdfExtractor: extractor,
      );

      expect(result.source, BookSource.pdf);
      expect(result.pageTexts, hasLength(2));
      expect(result.content, contains('第二页内容。'));
    });

    test('扫描件(无文本层): 注入提取函数抛异常, 原样上抛', () async {
      final dir = await Directory.systemTemp.createTemp('wm_pdf_scan_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}${Platform.pathSeparator}scan.pdf');
      await file.writeAsBytes([9], flush: true);

      Future<PdfExtractResult> extractor(String path) async =>
          throw const PdfHasNoTextLayerException('该 PDF 是扫描件。');

      await expectLater(
        () => ImportService().importFile(file.path, pdfExtractor: extractor),
        throwsA(isA<PdfHasNoTextLayerException>()),
      );
    });
  });

  group('ImportService 其他', () {
    test('旧版 .doc 抛中文异常', () async {
      final dir = await Directory.systemTemp.createTemp('wm_doc_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}${Platform.pathSeparator}old.doc');
      await file.writeAsBytes([1, 2], flush: true);

      await expectLater(
        () => ImportService().importFile(file.path),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('docx'),
          ),
        ),
      );
    });

    test('未知扩展名抛异常', () async {
      final dir = await Directory.systemTemp.createTemp('wm_unknown_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}${Platform.pathSeparator}a.xyz');
      await file.writeAsString('x');

      await expectLater(
        () => ImportService().importFile(file.path),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('不支持'),
          ),
        ),
      );
    });
  });
}
