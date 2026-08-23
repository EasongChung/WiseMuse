import 'package:sqflite/sqflite.dart';

import '../models/chat_message.dart';
import '../models/chat_session.dart';

/// [v0.1.60] AI 会话与消息数据访问。
class ChatDao {
  ChatDao(this.db, {this.profileId = 'default'});

  final Database db;
  final String? profileId;

  static const _messageTable = 'chat_messages';
  static const _sessionTable = 'chat_sessions';

  Future<String> insertSession(ChatSession session) async {
    final map = session.toMap();
    if (profileId != null) map['profile_id'] = profileId;
    await db.insert(
      _sessionTable,
      map,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return session.id;
  }

  Future<List<ChatSession>> getSessions({
    required ChatScope scope,
    String? bookId,
    int limit = 50,
  }) async {
    final where = <String>['scope = ?'];
    final args = <dynamic>[scope.name];
    if (profileId != null) {
      where.add('profile_id = ?');
      args.add(profileId);
    }
    if (bookId == null) {
      where.add('book_id IS NULL');
    } else {
      where.add('book_id = ?');
      args.add(bookId);
    }
    final rows = await db.query(
      _sessionTable,
      where: where.join(' AND '),
      whereArgs: args,
      orderBy: 'updated_at DESC',
      limit: limit,
    );
    return rows.map(ChatSession.fromMap).toList();
  }

  Future<ChatSession?> getSession(String id) async {
    final where = <String>['id = ?'];
    final args = <dynamic>[id];
    if (profileId != null) {
      where.add('profile_id = ?');
      args.add(profileId);
    }
    final rows = await db.query(
      _sessionTable,
      where: where.join(' AND '),
      whereArgs: args,
      limit: 1,
    );
    return rows.isEmpty ? null : ChatSession.fromMap(rows.first);
  }

  Future<String> insert(ChatMessage message) async {
    final map = message.toMap();
    if (profileId != null) map['profile_id'] = profileId;
    await db.insert(
      _messageTable,
      map,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    if (message.sessionId != null) {
      await db.rawUpdate(
        '''
        UPDATE $_sessionTable
        SET updated_at = ?,
            title = CASE
              WHEN ? = 'user' AND (title IS NULL OR title = '') THEN ?
              ELSE title
            END
        WHERE id = ?
        ''',
        [
          message.createdAt,
          message.role,
          _sessionTitle(message.content),
          message.sessionId,
        ],
      );
    }
    return message.id;
  }

  /// 获取指定会话历史；bookId 为 null 时严格使用 IS NULL。
  Future<List<ChatMessage>> getMessages({
    required String sessionId,
    int limit = 100,
  }) async {
    final where = <String>['session_id = ?'];
    final args = <dynamic>[sessionId];
    if (profileId != null) {
      where.add('profile_id = ?');
      args.add(profileId);
    }
    final rows = await db.query(
      _messageTable,
      where: where.join(' AND '),
      whereArgs: args,
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.reversed.map(ChatMessage.fromMap).toList();
  }

  Future<int> clearSession(String sessionId) async {
    final where = <String>['session_id = ?'];
    final args = <dynamic>[sessionId];
    if (profileId != null) {
      where.add('profile_id = ?');
      args.add(profileId);
    }
    return db.delete(
      _messageTable,
      where: where.join(' AND '),
      whereArgs: args,
    );
  }

  Future<int> deleteSession(String sessionId) async {
    await clearSession(sessionId);
    final where = <String>['id = ?'];
    final args = <dynamic>[sessionId];
    if (profileId != null) {
      where.add('profile_id = ?');
      args.add(profileId);
    }
    return db.delete(
      _sessionTable,
      where: where.join(' AND '),
      whereArgs: args,
    );
  }

  Future<int> deleteSessions({required ChatScope scope, String? bookId}) async {
    final sessions = await getSessions(
      scope: scope,
      bookId: bookId,
      limit: 1000000,
    );
    var deleted = 0;
    await db.transaction((txn) async {
      for (final session in sessions) {
        final messageWhere = <String>['session_id = ?'];
        final messageArgs = <dynamic>[session.id];
        final sessionWhere = <String>['id = ?'];
        final sessionArgs = <dynamic>[session.id];
        if (profileId != null) {
          messageWhere.add('profile_id = ?');
          messageArgs.add(profileId);
          sessionWhere.add('profile_id = ?');
          sessionArgs.add(profileId);
        }
        await txn.delete(
          _messageTable,
          where: messageWhere.join(' AND '),
          whereArgs: messageArgs,
        );
        deleted += await txn.delete(
          _sessionTable,
          where: sessionWhere.join(' AND '),
          whereArgs: sessionArgs,
        );
      }
    });
    return deleted;
  }

  /// 旧 API 兼容：按范围读取最近一个 legacy 会话的消息。
  Future<List<ChatMessage>> getMessagesByScope({
    ChatScope scope = ChatScope.normal,
    String? bookId,
    int limit = 100,
  }) async {
    final sessions = await getSessions(scope: scope, bookId: bookId, limit: 1);
    if (sessions.isEmpty) return [];
    return getMessages(sessionId: sessions.first.id, limit: limit);
  }

  static String _sessionTitle(String content) {
    final compact = content.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (compact.length <= 28) return compact;
    return '${compact.substring(0, 28)}…';
  }
}
