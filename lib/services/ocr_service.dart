import 'package:flutter/services.dart';

import '../core/debug/app_log.dart';
import 'ocr_geometry_service.dart';

/// [v0.2.0] ML Kit 中文 OCR 桥（MethodChannel → OcrBridge.kt）。
///
/// 纯离线 Bundled 模型（随 AAR 打包，无 GMS 依赖）。识别在原生后台线程执行。
class OcrService {
  static const _tag = 'ocr';
  static const _channel = MethodChannel('com.zqpd.wisemuse/ocr');

  /// 识别图片文件，返回识别结果；失败返回 null。
  ///
  /// 结果含完整文本 [OcrResult.text] 与块结构 [OcrResult.blocks]（供
  /// OcrGeometryService 合成句子几何）。
  Future<OcrResult?> recognizeFile(String path) async {
    try {
      final data = await _channel.invokeMethod<Map<Object?, Object?>>(
        'recognizeFile',
        {'path': path},
      );
      if (data == null) return null;
      return OcrResult.fromMap(data.cast<String, dynamic>());
    } catch (e) {
      AppLog.e(_tag, 'recognizeFile 失败: $e');
      return null;
    }
  }
}

/// OCR 识别结果（含块/行结构）。
class OcrResult {
  OcrResult({required this.text, required this.blocks});

  final String text;
  final List<OcrBlock> blocks;

  static OcrResult? fromMap(Map<String, dynamic> map) {
    final text = map['text'];
    final rawBlocks = map['blocks'];
    if (rawBlocks is! List) return null;
    final blocks = <OcrBlock>[];
    for (final b in rawBlocks) {
      final bm = (b as Map).cast<String, dynamic>();
      final bbox = _parseBbox(bm['bbox']);
      if (bbox == null) continue;
      final rawLines = bm['lines'];
      final lines = <OcrLine>[];
      if (rawLines is List) {
        for (final l in rawLines) {
          final lm = (l as Map).cast<String, dynamic>();
          final lb = _parseBbox(lm['bbox']);
          if (lb == null) continue;
          lines.add(
            OcrLine(text: lm['text']?.toString() ?? '', boundingBox: lb),
          );
        }
      }
      blocks.add(
        OcrBlock(
          text: bm['text']?.toString() ?? '',
          boundingBox: bbox,
          lines: lines,
        ),
      );
    }
    return OcrResult(text: text?.toString() ?? '', blocks: blocks);
  }

  static Rect? _parseBbox(Object? raw) {
    if (raw is! List || raw.length < 4) return null;
    final nums = raw.map((e) => (e as num).toDouble()).toList();
    return Rect.fromLTRB(nums[0], nums[1], nums[2], nums[3]);
  }
}
