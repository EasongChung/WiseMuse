import 'package:sqflite/sqflite.dart';

import '../models/book.dart';
import '../models/knowledge_point.dart';
import 'book_dao.dart';
import 'knowledge_point_dao.dart';

/// [v0.1.55] 幼小衔接基础知识库种子数据（拼音、英文字母、基础汉字）。
class SeedData {
  SeedData._();

  static const String builtinBookId = 'builtin_kindergarten_bridge';
  static const String builtinBookTitle = '幼小衔接基础知识';

  /// 只补写内置书籍记录，不改动知识点。
  ///
  /// 用于修复 v0.1.55 已写入 113 条知识点、但缺少 books 行的升级用户。
  static Future<void> repairBuiltinBook(Database db) async {
    final pointCount =
        Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM knowledge_points WHERE book_id = ?',
            [builtinBookId],
          ),
        ) ??
        0;
    if (pointCount == 0) return;
    final bookDao = BookDao(db);
    if (await bookDao.getById(builtinBookId) != null) return;
    final now = DateTime.now().microsecondsSinceEpoch;
    await bookDao.insert(
      Book(
        id: builtinBookId,
        title: builtinBookTitle,
        source: BookSource.txt,
        pageCount: 5,
        importStatus: 0,
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  /// 插入内置种子数据。
  static Future<void> populate(Database db) async {
    final dao = KnowledgePointDao(db);

    // 确保 books 表有内置书籍记录（ID 必须固定，不能由 Book.create 随机生成）
    final now = DateTime.now().microsecondsSinceEpoch;
    final bookDao = BookDao(db);
    final existing = await bookDao.getById(builtinBookId);
    if (existing == null) {
      await bookDao.insert(
        Book(
          id: builtinBookId,
          title: builtinBookTitle,
          source: BookSource.txt,
          pageCount: 5,
          importStatus: 0,
          createdAt: now,
          updatedAt: now,
        ),
      );
    }

    // 1. 声母表（23个）
    const initials = [
      ('b', '双唇不送气清塞音', '玻 泼 摸 佛 / 广播 b b b'),
      ('p', '双唇送气清塞音', '泼水 p p p'),
      ('m', '双唇鼻音', '摸摸 m m m'),
      ('f', '唇齿清擦音', '大佛 f f f'),
      ('d', '舌尖中不送气清塞音', '马蹄 d d d'),
      ('t', '舌尖中送气清塞音', '伞柄 t t t'),
      ('n', '舌尖中鼻音', '门洞 n n n'),
      ('l', '舌尖中边音', '小棍 l l l'),
      ('g', '舌根不送气清塞音', '白鸽 g g g'),
      ('k', '舌根送气清塞音', '蝌蚪 k k k'),
      ('h', '舌根清擦音', '荷花 h h h'),
      ('j', '舌面前不送气清塞擦音', '母鸡 j j j'),
      ('q', '舌面前送气清塞擦音', '气球 q q q'),
      ('x', '舌面前清擦音', '西瓜 x x x'),
      ('zh', '舌尖后不送气清塞擦音（翘舌音）', '织毛衣 zh zh zh'),
      ('ch', '舌尖后送气清塞擦音（翘舌音）', '吃苹果 ch ch ch'),
      ('sh', '舌尖后清擦音（翘舌音）', '狮子 sh sh sh'),
      ('r', '舌尖后浊擦音（翘舌音）', '日出 r r r'),
      ('z', '舌尖前不送气清塞擦音（平舌音）', '写字 z z z'),
      ('c', '舌尖前送气清塞擦音（平舌音）', '刺猬 c c c'),
      ('s', '舌尖前清擦音（平舌音）', '蚕丝 s s s'),
      ('y', '大 y（半元音）', '衣服 y y y'),
      ('w', '大 w（半元音）', '乌鸦 w w w'),
    ];

    for (final (text, def, extra) in initials) {
      await dao.upsertByText(
        builtinBookId,
        KnowledgeType.word,
        text,
        chapter: 1, // 第 1 单元：声母
        page: 1,
        definition: def,
        extra: extra,
        source: 'manual',
      );
    }

    // 2. 韵母表（单韵母6个 + 复韵母9个 + 鼻韵母9个）
    const finals = [
      // 单韵母
      ('a', '单韵母，嘴张大', '圆圆脸蛋扎小辫 a a a'),
      ('o', '单韵母，嘴拢圆', '公鸡打鸣 o o o'),
      ('e', '单韵母，嘴角向两边咧', '白鹅戏水 e e e'),
      ('i', '单韵母，牙齿对齐', '一件衣服 i i i'),
      ('u', '单韵母，嘴巴突出', '一只乌鸦 u u u'),
      ('ü', '单韵母，嘴巴吹笛', '小鱼吐泡 ü ü ü'),
      // 复韵母
      ('ai', '复韵母 a-i', '姐姐高，弟弟矮 ai ai ai'),
      ('ei', '复韵母 e-i', '干活使劲 ei ei ei'),
      ('ui', '复韵母 u-i', '围巾围上 ui ui ui'),
      ('ao', '复韵母 a-o', '穿棉袄 ao ao ao'),
      ('ou', '复韵母 o-u', '海鸥飞翔 ou ou ou'),
      ('iu', '复韵母 i-u', '邮筒邮票 iu iu iu'),
      ('ie', '复韵母 i-e', '椰树叶子 ie ie ie'),
      ('üe', '复韵母 ü-e', '月亮弯弯 üe üe üe'),
      ('er', '特殊韵母', '一只耳朵 er er er'),
      // 前鼻韵母
      ('an', '前鼻韵母', '天安门 an an an'),
      ('en', '前鼻韵母', '按门铃 en en en'),
      ('in', '前鼻韵母', '树荫下 in in in'),
      ('un', '前鼻韵母', '温水杯 un un un'),
      ('ün', '前鼻韵母', '白云飘 ün ün ün'),
      // 后鼻韵母
      ('ang', '后鼻韵母', '小山羊 ang ang ang'),
      ('eng', '后鼻韵母', '台灯亮 eng eng eng'),
      ('ing', '后鼻韵母', '老鹰飞 ing ing ing'),
      ('ong', '后鼻韵母', '小闹钟 ong ong ong'),
    ];

    for (final (text, def, extra) in finals) {
      await dao.upsertByText(
        builtinBookId,
        KnowledgeType.word,
        text,
        chapter: 2, // 第 2 单元：韵母
        page: 2,
        definition: def,
        extra: extra,
        source: 'manual',
      );
    }

    // 3. 整体认读音节（16个）
    const wholeSyllables = [
      ('zhi', '整体认读音节，不用拼，直接读', 'zh 的整体认读'),
      ('chi', '整体认读音节，不用拼，直接读', 'ch 的整体认读'),
      ('shi', '整体认读音节，不用拼，直接读', 'sh 的整体认读'),
      ('ri', '整体认读音节，不用拼，直接读', 'r 的整体认读'),
      ('zi', '整体认读音节，不用拼，直接读', 'z 的整体认读'),
      ('ci', '整体认读音节，不用拼，直接读', 'c 的整体认读'),
      ('si', '整体认读音节，不用拼，直接读', 's 的整体认读'),
      ('yi', '整体认读音节，不用拼，直接读', 'i 的整体认读'),
      ('wu', '整体认读音节，不用拼，直接读', 'u 的整体认读'),
      ('yu', '整体认读音节，不用拼，直接读', 'ü 的整体认读（小鱼脱帽）'),
      ('ye', '整体认读音节，不用拼，直接读', 'ie 的整体认读'),
      ('yue', '整体认读音节，不用拼，直接读', 'üe 的整体认读'),
      ('yuan', '整体认读音节，不用拼，直接读', 'üan 的整体认读'),
      ('yin', '整体认读音节，不用拼，直接读', 'in 的整体认读'),
      ('yun', '整体认读音节，不用拼，直接读', 'ün 的整体认读'),
      ('ying', '整体认读音节，不用拼，直接读', 'ing 的整体认读'),
    ];

    for (final (text, def, extra) in wholeSyllables) {
      await dao.upsertByText(
        builtinBookId,
        KnowledgeType.word,
        text,
        chapter: 3, // 第 3 单元：整体认读
        page: 3,
        definition: def,
        extra: extra,
        source: 'manual',
      );
    }

    // 4. 英文字母（26个字母与启蒙词）
    const alphabet = [
      ('Aa', '英文字母 /eɪ/', 'apple 苹果, ant 蚂蚁'),
      ('Bb', '英文字母 /biː/', 'book 书本, ball 球'),
      ('Cc', '英文字母 /siː/', 'cat 猫咪, car 小汽车'),
      ('Dd', '英文字母 /diː/', 'dog 小狗, duck 鸭子'),
      ('Ee', '英文字母 /iː/', 'egg 鸡蛋, elephant 大象'),
      ('Ff', '英文字母 /ef/', 'fish 鱼, fish 狐狸'),
      ('Gg', '英文字母 /dʒiː/', 'girl 女孩, green 绿色'),
      ('Hh', '英文字母 /eɪtʃ/', 'hat 帽子, hand 手'),
      ('Ii', '英文字母 /aɪ/', 'ice 冰块, ink 墨水'),
      ('Jj', '英文字母 /dʒeɪ/', 'juice 果汁, jump 跳跃'),
      ('Kk', '英文字母 /keɪ/', 'kite 风筝, king 国王'),
      ('Ll', '英文字母 /el/', 'lion 狮子, leg 腿'),
      ('Mm', '英文字母 /em/', 'monkey 猴子, moon 月亮'),
      ('Nn', '英文字母 /en/', 'nose 鼻子, nut 坚果'),
      ('Oo', '英文字母 /əʊ/', 'orange 橙子, orange 猫头鹰'),
      ('Pp', '英文字母 /piː/', 'panda 熊猫, pen 钢笔'),
      ('Qq', '英文字母 /kjuː/', 'queen 女王, quiet 安静'),
      ('Rr', '英文字母 /ɑːr/', 'rabbit 兔子, red 红色'),
      ('Ss', '英文字母 /es/', 'sun 太阳, star 星星'),
      ('Tt', '英文字母 /tiː/', 'tiger 老虎, tree 树'),
      ('Uu', '英文字母 /juː/', 'umbrella 雨伞, up 向上'),
      ('Vv', '英文字母 /viː/', 'van 面包车, vase 花瓶'),
      ('Ww', '英文字母 /ˈdʌbljuː/', 'water 水, window 窗户'),
      ('Xx', '英文字母 /eks/', 'fox 狐狸, box 盒子'),
      ('Yy', '英文字母 /waɪ/', 'yellow 黄色, yo-yo 溜溜球'),
      ('Zz', '英文字母 /zed/', 'zebra 斑马, zoo 动物园'),
    ];

    for (final (text, def, extra) in alphabet) {
      await dao.upsertByText(
        builtinBookId,
        KnowledgeType.english,
        text,
        chapter: 4, // 第 4 单元：英语字母
        page: 4,
        definition: def,
        extra: extra,
        source: 'manual',
      );
    }

    // 5. 基础入门汉字（识字一、二）
    const basicChars = [
      ('一', '数词，最小的正整数', 'yī / 笔画：1（横）'),
      ('二', '数词，一加一', 'èr / 笔画：2（横横）'),
      ('三', '数词，二加一', 'sān / 笔画：3（横横横）'),
      ('四', '数词，三加一', 'sì / 笔画：5'),
      ('五', '数词，四加一', 'wǔ / 笔画：4'),
      ('六', '数词，五加一', 'liù / 笔画：4'),
      ('七', '数词，六加一', 'qī / 笔画：2'),
      ('八', '数词，七加一', 'bā / 笔画：2'),
      ('九', '数词，八加一', 'jiǔ / 笔画：2'),
      ('十', '数词，九加一', 'shí / 笔画：2'),
      ('天', '地面以上的高空', 'tiān / 蓝天、晴天'),
      ('地', '人类生长居住的地面', 'dì / 大地、草地'),
      ('人', '能制造工具并使用工具的高等动物', 'rén / 大人、人们'),
      ('你', '对方，第二人称代词', 'nǐ / 你好、你们'),
      ('我', '自己，第一人称代词', 'wǒ / 我们、我的'),
      ('他', '第三人称代词', 'tā / 他们、他的'),
      ('日', '太阳，白天', 'rì / 日出、生日'),
      ('月', '月亮，月份', 'yuè / 月光、月亮'),
      ('水', '无色无味的透明液体', 'shuǐ / 喝水、河水'),
      ('火', '物体燃烧时发出的光和热', 'huǒ / 火苗、大火'),
      ('山', '地面上高起的部分', 'shān / 高山、大山'),
      ('石', '构成地壳的矿物集合体', 'shí / 石头、小石子'),
      ('田', '种植农作物的土地', 'tián / 农田、水田'),
      ('禾', '禾苗，泛指谷类庄稼', 'hé / 禾苗、庄稼'),
    ];

    for (final (text, def, extra) in basicChars) {
      await dao.upsertByText(
        builtinBookId,
        KnowledgeType.word,
        text,
        chapter: 5, // 第 5 单元：基础识字
        page: 5,
        definition: def,
        extra: extra,
        source: 'manual',
      );
    }
  }
}
