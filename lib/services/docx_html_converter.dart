import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// [v0.2.0] docx → HTML 转换（正文常见样式）。
///
/// 用于「原文模式」的 Word 排版还原：把 `.docx` 文档转成内联样式的 HTML，
/// 交给 WebView 渲染。**正文常见样式**覆盖：
///
/// - 段落对齐（居中/右/两端/散布）、首行缩进、行距
/// - 文本加粗/斜体/下划线/删除线、字号(半磅)、字体颜色
/// - 图片（`word/media/*` 内联为 base64 data-URI）
/// - 表格（`<w:tbl>` → `<table>`）
///
/// 不做纸面分页/页眉页脚/多栏等流式排版无法还原的复杂布局。
/// 转换结果是**流式 HTML**，页面按 WebView 视口自然换行。
class DocxHtmlConverter {
  /// 把 docx 文件转成 HTML 字符串。失败抛出带中文说明的异常。
  static Future<String> convert(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw Exception('docx 文件不存在');
    }
    final bytes = await file.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    // 1) 读取主 XML
    ArchiveFile? docEntry;
    for (final f in archive.files) {
      if (f.name == 'word/document.xml') {
        docEntry = f;
        break;
      }
    }
    if (docEntry == null) {
      throw Exception('docx 缺少 word/document.xml,文件可能已损坏');
    }
    final xmlText = utf8.decode(docEntry.content, allowMalformed: true);
    final document = XmlDocument.parse(xmlText);

    // 2) 图片映射: word/media/<name> → base64(data-URI)
    final media = <String, String>{};
    for (final f in archive.files) {
      if (!f.name.startsWith('word/media/')) continue;
      final name = f.name.substring('word/media/'.length);
      final content = f.content;
      if (content.isNotEmpty) {
        media[name] = base64Encode(content);
      }
    }

    // 3) 逐块转 HTML
    const ns = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
    final buf = StringBuffer();
    buf.write('<meta charset="utf-8">');
    buf.write('<style>'
        'body{font-family:sans-serif;margin:12px;font-size:16px;line-height:1.7;}'
        'table{border-collapse:collapse;margin:6px 0;}'
        'td,th{border:1px solid #888;padding:4px 8px;vertical-align:top;}'
        'img{max-width:100%;height:auto;}'
        '</style>');
    var blockCount = 0;
    for (final body in document.findAllElements('body', namespace: ns)) {
      for (final child in body.children) {
        if (child is XmlElement) {
          final b = _blockToHtml(child, ns, media);
          if (b.isNotEmpty) {
            buf.write(b);
            blockCount++;
          }
        }
      }
    }

