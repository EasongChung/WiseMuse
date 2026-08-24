import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wisemuse/core/models/knowledge_point.dart';
import 'package:wisemuse/core/storage/database.dart';
import 'package:wisemuse/core/storage/knowledge_point_dao.dart';
import 'package:wisemuse/core/storage/word_entry_dao.dart';
import 'package:wisemuse/core/models/word_entry.dart';
import 'package:wisemuse/services/ai_service.dart';
import 'package:wisemuse/services/ai_tutor_service.dart';
import 'package:wisemuse/services/openai_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'api_base_url': 'https://api.example.com/v1',
      'api_key': 'sk-test',
      'api_model': 'gpt-4o-mini',
    });
  });

  group('AiTutorService', () {
    test('explainStructured 解析多维启发式讲解 JSON', () async {
      final mockHttp = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': jsonEncode({
                    'meaning': '指春天温暖美好的风光。',
                    'example': '春风拂面，小鸟在树枝上欢快地唱歌。',
                    'question': '你在春天最喜欢做的事情是什么呢？',
                  }),
                },
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final ai = AiService(client: OpenAiClient(httpClient: mockHttp));
      final tutor = AiTutorService(ai: ai);

      final exp = await tutor.explainStructured('春风');
      expect(exp, isNotNull);
      expect(exp!.meaning, contains('温暖美好'));
      expect(exp.example, contains('小鸟'));
      expect(exp.question, contains('春天'));
      expect(exp.toMarkdown(), contains('### 📖 词句释义'));
    });

    test('generateSimilarChallenge 生成变式选择题', () async {
      final mockHttp = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': jsonEncode({
                    'question': '下列句子中，哪个词使用最恰当？',
                    'options': ['春风拂面', '大雪纷飞', '秋高气爽', '骄阳似火'],
                    'correct_answer': '春风拂面',
                    'explanation': '描写春天暖风用春风拂面最合适。',
                  }),
                },
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final ai = AiService(client: OpenAiClient(httpClient: mockHttp));
      final tutor = AiTutorService(ai: ai);

      final challenge = await tutor.generateSimilarChallenge('春风');
      expect(challenge, isNotNull);
      expect(challenge!.question, contains('哪个词使用最恰当'));
      expect(challenge.options, hasLength(4));
      expect(challenge.correctAnswer, '春风拂面');
      expect(challenge.explanation, contains('描写春天'));
    });

    test('getRecommendation 结合知识库与错词本未掌握内容', () async {
      final mockHttp = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': '晨曦\n繁衍\n春天'},
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final ai = AiService(client: OpenAiClient(httpClient: mockHttp));
      final tutor = AiTutorService(ai: ai);
      final db = await DatabaseProvider.openTest();
      try {
        final kpDao = KnowledgePointDao(db);
        final wordDao = WordEntryDao(db);

        await kpDao.insert(
          KnowledgePoint.create(
            bookId: 'b1',
            type: KnowledgeType.word,
            text: '晨曦',
            definition: '早晨的阳光',
          ),
        );

        await wordDao.upsert(WordEntry.create(word: '繁衍', lang: 'zh'));

        final recs = await tutor.getRecommendation(count: 5);

        expect(recs, contains('晨曦'));
        expect(recs, contains('繁衍'));
      } finally {
        await db.close();
      }
    });
  });
}
