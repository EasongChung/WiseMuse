import 'package:flutter/services.dart';

import '../core/debug/app_log.dart';

/// [v0.2.0] PDF 解析/渲染桥（MethodChannel → PdfBridge.kt）。
///
/// 提供：
/// - [getPageCount] / [renderPage]：系统 PdfRenderer 渲染 PNG（扫描件逐页 OCR）；
/// - [extractTextPositions]：PDFBox 逐页字符坐标（PDF 点，几何合成用）；
/// - [extractTexts]：整本逐页纯文本（仅导入时用）。
class PdfService {
  static const _tag = 'pdf';
  static const _channel = MethodChannel('com.zqpd.wisemuse/pdf');

  /// 获取 PDF 页数；失败返回 null。
  Future<int?> getPageCount(String path) async {
    try {
      final n = await _channel.invokeMethod<int>('getPageCount', {
        'path': path,
      });
      return n;
    } catch (e) {
      AppLog.e(_tag, 'getPageCount 失败: $e');
      return null;
    }
  }

  /// 渲染指定页为 PNG 字节；失败返回 null。
  Future<Uint8List?> renderPage(
    String path,
    int pageIndex, {
    double scale = 2.0,
  }) async {
    try {
      final sw = Stopwatch()..start();
      final bytes = await _channel.invokeMethod<Uint8List>('renderPage', {
        'path': path,
        'pageIndex': pageIndex,
        'scale': scale,
      });
      sw.stop();
      AppLog.d(_tag, 'renderPage($pageIndex) 耗时 ${sw.elapsedMilliseconds}ms');
      return bytes;
    } catch (e) {
      AppLog.e(_tag, 'renderPage($pageIndex) 失败: $e');
      return null;
    }
  }

  /// 提取指定页字符坐标 + 页面几何元信息。
  ///
  /// 返回结构（与 PdfBridge 一致）：
  /// ```
  /// {pageWidth, pageHeight, cropX, cropY, rotation,
  ///  chars: [{c,x,y,w,h,fs,asc,desc}, ...]}
  /// ```
  /// 失败返回 null。
  Future<Map<String, dynamic>?> extractTextPositions(
    String path,
    int pageIndex,
  ) async {
    try {
      final sw = Stopwatch()..start();
      final data = await _channel.invokeMethod<Map<Object?, Object?>>(
        'extractTextPositions',
        {'path': path, 'pageIndex': pageIndex},
      );
      sw.stop();
      final chars = (data?['chars'] as List?)?.length ?? 0;
      AppLog.d(
        _tag,
        'extractTextPositions($pageIndex) ${sw.elapsedMilliseconds}ms '
        '${chars}chars',
      );
      return data?.cast<String, dynamic>();
    } catch (e) {
      AppLog.e(_tag, 'extractTextPositions($pageIndex) 失败: $e');
      return null;
    }
  }

  /// 提取整本 PDF 逐页纯文本（索引 = 页码 - 1）；失败返回 null。
  Future<List<String>?> extractTexts(String path) async {
    try {
      final pages = await _channel.invokeMethod<List<Object?>>('extractTexts', {
        'path': path,
      });
      return pages?.map((e) => e?.toString() ?? '').toList();
    } catch (e) {
      AppLog.e(_tag, 'extractTexts 失败: $e');
      return null;
    }
  }
}

/// [v0.2.0] PDF 单页字符坐标解析后的便捷视图。
///
/// [chars] 元素结构与 PdfBridge 一致（见 [PdfService.extractTextPositions]）。
class PdfPageGeometry {
  PdfPageGeometry({
    required this.pageWidth,
    required this.pageHeight,
    required this.cropX,
    required this.cropY,
    required this.rotation,
    required this.chars,
  });

  /// 从原生返回的 Map 解析；格式不符返回 null。
  static PdfPageGeometry? fromMap(Map<String, dynamic> map) {
    final pw = map['pageWidth'];
    final ph = map['pageHeight'];
    final raw = map['chars'];
    if (pw is! num || ph is! num || raw is! List) return null;
    return PdfPageGeometry(
      pageWidth: pw.toDouble(),
      pageHeight: ph.toDouble(),
      cropX: (map['cropX'] as num?)?.toDouble() ?? 0,
      cropY: (map['cropY'] as num?)?.toDouble() ?? 0,
      rotation: (map['rotation'] as int?) ?? 0,
      chars:
          raw
              .map<Map<Object?, Object?>>(
                (e) => (e as Map).cast<Object?, Object?>(),
              )
              .toList(),
    );
  }

  final double pageWidth;
  final double pageHeight;
  final double cropX;
  final double cropY;
  final int rotation;

  /// 字符坐标列表（供 text_position_service 合成句子）。
  final List<Map<Object?, Object?>> chars;
}

/// 字符坐标 → [Rect]（PDF 点）辅助，供高亮/命中转换。
Rect charRectToRect(Map<Object?, Object?> c) {
  final x = (c['x'] as num).toDouble();
  final y = (c['y'] as num).toDouble();
  final fs = (c['fs'] as num).toDouble();
  final w = (c['w'] as num).toDouble();
  // em 框竖直范围（speak_reader Gate 1 定论）
  return Rect.fromLTRB(x, y - 0.88 * fs, x + w, y + 0.12 * fs);
}
