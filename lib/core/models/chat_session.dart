import 'model_ids.dart';

/// AI 会话范围。普通对话与书籍 RAG 必须隔离。
enum ChatScope {
  normal,
  book;

  static ChatScope fromName(String? name) => ChatScope.values.firstWhere(
    (value) => value.name == name,
    orElse: () => ChatScope.normal,
  );
}

/// [v0.1.60] 可持久化 AI 会话。
class ChatSession {
  ChatSession({
    required this.id,
    this.profileId = 'default',
    required this.scope,
    this.bookId,
    this.title,
    required this.createdAt,
    required this.updatedAt,
  });

  factory ChatSession.create({
    String profileId = 'default',
    required ChatScope scope,
    String? bookId,
    String? title,
  }) {
    final now = DateTime.now().microsecondsSinceEpoch;
    return ChatSession(
      id: newModelId('session'),
      profileId: profileId,
      scope: scope,
      bookId: bookId,
      title: title,
      createdAt: now,
      updatedAt: now,
    );
  }

  final String id;
  final String profileId;
  final ChatScope scope;
  final String? bookId;
  String? title;
  final int createdAt;
  int updatedAt;

  Map<String, dynamic> toMap() => {
    'id': id,
    'profile_id': profileId,
    'scope': scope.name,
    'book_id': bookId,
    'title': title,
    'created_at': createdAt,
    'updated_at': updatedAt,
  };

  factory ChatSession.fromMap(Map<String, dynamic> map) => ChatSession(
    id: map['id'] as String,
    profileId: (map['profile_id'] as String?) ?? 'default',
    scope: ChatScope.fromName(map['scope'] as String?),
    bookId: map['book_id'] as String?,
    title: map['title'] as String?,
    createdAt: (map['created_at'] as int?) ?? 0,
    updatedAt: (map['updated_at'] as int?) ?? 0,
  );
}
