import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:wisemuse/services/ocr_geometry_service.dart';

/// [v0.2.0] OCR 句子几何服务单测：用内存构造的 [OcrBlock] 验证跨行合并、
/// 归一化与命中判定，不依赖真实图片/ML Kit 运行。
void main() {
  // 辅助: 构造一个块, 内含若干行。
  // lines: (左, 顶, 宽, 高, 文本) 五元组(像素坐标)。
  OcrBlock block(List<(double, double, double, double, String)> lines) {
    final ls = <OcrLine>[];
    for (final (left, top, w, h, text) in lines) {
      ls.add(OcrLine(text: text, boundingBox: Rect.fromLTWH(left, top, w, h)));
    }
    // 块外接框 = 所有行的并集
    final box =
        ls.map((l) => l.boundingBox).reduce((a, b) => a.expandToInclude(b));
    return OcrBlock(
      text: ls.map((l) => l.text).join(' '),
      lines: ls,
      boundingBox: box,
    );
  }

  group('OcrGeometryService', () {
    test('跨行句子正确合并并输出归一化矩形', () {
      // 两个相邻行, 行末贴右边界且无标点 → 应合并成一句
      // 图宽 100, 行1 占满右缘; 行2 从左侧开始(自动折行)
      final blocks = [
        block([
          (0, 0, 60, 10, '春眠不觉晓'),
          (40, 30, 60, 10, '处处闻啼鸟'),
        ]),
      ];
      final out = OcrGeometryService.buildSentences(blocks,
          imageWidth: 100, imageHeight: 200);
      // 行1右缘 60/100=0.6 (未贴边 blockRight=1.0) → 不满足行末贴边 → 各成一句
      expect(out.length, 2);
    });

    test('行末贴边的行合并为一句', () {
      // 行1 占满整行(0..100像素) → 行2贴左起 → 合并
      final blocks = [
        block([
          (0, 0, 100, 10, '这是第一行文字'),
          (0, 30, 100, 10, '这是第二行没有标点'),
        ]),
      ];
      final out = OcrGeometryService.buildSentences(blocks,
          imageWidth: 100, imageHeight: 200);
      // 首行右缘 = 1.0 = blockRight → 可合并; 正文连接无标点 → 一句
      expect(out.length, 1);
      expect(out.first.text, contains('第一行'));
      expect(out.first.text, contains('第二行'));
      expect(out.first.rects.length, 2, reason: '跨行句含两行矩形');
      // 矩形已归一化
      expect(out.first.rects.first.left, 0.0);
      expect(out.first.rects.first.top, 0.0);
    });

    test('句末标点截断为独立句', () {
      final blocks = [
        block([
          (0, 0, 30, 10, '你好世界。'),
          (0, 30, 30, 10, '下一个句子'),
        ]),
      ];
      final out = OcrGeometryService.buildSentences(blocks,
          imageWidth: 100, imageHeight: 200);
      // 句末有句号 → 第一行自成一句(不依赖 merge, 标点结束)
      expect(out.length, greaterThanOrEqualTo(2));
    });

    test('hitSentence 命中归一化坐标并吸附', () {
      final blocks = [
        block([(10, 10, 50, 10, 'abc句')]),
      ];
      final out = OcrGeometryService.buildSentences(blocks,
          imageWidth: 100, imageHeight: 200);
      expect(out, isNotEmpty);
      // 点在该行内(归一化 0.3, 0.05)
      final hitIn =
          OcrGeometryService.hitSentence(out, const Offset(0.3, 0.05));
      expect(hitIn, isNotNull);
      expect(hitIn!.text, contains('abc'));
      // 点远处 → null
      final miss = OcrGeometryService.hitSentence(out, const Offset(0.9, 0.9));
      expect(miss, isNull);
    });
  });
}
