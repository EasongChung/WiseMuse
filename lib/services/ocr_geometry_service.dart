import 'dart:convert';
import 'dart:ui';

import 'line_merge_rules.dart';
import 'sentence_splitter.dart';

/// [v0.2.0] OCR 句子几何：把 ML Kit 识别出的**行级**轴向框合并为**句子级**矩形。
///
/// 用途：图片原文模式的「点击文字 → 高亮并朗读」。OCR 桥返回的每行一个
/// `boundingBox`（原图像素）+ 单行文本；而朗读/高亮单元期望是**句子**（可能
/// 跨行）。本服务把行合并成句，输出归一化(0~1)矩形，与图片缩放解耦。
///
/// ## 坐标约定
/// - 输入: 像素 `Rect`（OCR 的 boundingBox）+ 图片宽高。
/// - 输出: 归一化 `Rect`，用 `left = x / width`、`top = y / height` 换算，
///   与图片 `BoxFit.contain` / `InteractiveViewer` 缩放无关。
///
/// ## 句子切分（v0.3.0 修复）
/// **行内先按终止标点切段**（复用 [sentenceTerms]，与 PDF 几何 / 文本侧同源）：
/// ML Kit 的一行文本可能含多个句子（如 `"用一句话介绍你自己。帮我出个谜语。"`
/// 在同一行），旧实现只按跨行判据断句，把整行甚至整页拼成一句 → 高亮框覆盖
/// 整页。现改为：段末是终止标点时强制断句；跨行合并仍走 [canMergeLines]
/// （仅当上一句未结束且排版为自动折行）。
///
/// ## 跨行合并
/// 复用 [canMergeLines] 判据（与 PDF 点击朗读同一套规则），保证朗读单元与高亮
/// 单元同源（G2.5.1 教训）。度量统一用**归一化值**：块边界取整段块，`charW`
/// 用该块行高近似（OCR 行高≈字号），行末贴边/缩进/行首符号判据随之保持一致。

/// OCR 识别出的一行（像素坐标）。
class OcrLine {
  OcrLine({required this.text, required this.boundingBox});

  final String text;
  final Rect boundingBox; // 原图像素
}

/// OCR 识别出的一个文本块（多行，像素坐标）。
class OcrBlock {
  OcrBlock({
    required this.text,
    required this.boundingBox,
    required this.lines,
  });

  final String text;
  final Rect boundingBox; // 原图像素
  final List<OcrLine> lines;
}

/// OCR 句子：归一化(0~1)矩形列表 + 文本。
class OcrSentence {
  const OcrSentence({required this.text, required this.rects});

  final String text;
  final List<Rect> rects;

  Rect get union {
    if (rects.isEmpty) return Rect.zero;
    var r = rects.first;
    for (final x in rects.skip(1)) {
      r = r.expandToInclude(x);
    }
    return r;
  }
}

class OcrGeometryService {
  /// 输入 OCR 结果 + 原图宽高, 返回句子级几何（坐标已归一化）。
  ///
  /// 每个句子的 [OcrSentence.rects] 含若干行矩形（跨行句每行一个），
  /// [OcrSentence.text] 为该句文本（跨行已按 [needsSpaceBetween] 补空格）。
  static List<OcrSentence> buildSentences(
    List<OcrBlock> blocks, {
    required double imageWidth,
    required double imageHeight,
  }) {
    final result = <OcrSentence>[];
    if (imageWidth <= 0 || imageHeight <= 0) return result;

    for (final block in blocks) {
      final blockLeft = block.boundingBox.left;
      final blockRight = block.boundingBox.right;
      // 行高近似字符宽: 用块内中位行高（OCR 行高≈字号）
      final charH = _medianLineHeight(block.lines);
      final charW = charH.clamp(1.0, double.infinity);

      final sb = StringBuffer();
      final rects = <Rect>[];
      var lastChar = '';

      /// 结束当前句（收集到 result）
      void flush() {
        final s = sb.toString().trim();
        if (s.isNotEmpty && rects.isNotEmpty) {
          result.add(OcrSentence(text: s, rects: List.of(rects)));
        }
        sb.clear();
        rects.clear();
        lastChar = '';
      }

      for (final line in block.lines) {
        final text = line.text.trim();
        if (text.isEmpty) {
          // 空行是段落硬边界
          flush();
          continue;
        }

        final rr = _normRect(line.boundingBox, imageWidth, imageHeight);
        final rx = _normX(line.boundingBox.left, imageWidth);

        // **行内先按终止标点切段**（复用 sentenceTerms，与 PDF/文本侧同源）。
        // ML Kit 一行可能含多个句子；段末是终止标点时该段独立成句。
        final segments = _splitLineByTerms(text);
        if (segments.isEmpty) continue;

        for (final seg in segments) {
          final segText = seg.trim();
          if (segText.isEmpty) continue;
          final segFirst = segText[0];
          final segLast = segText[segText.length - 1];
          final segEndsTerm = sentenceTerms.contains(segLast);

          // 已有挂起句，且本段是行首第一段 → 先判定是否与上一句跨行合并
          // （仅当上一句未结束——行内切段后段末无终止标点才可能挂起）。
          if (sb.isNotEmpty && rects.isNotEmpty) {
            final merge = canMergeLines(
              prevRight: rects.last.right,
              prevLeft: rects.last.left,
              blockRight: blockRight / imageWidth,
              nextLeft: rx,
              blockLeft: blockLeft / imageWidth,
              charW: charW / imageWidth,
              prevLastChar: lastChar,
              nextFirstChar: segFirst,
              nextLineText: segText,
            );
            if (!merge) {
              flush();
            } else if (needsSpaceBetween(lastChar, segFirst)) {
              sb.write(' ');
            }
          }

          sb.write(segText);
          rects.add(rr);
          lastChar = segLast;
          if (segEndsTerm) flush();
        }
      }
      // 块结束: 收尾残留句
      flush();
    }
    return result;
  }

