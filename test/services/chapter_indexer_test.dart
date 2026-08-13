import 'package:flutter_test/flutter_test.dart';

import 'package:wisemuse/core/models/sentence.dart';
import 'package:wisemuse/services/chapter_indexer.dart';

void main() {
  group('ChapterIndexer', () {
    Sentence makeSent(String text, {int page = 0, int idx = 0}) {
      return Sentence.create(
        bookId: 'b1',
        page: page,
        chapter: 0,
        index: idx,
        text: text,
      );
    }

    test('少于 2 个章节标题行 → 全部 chapter=0', () {
      final input = [
        makeSent('这是第一句。'), // 带句号，不走宽松标题规则
        makeSent('这是第二句。'),
      ];
      final result = ChapterIndexer.assignChapters(input);
      expect(result.every((s) => s.chapter == 0), isTrue);
      expect(result.length, 2);
    });

    test('空列表返回空', () {
      expect(ChapterIndexer.assignChapters([]), isEmpty);
    });

    test('≥2 个标题行时分配章节号', () {
      final input = [
        makeSent('第一章 基础篇'), // 匹配 ^第.*[章节部回部分]
        makeSent('这是第一句正文。'),
        makeSent('这是第二句正文。'),
        makeSent('第二章 进阶篇'),
        makeSent('进阶第一句。'),
      ];
      final result = ChapterIndexer.assignChapters(input);
      expect(result[0].chapter, 1);
      expect(result[1].chapter, 1);
      expect(result[2].chapter, 1);
      expect(result[3].chapter, 2);
      expect(result[4].chapter, 2);
    });

    test('原列表不变（不可变性）', () {
      final input = [makeSent('第一章'), makeSent('正文。'), makeSent('第二章')];
      final copy = [...input];
      ChapterIndexer.assignChapters(input);
      expect(input.every((s) => s.chapter == 0), isTrue);
      expect(input, copy);
    });
  });
}