    // 只有样式头(meta+style)而无任何正文块时视为空文档
    if (blockCount == 0) {
      throw Exception('docx 未提取到排版内容,可改用文本模式阅读');
    }
    return buf.toString().trim();
  }

  /// 单个块级元素 → HTML（段落/表格）。
  static String _blockToHtml(
      XmlElement el, String ns, Map<String, String> media) {
    if (el.name.local == 'p') return _paragraphToHtml(el, ns, media);
    if (el.name.local == 'tbl') return _tableToHtml(el, ns, media);
    if (el.name.local == 'sectPr') return ''; // 节属性, 无排版在本方案内
    // 其他块(编号列表等)按段落近似, 避免丢失内容
    final text = _runsToHtml(el, ns, media);
    return text.isEmpty ? '' : '<p>$text</p>';
  }

  /// 段落 → <p>（含对齐/缩进/行距, 文本 run 内联样式）。
  static String _paragraphToHtml(
      XmlElement p, String ns, Map<String, String> media) {
    final style = StringBuffer();
    // 段落属性
    final pPr = _firstChild(p, 'pPr', ns);
    if (pPr != null) {
      _paraStyle(pPr, ns, style);
    }
    final text = _runsToHtml(p, ns, media);
    if (text.isEmpty) return '';
    final styleAttr =
        style.isEmpty ? '' : ' style="${style.toString().trim()}"';
    return '<p$styleAttr>$text</p>';
  }

  /// 表格 → <table>。
  static String _tableToHtml(
      XmlElement tbl, String ns, Map<String, String> media) {
    final rows = <String>[];
    for (final tr in tbl.childElements.where((e) => e.name.local == 'tr')) {
      final cells = <String>[];
      for (final tc in tr.childElements.where((e) => e.name.local == 'tc')) {
        // 单元格内容: 段落拼接
        final cellHtml = StringBuffer();
        for (final child in tc.childElements) {
          if (child.name.local == 'p') {
            final s = StringBuffer();
            final pPr = _firstChild(child, 'pPr', ns);
            if (pPr != null) _paraStyle(pPr, ns, s);
            final t = _runsToHtml(child, ns, media);
            final sa = s.isEmpty ? '' : ' style="${s.toString().trim()}"';
            cellHtml.write('<p$sa>$t</p>');
          }
        }
        cells.add('<td>${cellHtml.toString()}</td>');
      }
      rows.add('<tr>${cells.join()}</tr>');
    }
    return '<table>${rows.join()}</table>';
  }

  /// 段落属性 → CSS。
  static void _paraStyle(XmlElement pPr, String ns, StringBuffer out) {
    final jc = _firstChild(pPr, 'jc', ns);
    if (jc != null) {
      final v = _attr(jc, ns, 'val');
      final align = switch (v) {
        'center' => 'center',
        'right' => 'right',
        'both' => 'justify',
        'distribute' => 'justify',
        _ => 'left',
      };
      out.write('text-align:$align;');
    }
    final ind = _firstChild(pPr, 'ind', ns);
    if (ind != null) {
      final left = ind.getAttribute(
              '{http://schemas.openxmlformats.org/wordprocessingml/2006/main}left') ??
          ind.getAttribute('left');
      // firstLine 以 twentieths of a point (dxa) 为单位; 粗转 em
      final fl = ind.getAttribute(
              '{http://schemas.openxmlformats.org/wordprocessingml/2006/main}firstLine') ??
          ind.getAttribute('firstLine');
      if (fl != null && fl.isNotEmpty) {
        final dxa = int.tryParse(fl.toString()) ?? 0;
        if (dxa != 0) {
          out.write('text-indent:${(dxa / 240).toStringAsFixed(2)}em;');
        }
      }
      if (left != null && left.isNotEmpty) {
        final dxa = int.tryParse(left.toString()) ?? 0;
        if (dxa != 0) {
          out.write('padding-left:${(dxa / 240).toStringAsFixed(2)}em;');
        }
      }
    }
    final spacing = _firstChild(pPr, 'spacing', ns);
    if (spacing != null) {
      final line = spacing.getAttribute(
              '{http://schemas.openxmlformats.org/wordprocessingml/2006/main}line') ??
          spacing.getAttribute('line');
      final lineRule = spacing.getAttribute(
              '{http://schemas.openxmlformats.org/wordprocessingml/2006/main}lineRule') ??
          spacing.getAttribute('lineRule');
      if (line != null) {
        final v = int.tryParse(line.toString()) ?? 0;
        // lineRule=auto 时 line 为 240 线(倍数); exact/atLeast 为 twips
        if (lineRule == 'auto') {
          out.write('line-height:${(v / 240.0).toStringAsFixed(1)};');
        } else if (v > 0) {
          out.write('line-height:${(v / 20.0).toStringAsFixed(1)}px;');
        }
      }
    }
  }

  /// 段落内所有 run/（超链接等）→ 文本 HTML（含行内样式）。
  static String _runsToHtml(
      XmlElement parent, String ns, Map<String, String> media) {
    final buf = StringBuffer();
    for (final child in parent.childElements) {
      final name = child.name.local;
      if (name == 'r') {
        // run: 先收集其内所有文本/图片, 应用 rPr 样式
        final rPr = _firstChild(child, 'rPr', ns);
        final style = StringBuffer();
        if (rPr != null) _runStyle(rPr, ns, style);
        final content = StringBuffer();
        for (final c in child.childElements) {
          if (c.name.local == 't') {
            content.write(c.innerText);
          } else if (c.name.local == 'drawing' || c.name.local == 'pict') {
            final img = _inlineImage(child, ns, media);
            if (img != null) content.write(img);
          } else if (c.name.local == 'br') {
            content.write('<br>');
          }
        }
        if (content.isEmpty) continue;
        final s = style.toString();
        if (s.isEmpty) {
          buf.write(content);
        } else {
          buf.write('<span style="${s.trim()}">$content</span>');
        }
      } else if (name == 'hyperlink') {
        buf.write(_runsToHtml(child, ns, media));
      } else if (name == 'ins') {
        buf.write(_runsToHtml(child, ns, media));
      } else if (name == 'smartTag') {
        buf.write(_runsToHtml(child, ns, media));
      }
    }
    return buf.toString();
  }

  /// run 属性 → 行内 CSS。
  static void _runStyle(XmlElement rPr, String ns, StringBuffer out) {
    final b = rPr.childElements.any((e) => e.name.local == 'b');
    final i = rPr.childElements.any((e) => e.name.local == 'i');
    final u = rPr.childElements.any((e) => e.name.local == 'u');
    final strike = rPr.childElements.any((e) => e.name.local == 'strike');
    if (b) out.write('font-weight:bold;');
    if (i) out.write('font-style:italic;');
    if (u) {
      out.write('text-decoration:underline;');
    } else if (strike) {
      out.write('text-decoration:line-through;');
    }
    final sz = _firstChild(rPr, 'sz', ns);
    if (sz != null) {
      final v = sz.getAttribute(
              '{http://schemas.openxmlformats.org/wordprocessingml/2006/main}val') ??
          sz.getAttribute('val');
      final half = int.tryParse(v?.toString() ?? '') ?? 0;
      if (half > 0) {
        out.write('font-size:${(half / 2).toStringAsFixed(1)}pt;');
      }
    }
    final color = _firstChild(rPr, 'color', ns);
    if (color != null) {
      final v = color.getAttribute(
              '{http://schemas.openxmlformats.org/wordprocessingml/2006/main}val') ??
          color.getAttribute('val');
      final hex = v?.toString() ?? '';
      if (hex.isNotEmpty && hex != 'auto') {
        out.write('color:#$hex;');
      }
    }
  }

  /// 从 run 内的 drawing/pict 取内联图片 HTML（data-URI）。
  static String? _inlineImage(
      XmlElement run, String ns, Map<String, String> media) {
    // 找 blip 的 r:embed id
    for (final blip in run.descendants.whereType<XmlElement>()) {
      if (blip.name.local != 'blip') continue;
      final embed = blip.getAttribute(
              '{http://schemas.openxmlformats.org/officeDocument/2006/relationships}embed') ??
          blip.getAttribute('r:embed') ??
          blip.getAttribute('embed');
      if (embed == null) continue;
      final id = embed.toString();
      // 需要关系映射 rId → media 文件。docx 的 image 引用是 rId, 而 media 用文件名。
      // 简化: 直接扫 media 里的图片(单图片文档多数仅一张), 或依赖 rId 编号近似。
      // rId 形如 rId5, media 名为 image5.png —— 二者编号常一致。
      final numMatch = RegExp(r'(\d+)$').firstMatch(id);
      final num = numMatch?.group(1);
      String? base64;
      if (num != null) {
        final m = media.entries
            .where(
                (e) => e.key.contains('$num.') || e.key.startsWith('image$num'))
            .toList();
        if (m.isNotEmpty) base64 = m.first.value;
      }
      if (base64 == null && media.isNotEmpty) {
        // 兜底: 取第一张
        base64 = media.values.first;
      }
      if (base64 != null) {
        return '<img src="data:image/png;base64,$base64"/>';
      }
      return null;
    }
    return null;
  }

  static XmlElement? _firstChild(XmlElement el, String name, String ns) {
    for (final c in el.childElements) {
      if (c.name.local == name) return c;
    }
    return null;
  }

  /// 读取属性值。
  ///
  /// docx XML 经 xml 6.x 解析后, `w:val` 这类带前缀属性名 `qualified` 为字面量
  /// `"w:val"`(前缀未解析回命名空间 URI), 故 `getAttribute('val')` 与
  /// `getAttribute('{$ns}val')` 都取不到, 只有 `getAttribute('w:val')` 可以。
  /// 为兼容不同前缀(Word 常规为 `w`), 这里遍历所有属性按 local name 匹配值。
  static String? _attr(XmlElement el, String ns, String name) {
    // 遍历所有属性按 local name 匹配, 覆盖任意前缀(Word 常规为 w:)
    for (final a in el.attributes) {
      if (a.name.local == name) return a.value;
    }
    // 兜底: 前缀形式 / 命名空间形式 / 裸键
    return el.getAttribute('w:$name') ??
        el.getAttribute('{$ns}$name') ??
        el.getAttribute(name);
  }
}
