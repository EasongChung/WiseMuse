import '../core/debug/app_log.dart';
import '../core/models/sentence.dart';
import 'text_chunker.dart';

/// [v0.3.0] 章节索引器（MVP-lite 版，保守）。
///
/// 扫描全书句子列表，检测到至少 2 个章节标题行时给每句分配 chapter 号。
/// 未检测到时全部 chapter=0（全书即一章）。
///
/// 返回新列表（不修改输入），Sentence.chapter 不可变。
class ChapterIndexer {
  static const _tag = 'chapter_idx';

  /// 为句子列表分配章节号，返回新列表（原列表不变）。
  ///
  /// 规则：
  /// - 是章节标题行 → 新章开始（自身 chapter = 该章号）
  /// - 非标题行 → 沿用当前章号
  /// - 标题行数 ≥ 2 才启用章节索引（否则全 0）
  static List<Sentence> assignChapters(List<Sentence> sentences) {
    if (sentences.isEmpty) return const [];

    // 统计章节标题行
    final titleIndices = <int>{};
    for (var i = 0; i < sentences.length; i++) {
      if (isChapterLine(sentences[i].text)) {
        titleIndices.add(i);
      }
    }

    // 少于 2 个标题行 → 全书即一章
    if (titleIndices.length < 2) {
      AppLog.d(_tag, '章节标题行不足 2 个（${titleIndices.length}），全书视为一章');
      return sentences
          .map(
            (s) => Sentence(
              id: s.id,
              bookId: s.bookId,
              page: s.page,
              chapter: 0,
              index: s.index,
              text: s.text,
              geometry: s.geometry,
            ),
          )
          .toList();
    }

    // 分配章节号
    var currentChapter = 0;
    final result = <Sentence>[];
    for (var i = 0; i < sentences.length; i++) {
      if (titleIndices.contains(i)) {
        currentChapter++;
      }
      final s = sentences[i];
      result.add(
        Sentence(
          id: s.id,
          bookId: s.bookId,
          page: s.page,
          chapter: currentChapter,
          index: s.index,
          text: s.text,
          geometry: s.geometry,
        ),
      );
    }

    AppLog.d(
      _tag,
      '章节索引完成: ${titleIndices.length} 标题行, '
      '$currentChapter 章, ${result.length} 句',
    );
    return result;
  }
}
