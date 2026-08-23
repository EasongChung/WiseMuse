import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wisemuse/features/follow/follow_page.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('FollowPage and FollowItem', () {
    test('FollowItem 构造与拼音生成', () {
      final item = FollowItem(
        text: '静夜思',
        pinyin: 'jìng yè sī',
        sourceTitle: '古诗',
      );
      expect(item.text, '静夜思');
      expect(item.pinyin, 'jìng yè sī');
      expect(item.sourceTitle, '古诗');
    });

    testWidgets('FollowPage 列表渲染与题号进度展示', (tester) async {
      const sentences = ['床前明月光', '疑是地上霜', '举头望明月', '低头思故乡'];

      await tester.pumpWidget(
        const MaterialApp(home: FollowPage(sentences: sentences, title: '静夜思')),
      );
      await tester.pumpAndSettle();

      expect(find.text('静夜思'), findsOneWidget);
      expect(find.text('第 1 / 4 句'), findsOneWidget);
      expect(find.text('床前明月光'), findsOneWidget);
      expect(find.text('标准范读'), findsOneWidget);
      expect(find.text('慢速领读'), findsOneWidget);
      expect(find.text('下一句'), findsOneWidget);

      // 点击下一句
      await tester.tap(find.text('下一句'));
      await tester.pumpAndSettle();

      expect(find.text('第 2 / 4 句'), findsOneWidget);
      expect(find.text('疑是地上霜'), findsOneWidget);
      expect(find.text('上一句'), findsOneWidget);

      // 点击上一句
      await tester.tap(find.text('上一句'));
      await tester.pumpAndSettle();

      expect(find.text('第 1 / 4 句'), findsOneWidget);
      expect(find.text('床前明月光'), findsOneWidget);
    });

    testWidgets('FollowPage 句子清单 BottomSheet 展开与跳转', (tester) async {
      const sentences = ['春眠不觉晓', '处处闻啼鸟', '夜来风雨声', '花落知多少'];

      await tester.pumpWidget(
        const MaterialApp(home: FollowPage(sentences: sentences, title: '春晓')),
      );
      await tester.pumpAndSettle();

      // 点击清单图标
      final listIcon = find.byIcon(Icons.format_list_bulleted);
      expect(listIcon, findsOneWidget);
      await tester.tap(listIcon);
      await tester.pumpAndSettle();

      expect(find.text('跟读清单 (4 句)'), findsOneWidget);
      expect(find.text('花落知多少'), findsOneWidget);

      // 点击第 4 句
      await tester.tap(find.text('花落知多少'));
      await tester.pumpAndSettle();

      expect(find.text('第 4 / 4 句'), findsOneWidget);
      expect(find.text('花落知多少'), findsOneWidget);
    });
  });
}
