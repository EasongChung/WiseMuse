import 'model_ids.dart';

/// [v0.2.0] 一句可朗读文本 + 可选归一化几何。
///
/// 一次导入按页切句后入库，作为后续跟读/听写/生词复用的文本骨架。
/// [geometry] 仅在 camera/gallery 图片书导入时写入（OCR 归一化 rects JSON，
/// 避免每次打开阅读页重跑 ML Kit）；PDF 几何不持久化（运行时逐页从原文件
/// 提取，speak_reader 同款）；TXT/Word 恒为 null。
class Sentence {
  Sentence({
    required this.id,
    required this.bookId,
    required this.page,
    required this.chapter,
    required this.index,
    required this.text,
    this.geometry,
  });

  /// 生成带时间戳与随机后缀的新句子。
  factory Sentence.create({
    required String bookId,
    required int page,
    required int chapter,
    required int index,
    required String text,
    String? geometry,
  }) {
    return Sentence(
      id: newModelId('sent'),
      bookId: bookId,
      page: page,
      chapter: chapter,
      index: index,
      text: text,
      geometry: geometry,
    );
  }

  final String id;
  final String bookId;

  /// 页码：PDF 真实页码(0-based)；TXT/Word 固定 0。
  final int page;

  /// 章节（保留字段，Phase2+3 固定 0，后续 text_chunker 填充）。
  final int chapter;

  /// 页内句序号(0-based)。
  final int index;

  /// 句文本（跨行已补空格）。
  final String text;

  /// 归一化几何 JSON：`{"rects":[[l,t,r,b],...]}`（0~1，仅图片书）。
  final String? geometry;

  Map<String, dynamic> toMap() => {
    'id': id,
    'book_id': bookId,
    'page': page,
    'chapter': chapter,
    // SQLite 保留字 index 不可做列名，故列名为 sentence_index
    'sentence_index': index,
    'text': text,
    'geometry': geometry,
  };

  factory Sentence.fromMap(Map<String, dynamic> map) => Sentence(
    id: map['id'] as String,
    bookId: map['book_id'] as String,
    page: (map['page'] as int?) ?? 0,
    chapter: (map['chapter'] as int?) ?? 0,
    index: (map['sentence_index'] as int?) ?? 0,
    text: (map['text'] as String?) ?? '',
    geometry: map['geometry'] as String?,
  );
}
