import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wisemuse/core/models/chat_message.dart';
import 'package:wisemuse/core/models/chat_session.dart';
import 'package:wisemuse/core/storage/database.dart';
import 'package:wisemuse/core/storage/chat_dao.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('会话按 scope、bookId 和 profile 隔离', () async {
    final db = await DatabaseProvider.openTest();
    try {
      final normal = ChatSession.create(
        profileId: 'child-a',
        scope: ChatScope.normal,
      );
      final book = ChatSession.create(
        profileId: 'child-a',
        scope: ChatScope.book,
        bookId: 'book-a',
      );
      final otherProfile = ChatSession.create(
        profileId: 'child-b',
        scope: ChatScope.normal,
      );
      await ChatDao(db, profileId: 'child-a').insertSession(normal);
      await ChatDao(db, profileId: 'child-a').insertSession(book);
      await ChatDao(db, profileId: 'child-b').insertSession(otherProfile);

      final daoA = ChatDao(db, profileId: 'child-a');
      await daoA.insert(
        ChatMessage.create(
          sessionId: normal.id,
          profileId: 'child-a',
          scope: ChatScope.normal,
          role: 'user',
          content: '普通问题',
        ),
      );
      await daoA.insert(
        ChatMessage.create(
          sessionId: book.id,
          profileId: 'child-a',
          scope: ChatScope.book,
          role: 'user',
          content: '书籍问题',
          bookId: 'book-a',
        ),
      );
      await ChatDao(db, profileId: 'child-b').insert(
        ChatMessage.create(
          sessionId: otherProfile.id,
          profileId: 'child-b',
          role: 'user',
          content: '另一个孩子的问题',
        ),
      );

      expect(
        (await daoA.getSessions(
          scope: ChatScope.normal,
          bookId: null,
        )).map((s) => s.id),
        [normal.id],
      );
      expect(
        (await daoA.getSessions(
          scope: ChatScope.book,
          bookId: 'book-a',
        )).map((s) => s.id),
        [book.id],
      );
      expect(
        await daoA.getSessions(scope: ChatScope.normal, bookId: 'book-a'),
        isEmpty,
      );
      expect(
        (await daoA.getMessages(sessionId: normal.id)).single.content,
        '普通问题',
      );
      expect(
        (await ChatDao(
          db,
          profileId: 'child-b',
        ).getMessages(sessionId: normal.id)),
        isEmpty,
      );
    } finally {
      await db.close();
    }
  });

  test('删除指定 profile 的会话不影响其他 profile', () async {
    final db = await DatabaseProvider.openTest();
    try {
      final a = ChatSession.create(profileId: 'a', scope: ChatScope.normal);
      final b = ChatSession.create(profileId: 'b', scope: ChatScope.normal);
      await ChatDao(db, profileId: 'a').insertSession(a);
      await ChatDao(db, profileId: 'b').insertSession(b);
      await ChatDao(
        db,
        profileId: 'a',
      ).deleteSessions(scope: ChatScope.normal, bookId: null);
      expect(
        await ChatDao(
          db,
          profileId: 'a',
        ).getSessions(scope: ChatScope.normal, bookId: null),
        isEmpty,
      );
      expect(
        await ChatDao(
          db,
          profileId: 'b',
        ).getSessions(scope: ChatScope.normal, bookId: null),
        hasLength(1),
      );
    } finally {
      await db.close();
    }
  });
}
