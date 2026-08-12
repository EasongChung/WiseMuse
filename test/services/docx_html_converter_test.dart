import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wisemuse/services/docx_html_converter.dart';

/// [v0.2.0] docx → HTML 转换器单测。
/// 用 archive 合成最小 docx(一个居中加粗标题 + 一个普通段落),
/// 断言转换出的 HTML 包含对应样式标签。覆盖纯 Dart 逻辑, 不涉及 WebView。
void main() {
  const wNs = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';

  /// 构造一个最小可用的 docx 文件(含 document.xml), 返回临时路径。
  Future<File> makeDocx(String documentXml) async {
    final dir = await Directory.systemTemp.createTemp('wm_docx_test_');
    addTearDown(() => dir.delete(recursive: true));
    final archive = Archive()
      ..add(ArchiveFile.string(
          'word/document.xml',
          '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
              '<w:document'
              ' xmlns:w="$wNs" '
              ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
              '<w:body>$documentXml</w:body></w:document>'));
    final bytes = ZipEncoder().encodeBytes(archive);
    final file = File('${dir.path}${Platform.pathSeparator}test.docx');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  /// 一个居中加粗标题段落。
  String paragraphBoldCenter(String text) => '<w:p><w:pPr>'
      '<w:jc w:val="center"/></w:pPr>'
      '<w:r><w:rPr><w:b/></w:rPr><w:t>$text</w:t></w:r></w:p>';

  group('DocxHtmlConverter', () {
    test('空文档抛出带中文说明的异常', () async {
      final file = await makeDocx('<w:p/>');
      await expectLater(
        DocxHtmlConverter.convert(file.path),
        throwsA(isA<Exception>()),
      );
    });

    test('居中加粗段落渲染出 text-align:center 与 font-weight:bold', () async {
      final file = await makeDocx(paragraphBoldCenter('标题'));
      final html = await DocxHtmlConverter.convert(file.path);
      expect(html, contains('text-align:center'));
      expect(html, contains('font-weight:bold'));
      expect(html, contains('标题'));
    });

    test('缺少 word/document.xml 时抛出明确异常', () async {
      final dir = await Directory.systemTemp.createTemp('wm_docx_bad_');
      addTearDown(() => dir.delete(recursive: true));
      final archive = Archive()
        ..add(ArchiveFile.bytes('word/media/x.png', utf8.encode('xxxx')));
      final bytes = ZipEncoder().encodeBytes(archive);
      final file = File('${dir.path}${Platform.pathSeparator}broken.docx');
      await file.writeAsBytes(bytes, flush: true);
      await expectLater(
        DocxHtmlConverter.convert(file.path),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('document.xml'),
        )),
      );
    });
  });
}
