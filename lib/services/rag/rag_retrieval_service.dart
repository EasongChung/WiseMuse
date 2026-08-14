import '../../core/debug/app_log.dart';
import '../../core/models/book.dart';
import '../../core/storage/database.dart';
import '../../core/storage/sentence_dao.dart';
import 'embedding_service.dart';
import 'vector_index.dart';

/// [v2.10.0] RAG 检索编排：教材文本分块 → embedding → 索引 → 检索。
///
/// 整合 [EmbeddingService] 与 [VectorIndex]，提供全书索引、检索、
/// 状态查询的统一入口。
class RagRetrievalService {
  RagRetrievalService._();
  static final RagRetrievalService instance = RagRetrievalService._();

  static const _tag = 'rag_retrieval';

  final VectorIndex _index = VectorIndex.instance;
  final EmbeddingService _embedding = EmbeddingService.instance;

  /// 为某书构建 RAG 索引。
  ///
  /// 从数据库取该书全部句子 → 分块 → embedding → 持久化到文件。
  /// 返回构建的 chunk 数，0 表示无内容。
  Future<int> buildIndex(Book book) async {
    if (_index.isBuilding(book.id)) {
      AppLog.d(_tag, 'book=${book.id} 正在构建中');
      return 0;
    }

    AppLog.d(_tag, '开始构建索引 book=${book.id} title=${book.title}');
    final db = await DatabaseProvider.database;
    final dao = SentenceDao(db);
    final sentences = await dao.getByBook(book.id);
    if (sentences.isEmpty) {
      AppLog.w(_tag, 'book=${book.id} 无句子，跳过索引');
      return 0;
    }

    return _index.buildIndex(book.id, sentences);
  }

  /// 检索：给定 query 文本，返回 top-k 相关 chunk。
  ///
  /// 先尝试对 query 做 embedding，向量检索；embedding 不可用时降级 BM25。
  Future<List<SearchResult>> search(
    String bookId,
    String query, {
    int topK = 5,
  }) async {
    // 尝试 query embedding
    List<double>? queryEmb;
    if (await _embedding.isCloudReady()) {
      queryEmb = await _embedding.embed(query);
    }

    return _index.search(
      bookId,
      query,
      queryEmbedding: queryEmb,
      topK: topK,
    );
  }

  /// 检索并拼接上下文文本（供 LLM prompt 使用）。
  ///
  /// 返回 [context, sourceInfo] — 上下文文本与来源说明（页码等）。
  /// 无结果时返回 null。
  Future<(String, String)?> retrieveContext(
    String bookId,
    String query, {
    int topK = 3,
  }) async {
    final results = await search(bookId, query, topK: topK);
    if (results.isEmpty) return null;

    final sb = StringBuffer();
    final sourceSb = StringBuffer();
    for (var i = 0; i < results.length; i++) {
      final r = results[i];
      sb.writeln('[片段 ${i + 1}]');
      sb.writeln(r.chunk.text);
      sb.writeln();
      sourceSb.writeln(
        '- 片段 ${i + 1}（相似度 ${r.score.toStringAsFixed(3)}，检索方式 ${r.method}）',
      );
    }
    return (sb.toString().trim(), sourceSb.toString().trim());
  }

  /// 书架中各书籍的索引状态。
  ///
  /// 返回 map：bookId → isIndexed。
  Future<Map<String, bool>> getIndexStatus(List<Book> books) async {
    if (books.isEmpty) return const {};
    final indexed = await _index.listIndexedBooks();
    final indexedSet = indexed.toSet();
    return {for (final b in books) b.id: indexedSet.contains(b.id)};
  }

  /// 删除某书索引。
  Future<void> deleteIndex(String bookId) async {
    await _index.deleteIndex(bookId);
  }

  /// 列出所有已索引的 bookId。
  Future<List<String>> listIndexedBooks() async {
    return _index.listIndexedBooks();
  }

  /// 检测某书是否已索引。
  Future<bool> isIndexed(String bookId) async {
    return _index.isIndexed(bookId);
  }

  /// 释放资源。
  void dispose() {
    _embedding.dispose();
  }
}