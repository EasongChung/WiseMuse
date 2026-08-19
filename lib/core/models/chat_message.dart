import 'dart:convert';

import 'model_ids.dart';

/// [v0.1.48] AI 会话消息模型。
///
/// [v0.1.52] 新增 [imagePaths]：多模态消息时保存图片本地路径列表（JSON 序列化）。
class ChatMessage {
  ChatMessage({
    required this.id,
    this.sessionId,
    this.profileId = 'default',
    required this.role,
    required this.content,
    this.imagePaths,
    this.bookId,
    this.bookTitle,
    this.sources,
    required this.createdAt,
  });

  factory ChatMessage.create({
    String? sessionId,
    String profileId = 'default',
    required String role,
    required String content,
    List<String>? imagePaths,
    String? bookId,
    String? bookTitle,
    String? sources,
  }) {
    return ChatMessage(
      id: newModelId('chat'),
      sessionId: sessionId,
      profileId: profileId,
      role: role,
      content: content,
      imagePaths: imagePaths,
      bookId: bookId,
      bookTitle: bookTitle,
      sources: sources,
      createdAt: DateTime.now().microsecondsSinceEpoch,
    );
  }

  final String id;
  String? sessionId;
  final String profileId;

  /// 'user' | 'assistant' | 'system'
  final String role;

  final String content;

  /// [v0.1.52] 多模态消息时附带的图片本地路径列表（JSON 序列化到 DB）。
  final List<String>? imagePaths;

  /// 可选关联的书籍（RAG 会话）
  final String? bookId;
  final String? bookTitle;

  /// RAG 检索到的参考片段 JSON/纯文本
  final String? sources;

  final int createdAt;

  Map<String, dynamic> toMap() => {
    'id': id,
    'session_id': sessionId,
    'profile_id': profileId,
    'role': role,
    'content': content,
    'image_paths': imagePaths != null ? jsonEncode(imagePaths) : null,
    'book_id': bookId,
    'book_title': bookTitle,
    'sources': sources,
    'created_at': createdAt,
  };

  factory ChatMessage.fromMap(Map<String, dynamic> map) => ChatMessage(
    id: map['id'] as String,
    sessionId: map['session_id'] as String?,
    profileId: (map['profile_id'] as String?) ?? 'default',
    role: (map['role'] as String?) ?? 'user',
    content: (map['content'] as String?) ?? '',
    imagePaths: _parseImagePaths(map['image_paths'] as String?),
    bookId: map['book_id'] as String?,
    bookTitle: map['book_title'] as String?,
    sources: map['sources'] as String?,
    createdAt: (map['created_at'] as int?) ?? 0,
  );

  static List<String>? _parseImagePaths(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final list = jsonDecode(raw) as List;
      return list.cast<String>();
    } catch (_) {
      return null;
    }
  }
}
