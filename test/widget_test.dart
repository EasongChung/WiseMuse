import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:wisemuse/main.dart';

void main() {
  setUpAll(() {
    // 桌面/测试环境用 FFI 库替代 Android sqflite（HomePage 初始化会开库）
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('app 渲染书架首页', (WidgetTester tester) async {
    await tester.pumpWidget(const WiseMuseApp());
    // 仅 pump 一帧：数据库打开是真实异步，测试环境不必等到完成
    await tester.pump();

    // 首页为书架（AppBar 标题即时渲染，不依赖异步加载）
    expect(find.text('我的书架'), findsOneWidget);
    expect(find.text('导入'), findsWidgets); // FAB 文案
  });
}
