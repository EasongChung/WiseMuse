import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/debug/app_log.dart';
import '../../core/models/sentence.dart';
import 'embedding_service.dart';

/// [v0.1.37] 教材 RAG 向量索引（内存 Map + JSON 持久化）。
///
/// 每本书独立索引文件 `{documents}/rag_index/{bookId}.json`。
/// 构建时先尝试云端 embedding，失败则存纯文本供 BM25 回落。
class VectorIndex {
  VectorIndex._();
  static final VectorIndex instance = VectorIndex._();

  static const _tag = 'vector_idx';
  static const _indexDir = 'rag_index';

  // 内存缓存：bookId → IndexChunk[]
  final Map<String, List<IndexChunk>> _cache = {};

  // 正在构建的 bookId 集合，防并发重复构建
  final Set<String> _building = {};

  /// 当前已加载到内存的 bookId 列表。
  Set<String> get loadedBookIds => _cache.keys.toSet();

  /// 检查某书是否正在构建索引。
  bool isBuilding(String bookId) => _building.contains(bookId);

  /// 检查某书是否已有索引文件。
  Future<bool> isIndexed(String bookId) async {
    final file = await _indexFile(bookId);
    return file.existsSync();
  }

  /// 构建并缓存某书的向量索引。
  ///
  /// [sentences] 该书的全部句子（需含文本与页码）。
  /// 返回构建的 chunk 数，0 表示无可索引内容。
  Future<int> buildIndex(String bookId, List<Sentence> sentences) async {
    if (sentences.isEmpty) return 0;
    if (_building.contains(bookId)) {
      AppLog.d(_tag, 'book=$bookId 正在构建，跳过');
      return 0;
    }

    _building.add(bookId);
    try {
      // 分块：3-5 句一组，跨块有 1 句重叠保持上下文连贯
      final chunks = _chunkSentences(sentences);

      // 尝试 embedding
      final texts = chunks.map((c) => c.text).toList();
      final embeddings = await EmbeddingService.instance.embedBatch(texts);

      // 构造成 IndexChunk
      final indexChunks = <IndexChunk>[];
      for (var i = 0; i < chunks.length; i++) {
        indexChunks.add(
          IndexChunk(
            id: i,
            text: chunks[i].text,
            sentenceIds: chunks[i].sentenceIds,
            embedding:
                embeddings != null && i < embeddings.length
                    ? embeddings[i]
                    : null,
          ),
        );
      }

      // 持久化
      await _saveIndex(bookId, indexChunks);

      // 缓存
      _cache[bookId] = indexChunks;

      AppLog.d(_tag, 'book=$bookId 索引完成: ${indexChunks.length} chunks');
      return indexChunks.length;
    } catch (e, s) {
      AppLog.e(_tag, 'buildIndex 失败 book=$bookId: $e\n$s');
      return 0;
    } finally {
      _building.remove(bookId);
    }
  }

  /// 加载某书索引到内存（如有缓存则跳过）。
  Future<List<IndexChunk>> loadIndex(String bookId) async {
    if (_cache.containsKey(bookId)) return _cache[bookId]!;

    final file = await _indexFile(bookId);
    if (!file.existsSync()) {
      AppLog.d(_tag, '索引文件不存在 book=$bookId');
      return const [];
    }

    try {
      final content = await file.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      final list = (json['chunks'] as List).cast<Map<String, dynamic>>();
      final chunks = list.map((m) => IndexChunk.fromJson(m)).toList();
      _cache[bookId] = chunks;
      return chunks;
    } catch (e) {
      AppLog.e(_tag, '加载索引失败 book=$bookId: $e');
      return const [];
    }
  }

  /// 检索：给定 query 向量或文本，返回 top-k 相关 chunk。
  ///
  /// [queryEmbedding] 不为 null → 余弦相似度；
  /// null → BM25 文本匹配降级。
  Future<List<SearchResult>> search(
    String bookId,
    String query, {
    List<double>? queryEmbedding,
    int topK = 5,
  }) async {
    final chunks = await loadIndex(bookId);
    if (chunks.isEmpty) return const [];

    if (queryEmbedding != null && chunks.any((c) => c.embedding != null)) {
      // 向量检索：余弦相似度
      final scored = <(int, double)>[];
      for (var i = 0; i < chunks.length; i++) {
        final emb = chunks[i].embedding;
        if (emb != null && emb.length == queryEmbedding.length) {
          final sim = _cosineSimilarity(queryEmbedding, emb);
          scored.add((i, sim));
        }
      }
      scored.sort((a, b) => b.$2.compareTo(a.$2));
      return scored.take(topK).map((s) {
        final chunk = chunks[s.$1];
        return SearchResult(chunk: chunk, score: s.$2, method: 'vector');
      }).toList();
    }

    // BM25 文本检索降级
    final texts = chunks.map((c) => c.text).toList();
    final ranked = EmbeddingService.textSearchRank(query, texts);
    return ranked.take(topK).map((r) {
      return SearchResult(chunk: chunks[r.$1], score: r.$2, method: 'text');
    }).toList();
  }

