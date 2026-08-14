import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/debug/app_log.dart';
import '../openai_client.dart';

/// [v2.10.0] Embedding 服务：云端 API 优先，无配置时回落文本检索。
///
/// 封装 [OpenAiClient.embeddings()] 调用云端 embedding 模型。
/// 未配置时 [embed]/[embedBatch] 返回 null，由上层降级为 BM25 文本匹配。
class EmbeddingService {
  EmbeddingService._();
  static final EmbeddingService instance = EmbeddingService._();

  static const _tag = 'embed';

  OpenAiClient? _client;

  OpenAiClient get _openai => _client ??= OpenAiClient();

  /// 云端 embedding API 是否已配置。
  Future<bool> isCloudReady() async {
    final sett = await _loadSettings();
    return sett.$1.isNotEmpty && sett.$2.isNotEmpty;
  }

  /// 单文本转向量。返回 null 说明云端不可用。
  Future<List<double>?> embed(String text) async {
    final results = await embedBatch([text]);
    return results?.firstOrNull;
  }

  /// 批量转向量，返回 null 说明云端不可用。
  Future<List<List<double>>?> embedBatch(List<String> texts) async {
    if (texts.isEmpty) return const [];
    final sett = await _loadSettings();
    if (sett.$1.isEmpty || sett.$2.isEmpty) {
      AppLog.d(_tag, '云端未配置，返回 null');
      return null;
    }
    return _openai.embeddings(
      texts,
      baseUrl: sett.$1,
      apiKey: sett.$2,
      model: sett.$3,
    );
  }

  /// 释放。
  void dispose() {
    _client?.dispose();
    _client = null;
  }

  /// 从 SharedPreferences 读取 embedding 相关配置。
  static Future<(String, String, String)> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      prefs.getString('api_base_url') ?? '',
      prefs.getString('api_key') ?? '',
      prefs.getString('embedding_model') ?? 'text-embedding-3-small',
    );
  }

  // ---------- 包内工具 ----------

  /// 简单文本检索评分（BM25 风格回落）：按查询词在 chunk 中的 TF-IDF 加权评分。
  ///
  /// 返回 [(chunkIndex, score)]，已降序；空查询或无匹配返回空。
  static List<(int, double)> textSearchRank(
    String query,
    List<String> chunkTexts,
  ) {
    if (query.trim().isEmpty || chunkTexts.isEmpty) return const [];

    final queryTerms = query
        .toLowerCase()
        .split(RegExp(r'[\s\p{P}]+'))
        .where((t) => t.length >= 2)
        .toList();
    if (queryTerms.isEmpty) return const [];

    final n = chunkTexts.length;
    // 文档频率 df：出现该词的 chunk 数
    final df = <String, int>{};
    final termInChunks = <int, Set<String>>{};
    for (var i = 0; i < n; i++) {
      final terms = chunkTexts[i]
          .toLowerCase()
          .split(RegExp(r'[\s\p{P}]+'))
          .where((t) => t.length >= 2)
          .toSet();
      termInChunks[i] = terms;
      for (final t in terms) {
        df[t] = (df[t] ?? 0) + 1;
      }
    }
    final idf = df.map((k, v) => MapEntry(k, log((n + 1) / (v + 1)) + 1));

    final results = <(int, double)>[];
    for (var i = 0; i < n; i++) {
      final terms = termInChunks[i]!;
      double score = 0;
      for (final qt in queryTerms) {
        if (terms.contains(qt)) {
          score += idf[qt] ?? 1;
        }
      }
      if (score > 0) {
        results.add((i, score / queryTerms.length));
      }
    }
    results.sort((a, b) => b.$2.compareTo(a.$2));
    return results;
  }
}