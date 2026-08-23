import '../core/models/book.dart';
import '../core/models/knowledge_extraction_job.dart';
import '../core/models/knowledge_point.dart';
import '../core/models/sentence.dart';
import '../core/storage/book_dao.dart';
import '../core/storage/database.dart';
import '../core/storage/knowledge_extraction_job_dao.dart';
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
  final Map<String, Future<KnowledgeExtractionResult>> _activeRuns = {};
  Future<void>? _resumeFuture;

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

  /// 整本批量提取。默认恢复当前任务，restart=true 时创建新任务代次。
  Future<KnowledgeExtractionResult> extractBook(
    Book book, {
    void Function(int done, int total)? onProgress,
    bool restart = false,
  }) {
    final active = _activeRuns[book.id];
    if (active != null) return active;
    final future = _runBook(book, onProgress: onProgress, restart: restart);
    _activeRuns[book.id] = future;
    return future.whenComplete(() => _activeRuns.remove(book.id));
  }

  Future<KnowledgeExtractionResult> _runBook(
    Book book, {
    void Function(int done, int total)? onProgress,
    required bool restart,
  }) async {
    final db = await DatabaseProvider.database;
    final sentenceDao = SentenceDao(db);
    final allSentences = await sentenceDao.getByBook(book.id);
    if (allSentences.isEmpty) {
      return const KnowledgeExtractionResult(errors: ['书籍无可提取文本']);
    }

    final indexed = ChapterIndexer.assignChapters(allSentences);
    final chapters = indexed.map((s) => s.chapter).toSet();
    final hasValidChapters = chapters.length >= 2;
    final pageGroups = <int, List<Sentence>>{};
    for (final sentence in indexed) {
      pageGroups.putIfAbsent(sentence.page, () => []).add(sentence);
    }
    final pageChapters = <int, int>{
      for (final entry in pageGroups.entries)
        entry.key: hasValidChapters ? entry.value.first.chapter : 0,
    };
    final jobDao = KnowledgeExtractionJobDao(db);
    var job = await jobDao.getByBook(book.id);
    if (restart || job == null || job.status == KnowledgeJobStatus.completed) {
      job = await jobDao.createJob(bookId: book.id, pageChapters: pageChapters);
    }
    final token = await jobDao.claim(job.id);
    if (token == null) {
      return KnowledgeExtractionResult(errors: ['《${book.title}》已有提取任务正在运行']);
    }

    final pointsDao = KnowledgePointDao(db);
    final pages = await jobDao.getPages(job.id);
    final errors = <String>[];
    final allPoints = <KnowledgePoint>[];
    String? summary;
    var done =
        pages.where((p) => p.status == KnowledgePageStatus.completed).length;
    var pointCount = await pointsDao.countByBook(book.id);
    _publishProgress(
      book,
      done: done,
      total: pages.length,
      pointCount: pointCount,
      running: true,
      onProgress: onProgress,
    );

    for (final checkpoint in pages) {
      if (checkpoint.status == KnowledgePageStatus.completed) continue;
      final pageSentences = pageGroups[checkpoint.page] ?? const <Sentence>[];
      if (!await jobDao.markPageRunning(job.id, token, checkpoint)) continue;
      await jobDao.renew(job.id, token);
      final result = await extractForScope(
        bookId: book.id,
        page: checkpoint.page,
        chapter: checkpoint.chapter,
        sentences: pageSentences,
        persist: false,
      );
      if (result.errors.isNotEmpty) {
        final message = result.errors.join('；');
        errors.add(message);
        await jobDao.markPageFailed(job.id, token, checkpoint.page, message);
        _publishProgress(
          book,
          done: done,
          total: pages.length,
          pointCount: pointCount,
          running: false,
          error: message,
          onProgress: onProgress,
        );
        return KnowledgeExtractionResult(
          summary: summary,
          points: allPoints,
          errors: errors,
        );
      }
      await db.transaction((txn) async {
        for (final point in result.points) {
          await pointsDao.upsertByTextInExecutor(
            txn,
            book.id,
            point.type,
            point.text,
            page: point.page,
            chapter: point.chapter,
            definition: point.definition,
            extra: point.extra,
          );
        }
        pointCount = await pointsDao.countByBookInExecutor(txn, book.id);
        final completed = done + 1;
        final ok = await jobDao.completePage(
          txn,
          jobId: job!.id,
          token: token,
          page: checkpoint.page,
          pointCount: pointCount,
          isLastPage: completed == pages.length,
        );
        if (!ok) throw StateError('知识提取任务已被其他运行实例接管');
      });
      done++;
      allPoints.addAll(result.points);
      if (result.summary != null) {
        summary =
            summary == null ? result.summary : '$summary\n\n${result.summary}';
      }
      onProgress?.call(done, pages.length);
      _publishProgress(
        book,
        done: done,
        total: pages.length,
        pointCount: pointCount,
        running: done < pages.length,
        onProgress: onProgress,
      );
    }

    _publishProgress(
      book,
      done: done,
      total: pages.length,
      pointCount: pointCount,
      running: false,
      onProgress: onProgress,
    );
    return KnowledgeExtractionResult(
      summary: summary,
      points: allPoints,
      errors: errors,
    );
  }

  Future<void> clearCheckpoint(String bookId) async {
    final db = await DatabaseProvider.database;
    await KnowledgeExtractionJobDao(db).clearBook(bookId);
  }

  Future<void> resumePendingJobs() async {
    final inFlight = _resumeFuture;
    if (inFlight != null) return inFlight;
    final future = _resumePendingJobs();
    _resumeFuture = future;
    try {
      await future;
    } finally {
      if (identical(_resumeFuture, future)) _resumeFuture = null;
    }
  }

  Future<void> _resumePendingJobs() async {
    final db = await DatabaseProvider.database;
    final jobs = await KnowledgeExtractionJobDao(db).getRecoverable();
    for (final job in jobs) {
      final rows = await BookDao(db).getById(job.bookId);
      if (rows != null) await extractBook(rows);
    }
    final unfinished = await KnowledgeExtractionJobDao(db).getUnfinished();
    for (final job in unfinished) {
      if (jobs.any((candidate) => candidate.id == job.id)) continue;
      final book = await BookDao(db).getById(job.bookId);
      if (book == null) continue;
      _notify(
        KnowledgeTaskProgress(
          bookId: job.bookId,
          bookTitle: book.title,
          done: job.completedPages,
          total: job.totalPages,
          pointCount: job.pointCount,
          isRunning: false,
          error: job.lastError,
        ),
      );
    }
  }

  void _publishProgress(
    Book book, {
    required int done,
    required int total,
    required int pointCount,
    required bool running,
    String? error,
    void Function(int done, int total)? onProgress,
  }) {
    _notify(
      KnowledgeTaskProgress(
        bookId: book.id,
        bookTitle: book.title,
        done: done,
        total: total,
        pointCount: pointCount,
        isRunning: running,
        error: error,
      ),
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
