import '../core/models/book.dart';
import '../core/models/knowledge_point.dart';
import '../core/models/sentence.dart';
import '../core/storage/database.dart';
import '../core/storage/knowledge_point_dao.dart';
import '../core/storage/sentence_dao.dart';
import '../core/utils/json_util.dart';
import 'ai_service.dart';
import 'chapter_indexer.dart';
import 'sentence_splitter.dart';

/// [v0.3.0] AI 知识提取服务：按页/章节提取知识点并落知识库。
///
/// 流程：
/// 1. 拼接 scope 句子 → 超长按句分块
/// 2. AiService.complete(prompt, jsonObject:true) → 双引擎回落
/// 3. parseLooseJsonObject 解析 → 校验/去重/批内+库内去重
/// 4. KnowledgePointDao.upsertByText 落库（AI 重复提取不建重复行）
///
/// 依赖 AiService（S2）+ KnowledgePointDao（S1）。
class KnowledgeExtractionService {
  KnowledgeExtractionService({AiService? ai}) : _ai = ai ?? AiService();

  final AiService _ai;

  /// 单次调用文本上限（安全 token 预算，约 750 token 按中文）。
  static const int maxCharsPerCall = 3000;

  /// 按 scope 提取知识点。
  ///
  /// [bookId] 书籍 id；[page]/[chapter] 可选（null 时提取整本或整章）；
  /// [sentences] 该 scope 的句子列表（调用方预取）。
  /// [persist] 是否写库（false 返回预览结果，用于测试）。
  ///
  /// 返回提取结果（summary + 知识点列表 + 错误信息）。
  Future<KnowledgeExtractionResult> extractForScope({
    required String bookId,
    int? page,
    int? chapter,
    required List<Sentence> sentences,
    bool persist = true,
  }) async {
    if (sentences.isEmpty) {
      return KnowledgeExtractionResult(errors: ['该范围无文本内容']);
    }

    // 拼合文本
    final fullText = sentences.map((s) => s.text).join('\n');
    final chunks = _splitIntoChunks(fullText);

    final allPoints = <KnowledgePoint>[];
    final errors = <String>[];
    String? summary;

    for (var i = 0; i < chunks.length; i++) {
      final chunk = chunks[i];
      final prompt = _buildPrompt(
        chunk,
        page: page,
        chapter: chapter,
        totalChunks: chunks.length,
        chunkIndex: i,
      );

      final result = await _ai.complete(prompt, jsonObject: true);
      if (result == null) {
        errors.add('第 ${i + 1}/${chunks.length} 块提取失败（AI 不可用或无响应）');
        continue;
      }

      final parsed = parseLooseJsonObject(result.text);
      if (parsed == null) {
        errors.add('第 ${i + 1}/${chunks.length} 块 AI 响应解析失败');
        continue;
      }

      // 提取 summary
      if (summary == null) {
        summary = parsed['summary'] as String?;
      } else {
        final extra = parsed['summary'] as String?;
        if (extra != null) summary = '$summary\n$extra';
      }

      // 提取知识点
      final kps = parsed['knowledge_points'] as List?;
      if (kps == null) {
        errors.add('第 ${i + 1}/${chunks.length} 块未提取到知识点');
        continue;
      }

      for (final raw in kps) {
        final map = raw as Map<String, dynamic>?;
        if (map == null) continue;
        final text = map['text'] as String?;
        final typeStr = map['type'] as String?;
        if (text == null || text.isEmpty || typeStr == null) continue;

        final type = KnowledgeType.fromName(typeStr);
        allPoints.add(
          KnowledgePoint.create(
            bookId: bookId,
            page: page,
            chapter: chapter,
            type: type,
            text: text,
            definition: map['definition'] as String?,
            extra: map['extra'] as String?,
          ),
        );
      }
    }

    // 批内去重（按 bookId+type+text 去重，已存在则更新旧条目的归属）
    final seen = <String>{};
    final deduped = <KnowledgePoint>[];
    for (final kp in allPoints) {
      final key = '${kp.bookId}:${kp.type.name}:${kp.text}';
      if (seen.add(key)) {
        deduped.add(kp);
      }
    }

    // 落库
    if (persist && deduped.isNotEmpty) {
      final db = await DatabaseProvider.database;
      final dao = KnowledgePointDao(db);
      for (final kp in deduped) {
        await dao.upsertByText(
          kp.bookId ?? '',
          kp.type,
          kp.text,
          page: kp.page,
          chapter: kp.chapter,
          definition: kp.definition,
          extra: kp.extra,
        );
      }
    }

    return KnowledgeExtractionResult(
      summary: summary,
      points: deduped,
      errors: errors,
    );
  }