  /// 按终止标点把一行文本切成段（标点归入前段）。
  ///
  /// 与 [sentenceTerms]（`splitTextToSentences` 同一终止标点集）对齐：
  /// `"你好。世界！"` → `["你好。", "世界！"]`；无标点整行 → `["整行"]`。
  static List<String> _splitLineByTerms(String text) {
    final parts = text.split(RegExp('(?<=[$sentenceTerms])'));
    final out = <String>[];
    for (final p in parts) {
      final t = p.trim();
      if (t.isNotEmpty) out.add(t);
    }
    return out.isEmpty ? [text] : out;
  }

  /// 给定归一化点击点(0~1), 返回命中的句子(含吸附); 未命中返回 null。
  static OcrSentence? hitSentence(
    List<OcrSentence> sentences,
    Offset point, {
    double snap = 0.02,
  }) {
    if (sentences.isEmpty) return null;
    OcrSentence? best;
    var bestD = double.infinity;
    for (final s in sentences) {
      for (final r in s.rects) {
        if (r.contains(point)) return s;
        final d = _distToRect(point, r);
        if (d < bestD) {
          bestD = d;
          best = s;
        }
      }
    }
    // 吸附阈值基于归一化距离(约 2% 图宽)
    return bestD <= snap ? best : null;
  }

  // ---- 归一化换算 ----
  static double _normX(double px, double w) =>
      (px / w).clamp(0.0, 1.0).toDouble();
  static double _normY(double py, double h) =>
      (py / h).clamp(0.0, 1.0).toDouble();
  static Rect _normRect(Rect r, double w, double h) => Rect.fromLTRB(
    _normX(r.left, w),
    _normY(r.top, h),
    _normX(r.right, w),
    _normY(r.bottom, h),
  );

  static double _medianLineHeight(List<OcrLine> lines) {
    if (lines.isEmpty) return 20;
    final hs = lines.map((l) => l.boundingBox.height).toList()..sort();
    return hs[hs.length ~/ 2];
  }

  static double _distToRect(Offset p, Rect r) {
    final dx =
        p.dx < r.left ? r.left - p.dx : (p.dx > r.right ? p.dx - r.right : 0);
    final dy =
        p.dy < r.top ? r.top - p.dy : (p.dy > r.bottom ? p.dy - r.bottom : 0);
    return (dx * dx + dy * dy).toDouble();
  }
}

/// 解码 [Sentence.geometry] 的 JSON 为归一化矩形列表。
///
/// 格式：`{"rects":[[l,t,r,b],...]}`；解析失败或为空返回 null。
List<Rect>? decodeSentenceGeometry(String? json) {
  if (json == null || json.trim().isEmpty) return null;
  try {
    final decoded = jsonDecode(json);
    if (decoded is! Map) return null;
    final raw = decoded['rects'];
    if (raw is! List) return null;
    final rects = <Rect>[];
    for (final item in raw) {
      if (item is! List || item.length < 4) continue;
      rects.add(
        Rect.fromLTRB(
          (item[0] as num).toDouble(),
          (item[1] as num).toDouble(),
          (item[2] as num).toDouble(),
          (item[3] as num).toDouble(),
        ),
      );
    }
    return rects.isEmpty ? null : rects;
  } catch (_) {
    return null;
  }
}

/// 把句子矩形列表编码为 [Sentence.geometry] JSON。
String encodeSentenceGeometry(List<Rect> rects) {
  return jsonEncode({
    'rects':
        rects.map((r) => <double>[r.left, r.top, r.right, r.bottom]).toList(),
  });
}
