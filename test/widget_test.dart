import 'package:flutter_test/flutter_test.dart';

import 'package:wisemuse/main.dart';

void main() {
  testWidgets('app 渲染跟读练习页', (WidgetTester tester) async {
    await tester.pumpWidget(const WiseMuseApp());

    // 首页为跟读练习
    expect(find.text('跟读练习'), findsOneWidget);
    expect(find.text('未初始化'), findsOneWidget);
    expect(find.text('导入模型文件'), findsOneWidget);
    expect(find.text('尝试在线下载'), findsOneWidget);
    // 播放/跟读按钮存在
    expect(find.text('播放'), findsOneWidget);
    expect(find.text('跟读'), findsOneWidget);
  });
}
