import 'package:sqflite/sqflite.dart';

import '../models/chat_message.dart';

/// [v0.1.48] AI 会话记录访问。
class ChatDao {
  ChatDao(this.db, {this.profileId});

  final Database db;
  final String? profileId;

  static const _table = 'chat_messages';

  /// 插入消息
  Future<String> insert(ChatMessage message) async {
    final map = message.toMap();
    if (profileId != null) map['profile_id'] = profileId;
    await db.insert(_table, map, conflictAlgorithm: ConflictAlgorithm.replace);
    return message.id;
  }

  /// 获取历史消息（按时间正序）
  Future<List<ChatMessage>> getMessages({
    String? bookId,
    int limit = 100,
  }) async {
    final whereClauses = <String>[];
    final whereArgs = <dynamic>[];

    if (profileId != null) {
      whereClauses.add('profile_id = ?');
      whereArgs.add(profileId);
    }
    if (bookId != null) {
      whereClauses.add('book_id = ?');
      whereArgs.add(bookId);
    }

    final where = whereClauses.isNotEmpty ? whereClauses.join(' AND ') : null;

    final rows = await db.query(
      _table,
      where: where,
      whereArgs: whereArgs.isNotEmpty ? whereArgs : null,
      orderBy: 'created_at ASC',
      limit: limit,
    );
    return rows.map(ChatMessage.fromMap).toList();
  }

  /// 清空当前会话历史
  Future<int> clearMessages({String? bookId}) async {
    final whereClauses = <String>[];
    final whereArgs = <dynamic>[];

    if (profileId != null) {
      whereClauses.add('profile_id = ?');
      whereArgs.add(profileId);
    }
    if (bookId != null) {
      whereClauses.add('book_id = ?');
      whereArgs.add(bookId);
    }

    final where = whereClauses.isNotEmpty ? whereClauses.join(' AND ') : null;
    return db.delete(
      _table,
      where: where,
      whereArgs: whereArgs.isNotEmpty ? whereArgs : null,
    );
  }
}
