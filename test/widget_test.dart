import 'package:flutter_test/flutter_test.dart';

import 'package:wisemuse/main.dart';

void main() {
  testWidgets('app 渲染 Vosk PoC 验证页', (WidgetTester tester) async {
    await tester.pumpWidget(const WiseMuseApp());

    // 验证页标题与初始状态
    expect(find.text('Vosk 离线识别 PoC'), findsOneWidget);
    expect(find.text('未初始化'), findsOneWidget);
    expect(find.text('导入模型文件'), findsOneWidget);
    expect(find.text('尝试在线下载'), findsOneWidget);
  });
}
