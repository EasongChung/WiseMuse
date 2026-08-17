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

/// 知识库提取任务状态。
class KnowledgeTaskProgress {
  final String bookId;
  final String bookTitle;
  final int done;
  final int total;
  final int pointCount;
  final bool isRunning;
  final String? error;

  const KnowledgeTaskProgress({
    required this.bookId,
    required this.bookTitle,
    required this.done,
    required this.total,
    required this.pointCount,
    required this.isRunning,
    this.error,
  });

  double get progress => total > 0 ? (done / total).clamp(0.0, 1.0) : 0.0;
}

/// [v0.3.0] AI 知识提取服务：按页/章节提取知识点并落知识库（支持按页回落与全局后台任务）。
class KnowledgeExtractionService {
  KnowledgeExtractionService({AiService? ai}) : _ai = ai ?? AiService();

  static final KnowledgeExtractionService instance =
      KnowledgeExtractionService();

  final AiService _ai;

  /// 全局任务状态回调列表。
  final List<void Function(KnowledgeTaskProgress)> _listeners = [];
  KnowledgeTaskProgress? _currentTask;

  KnowledgeTaskProgress? get currentTask => _currentTask;

  void addListener(void Function(KnowledgeTaskProgress) listener) {
    _listeners.add(listener);
    if (_currentTask != null) listener(_currentTask!);
  }

  void removeListener(void Function(KnowledgeTaskProgress) listener) {
    _listeners.remove(listener);
  }

  void _notify(KnowledgeTaskProgress p) {
    _currentTask = p;
    for (final l in List.from(_listeners)) {
      l(p);
    }
  }

  /// 单次调用文本上限（安全 token 预算）。
  static const int maxCharsPerCall = 3000;

  /// 按 scope 提取知识点。
  Future<KnowledgeExtractionResult> extractForScope({
    required String bookId,
    int? page,
    int? chapter,
    required List<Sentence> sentences,
    bool persist = true,
  }) async {
    if (sentences.isEmpty) {
      return const KnowledgeExtractionResult(errors: ['该范围无文本内容']);
    }

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

      if (summary == null) {
        summary = parsed['summary'] as String?;
      } else {
        final extra = parsed['summary'] as String?;
        if (extra != null) summary = '$summary\n$extra';
      }

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

    // 批内去重
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

  /// 整本批量提取（支持后台运行与通知）。
  Future<KnowledgeExtractionResult> extractBook(
    Book book, {
    void Function(int done, int total)? onProgress,
  }) async {
    final db = await DatabaseProvider.database;
    final sentenceDao = SentenceDao(db);
    final allSentences = await sentenceDao.getByBook(book.id);

    if (allSentences.isEmpty) {
      return const KnowledgeExtractionResult(errors: ['书籍无可提取文本']);
    }

    // [v0.1.48] 章节索引与智能按页回落
    final indexedSentences = ChapterIndexer.assignChapters(allSentences);
    final detectedChapters = indexedSentences.map((s) => s.chapter).toSet();
    final hasValidChapters = detectedChapters.length >= 2;

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

    _notify(
      KnowledgeTaskProgress(
        bookId: book.id,
        bookTitle: book.title,
        done: 0,
        total: total,
        pointCount: 0,
        isRunning: true,
      ),
    );

    for (final entry in pageGroups.entries) {
      final page = entry.key;
      final sentences = entry.value;
      // 若章节结构不清晰，回落为 0（UI 侧显示按页）
      final chapter = hasValidChapters ? sentences.first.chapter : 0;

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
      _notify(
        KnowledgeTaskProgress(
          bookId: book.id,
          bookTitle: book.title,
          done: done,
          total: total,
          pointCount: allPoints.length,
          isRunning: done < total,
        ),
      );
    }

    _notify(
      KnowledgeTaskProgress(
        bookId: book.id,
        bookTitle: book.title,
        done: total,
        total: total,
        pointCount: allPoints.length,
        isRunning: false,
      ),
    );

    return KnowledgeExtractionResult(
      summary: summary,
      points: allPoints,
      errors: errors,
    );
  }

  String _buildPrompt(
    String text, {
    int? page,
    int? chapter,
    int totalChunks = 1,
    int chunkIndex = 0,
  }) {
    final scopeTag =
        page != null && chapter != null && chapter > 0
            ? '（第 $page 页，第 $chapter 单元）'
            : page != null
            ? '（第 $page 页）'
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
   {"text": "诗词完整全篇（含题目、朝代作者与全部诗句，换行排列）", "type": "poem", "definition": "朝代与作者/出处", "extra": "全诗赏析或主旨"}
 ]}
要求：
- 词语：书籍中值得学习的生词（最多 8 条）
- 成语：书籍中的四字成语（最多 8 条）
- english：书籍中的英语单词（最多 8 条，附中文释义）
- 古诗词：若文本中包含古诗、文言古诗或诗歌，必须将【整首诗词全篇】（包含标题、作者与全部诗句）作为一个完整的诗词知识点提取在 text 中，严禁只截取单句（最多 3 条）
- 每类宁缺毋滥，无相关内容则留空数组
只输出 JSON，不要多余文字。''';
  }

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

  final String? summary;
  final List<KnowledgePoint> points;
  final List<String> errors;
}