  /// 删除某书索引（文件 + 缓存）。
  Future<void> deleteIndex(String bookId) async {
    _cache.remove(bookId);
    final file = await _indexFile(bookId);
    if (file.existsSync()) {
      await file.delete();
      AppLog.d(_tag, '索引已删除 book=$bookId');
    }
  }

  /// 列出所有已索引的 bookId（扫描索引目录）。
  Future<List<String>> listIndexedBooks() async {
    final dir = await _indexDirPath();
    if (!await dir.exists()) return const [];
    final files =
        await dir
            .list()
            .where((e) => e is File && e.path.endsWith('.json'))
            .map((e) => p.basenameWithoutExtension(e.path))
            .toList();
    return files;
  }

  // ===== 内部工具 =====

  /// 分句为块（3-5 句/块，跨块 1 句重叠）。
  static List<_TextChunk> _chunkSentences(List<Sentence> sentences) {
    if (sentences.isEmpty) return const [];
    const int chunkSize = 4;
    const int overlap = 1;

    final chunks = <_TextChunk>[];
    var start = 0;
    while (start < sentences.length) {
      final end = (start + chunkSize).clamp(0, sentences.length);
      final batch = sentences.sublist(start, end);
      chunks.add(
        _TextChunk(
          text: batch.map((s) => s.text).join(''),
          sentenceIds: batch.map((s) => s.id).toList(),
        ),
      );
      if (end >= sentences.length) break;
      start += chunkSize - overlap;
    }
    return chunks;
  }

  /// 余弦相似度。
  static double _cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length) return 0;
    double dot = 0, normA = 0, normB = 0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    if (normA == 0 || normB == 0) return 0;
    return dot / (sqrt(normA) * sqrt(normB));
  }

  /// 索引文件路径。
  Future<File> _indexFile(String bookId) async {
    final dir = await _indexDirPath();
    return File(p.join(dir.path, '$bookId.json'));
  }

  /// 索引目录路径。
  Future<Directory> _indexDirPath() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, _indexDir));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 持久化索引到 JSON 文件。
  Future<void> _saveIndex(String bookId, List<IndexChunk> chunks) async {
    final file = await _indexFile(bookId);
    final data = {
      'version': 1,
      'book_id': bookId,
      'chunks': chunks.map((c) => c.toJson()).toList(),
    };
    await file.writeAsString(jsonEncode(data), flush: true);
    AppLog.d(_tag, '索引已持久化 book=$bookId (${chunks.length} chunks)');
  }
}

/// 索引块：文本 + 关联句子 ID + 向量（null=无 embedding）。
class IndexChunk {
  const IndexChunk({
    required this.id,
    required this.text,
    required this.sentenceIds,
    this.embedding,
  });

  final int id;
  final String text;
  final List<String> sentenceIds;
  final List<double>? embedding;

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'sentence_ids': sentenceIds,
    if (embedding != null) 'embedding': embedding,
  };

  factory IndexChunk.fromJson(Map<String, dynamic> json) => IndexChunk(
    id: json['id'] as int,
    text: json['text'] as String,
    sentenceIds: (json['sentence_ids'] as List).cast<String>(),
    embedding: (json['embedding'] as List?)?.cast<double>(),
  );
}

/// 检索结果。
class SearchResult {
  const SearchResult({
    required this.chunk,
    required this.score,
    required this.method,
  });

  final IndexChunk chunk;
  final double score;
  final String method; // 'vector' | 'text'

  /// 相关文本摘要（截取前 200 字）。
  String get snippet =>
      chunk.text.length > 200 ? '${chunk.text.substring(0, 200)}…' : chunk.text;
}

/// 内部文本块（构建用）。
class _TextChunk {
  const _TextChunk({required this.text, required this.sentenceIds});
  final String text;
  final List<String> sentenceIds;
}