  /// 整本批量提取，按页逐页处理，带回调和进度。
  Future<KnowledgeExtractionResult> extractBook(
    Book book, {
    void Function(int done, int total)? onProgress,
    AiService? aiOverride,
  }) async {
    final db = await DatabaseProvider.database;
    final sentenceDao = SentenceDao(db);
    final allSentences = await sentenceDao.getByBook(book.id);

    if (allSentences.isEmpty) {
      return KnowledgeExtractionResult(errors: ['书籍无可提取文本']);
    }

    // 章节索引
    final indexedSentences = ChapterIndexer.assignChapters(allSentences);

    // 按页分组
    final pageGroups = <int, List<Sentence>>{};
    for (final s in indexedSentences) {
      pageGroups.putIfAbsent(s.page, () => []).add(s);
    }

    final allPoints = <KnowledgePoint>[];
    final errors = <String>[];
    String? summary;
    var done = 0;
    final total = pageGroups.length;

    for (final entry in pageGroups.entries) {
      final page = entry.key;
      final sentences = entry.value;
      final chapter = sentences.first.chapter;

      final result = await extractForScope(
        bookId: book.id,
        page: page,
        chapter: chapter,
        sentences: sentences,
        persist: true,
      );

      allPoints.addAll(result.points);
      errors.addAll(result.errors);
      if (result.summary != null) {
        summary =
            summary == null ? result.summary : '$summary\n\n${result.summary}';
      }

      done++;
      onProgress?.call(done, total);
    }

    return KnowledgeExtractionResult(
      summary: summary,
      points: allPoints,
      errors: errors,
    );
  }

  /// 构造 AI prompt。
  String _buildPrompt(
    String text, {
    int? page,
    int? chapter,
    int totalChunks = 1,
    int chunkIndex = 0,
  }) {
    final scopeTag =
        page != null && chapter != null
            ? '（第 $page 页，第 $chapter 章）'
            : page != null
            ? '（第 $page 页）'
            : chapter != null
            ? '（第 $chapter 章）'
            : '（全书）';
    final chunkTag =
        totalChunks > 1 ? '（第 ${chunkIndex + 1}/$totalChunks 块）' : '';

    return '''书籍文本$scopeTag$chunkTag：
$text
---
请提取知识点。返回 JSON：
{"summary": "该部分的简要概述（30 字以内）",
 "knowledge_points": [
   {"text": "词语", "type": "word", "definition": "释义", "extra": "拼音/例句"},
   {"text": "成语", "type": "idiom", "definition": "释义与出处"},
   {"text": "word", "type": "english", "definition": "中文释义", "extra": "音标/例句"},
   {"text": "诗句", "type": "poem", "definition": "出处/作者", "extra": "下一句或赏析"}
 ]}
要求：
- 词语：书籍中值得学习的生词（最多 8 条）
- 成语：书籍中的四字成语（最多 8 条）
- english：书籍中的英语单词（最多 8 条，附中文释义）
- 古诗词：书籍中引用的诗词句（最多 4 条，附出处）
- 每类宁缺毋滥，无相关内容则留空数组
只输出 JSON，不要多余文字。''';
  }

  /// 超长文本按句分块（保持句子完整）。
  List<String> _splitIntoChunks(String text) {
    if (text.length <= maxCharsPerCall) return [text];

    final sentences = splitTextToSentences(text);
    final chunks = <String>[];
    var buf = StringBuffer();
    for (final s in sentences) {
      if (buf.length + s.length > maxCharsPerCall && buf.isNotEmpty) {
        chunks.add(buf.toString().trim());
        buf.clear();
      }
      buf.write(s);
    }
    if (buf.isNotEmpty) chunks.add(buf.toString().trim());
    return chunks;
  }
}

/// 知识提取结果。
class KnowledgeExtractionResult {
  const KnowledgeExtractionResult({
    this.summary,
    this.points = const [],
    this.errors = const [],
  });

  /// 全文概要（各块拼接）。
  final String? summary;

  /// 本次提取的知识点（已去重、已落库？看 persist 参数）。
  final List<KnowledgePoint> points;

  /// 失败信息（非致命，UI 可提示用户重试该块）。
  final List<String> errors;
}
