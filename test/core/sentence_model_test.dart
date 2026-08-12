import 'package:flutter_test/flutter_test.dart';
import 'package:wisemuse/core/models/sentence.dart';

void main() {
  test('create 生成唯一 id 与默认字段', () {
    final a = Sentence.create(
      bookId: 'b1',
      page: 0,
      chapter: 0,
      index: 0,
      text: '今天天气真好。',
    );
    final b = Sentence.create(
      bookId: 'b1',
      page: 0,
      chapter: 0,
      index: 1,
      text: '我们一起去公园。',
    );
    expect(a.id, isNot(b.id));
    expect(a.id, startsWith('sent_'));
    expect(a.bookId, 'b1');
    expect(a.page, 0);
    expect(a.index, 0);
    expect(a.geometry, isNull);
  });

  test('toMap/fromMap round-trip（含 geometry）', () {
    final s = Sentence.create(
      bookId: 'b1',
      page: 2,
      chapter: 1,
      index: 3,
      text: '小猫在草地上玩耍。',
      geometry: '{"rects":[[0.1,0.2,0.5,0.3]]}',
    );
    final restored = Sentence.fromMap(s.toMap());
    expect(restored.id, s.id);
    expect(restored.bookId, 'b1');
    expect(restored.page, 2);
    expect(restored.chapter, 1);
    expect(restored.index, 3);
    expect(restored.text, '小猫在草地上玩耍。');
    expect(restored.geometry, '{"rects":[[0.1,0.2,0.5,0.3]]}');
  });

  test('fromMap 缺失字段有默认值', () {
    final s = Sentence.fromMap({'id': 'x', 'book_id': 'b', 'text': 't'});
    expect(s.page, 0);
    expect(s.chapter, 0);
    expect(s.index, 0);
    expect(s.geometry, isNull);
  });
}
