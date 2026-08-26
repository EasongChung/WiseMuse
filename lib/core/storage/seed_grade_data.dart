import '../models/knowledge_point.dart';
import 'knowledge_point_dao.dart';

/// [v0.1.61] 小学一、二年级语数英核心知识点。
///
/// 内容按深圳小学常见教材版本的公共知识范围整理，不复制整册教材正文。
class GradeSeedData {
  GradeSeedData._();

  static const _bookId = 'builtin_kindergarten_bridge';

  static Future<void> populate(KnowledgePointDao dao) async {
    await _insert(dao, 101, KnowledgeType.word, const [
      ('春', '春季，一年四季之一', '春天、春风'),
      ('夏', '夏季，一年四季之一', '夏天、夏日'),
      ('秋', '秋季，一年四季之一', '秋天、秋风'),
      ('冬', '冬季，一年四季之一', '冬天、冬雪'),
      ('花', '植物的繁殖器官', '花朵、红花'),
      ('鸟', '有羽毛和翅膀的动物', '小鸟、飞鸟'),
      ('虫', '昆虫等小动物的总称', '小虫、虫子'),
      ('云', '空中由水滴组成的物体', '白云、云朵'),
      ('雨', '从云中降落的水滴', '下雨、雨水'),
      ('风', '空气流动形成的现象', '大风、风雨'),
      ('上', '位置在高处或由低处到高处', '上面、上学'),
      ('下', '位置在低处或由高处到低处', '下面、下雨'),
      ('左', '面向前方时身体的左侧', '左边、左右'),
      ('右', '面向前方时身体的右侧', '右边、左右'),
      ('大', '面积、体积或程度超过一般', '大小、大人'),
      ('小', '面积、体积或程度较少', '大小、小心'),
      ('多', '数量较大', '多少、很多'),
      ('少', '数量较小', '多少、少数'),
      ('口', '人或动物进食和发声的器官', '人口、开口'),
      ('目', '眼睛，也指看', '目光、耳目'),
      ('耳', '听觉器官', '耳朵、耳边'),
      ('手', '人体上肢前端的五个指头', '小手、手心'),
      ('足', '脚，也表示充足', '手足、满足'),
      ('天', '天空；一天的时间', '今天、天空'),
      ('地', '地面；土地', '大地、地上'),
      ('人', '能制造和使用工具的动物', '大人、人民'),
      ('我', '第一人称代词', '我们、我的'),
      ('你', '第二人称代词', '你好、你们'),
      ('他', '第三人称代词', '他们、他的'),
    ]);
    await _insert(dao, 102, KnowledgeType.poem, const [
      ('咏鹅', '骆宾王；鹅，鹅，鹅，曲项向天歌。白毛浮绿水，红掌拨清波。', '一年级古诗积累'),
      ('江南', '汉乐府；江南可采莲，莲叶何田田。鱼戏莲叶间。', '一年级古诗积累'),
      ('画', '王维；远看山有色，近听水无声。春去花还在，人来鸟不惊。', '一年级古诗积累'),
      ('静夜思', '李白；床前明月光，疑是地上霜。举头望明月，低头思故乡。', '一年级古诗积累'),
      ('春晓', '孟浩然；春眠不觉晓，处处闻啼鸟。夜来风雨声，花落知多少。', '一年级古诗积累'),
    ]);
    await _insert(dao, 104, KnowledgeType.word, const [
      ('10以内加减法', '掌握10以内数的组成、分解与加减计算', '3+4=7；9-5=4'),
      ('20以内进位加法', '凑十法：看大数、分小数、凑成十、加剩数', '9+4=9+1+3=13'),
      ('20以内退位减法', '破十法：十几减几，先减十再加补数', '13-8=10-8+3=5'),
      ('认识人民币', '认识元、角、分及换算关系', '1元=10角，1角=10分'),
      ('认识钟表', '认识整时和半时，分针指向12为整时', '7时、7时半'),
      ('位置与顺序', '认识上、下、前、后、左、右', '小明在小红的左边'),
      ('图形认识', '认识长方形、正方形、三角形和圆', '生活中的物体有不同形状'),
    ]);
    await _insert(dao, 106, KnowledgeType.english, const [
      ('hello', '问候语：你好', 'Hello!'),
      ('goodbye', '告别语：再见', 'Goodbye!'),
      ('please', '礼貌用语：请', 'Please.'),
      ('thank you', '感谢用语：谢谢你', 'Thank you.'),
      ('teacher', '老师', 'This is my teacher.'),
      ('friend', '朋友', 'This is my friend.'),
      ('father', '爸爸', 'This is my father.'),
      ('mother', '妈妈', 'This is my mother.'),
      ('red', '红色', 'It is red.'),
      ('yellow', '黄色', 'It is yellow.'),
      ('blue', '蓝色', 'It is blue.'),
      ('green', '绿色', 'It is green.'),
      ('one', '一', 'One, two, three.'),
      ('two', '二', 'One, two, three.'),
      ('three', '三', 'One, two, three.'),
      ('book', '书', 'Open your book.'),
      ('pencil', '铅笔', 'This is a pencil.'),
      ('cat', '猫', 'I see a cat.'),
      ('dog', '狗', 'I like dogs.'),
      ('school', '学校', 'I go to school.'),
    ]);

    await _insert(dao, 201, KnowledgeType.word, const [
      ('宽', '横向距离大；不狭窄', '宽广、宽度'),
      ('顶', '最高处；用头支撑', '山顶、头顶'),
      ('肚', '腹部', '肚子、肚皮'),
      ('孩', '儿童', '孩子、小孩'),
      ('跳', '两脚离地向上或向前', '跳高、跳远'),
      ('变', '性质或状态发生变化', '变化、变成'),
      ('傍晚', '临近晚上的时候', '太阳傍晚落山'),
      ('海洋', '地球上广大的咸水水域', '海洋生物'),
      ('桥', '架在水面或空中便于通行的建筑', '大桥、木桥'),
      ('队伍', '有组织的行列', '排队、队伍'),
      ('杨树', '一种落叶乔木', '白杨、杨树'),
      ('枫树', '秋季叶子变红的树', '枫叶、枫树'),
      ('松柏', '松树和柏树，常青树', '松柏长青'),
      ('朋友', '彼此有交情的人', '好朋友、交朋友'),
      ('深', '从上到下或从外到里的距离大', '深浅、深处'),
      ('美丽', '好看、漂亮', '美丽的校园'),
      ('中心', '事物的主要部分或中央位置', '中心、中央'),
      ('展现', '清楚地表现出来', '展现风采'),
    ]);
    await _insert(dao, 202, KnowledgeType.idiom, const [
      ('名山大川', '著名的高山和大河', '祖国有许多名山大川。'),
      ('山清水秀', '山水清幽秀丽', '这里山清水秀。'),
      ('五光十色', '形容色彩鲜艳、花样繁多', '商品五光十色。'),
      ('风调雨顺', '风雨及时适宜，形容年景好', '今年风调雨顺。'),
      ('欢歌笑语', '欢乐的歌声和笑声', '校园里充满欢歌笑语。'),
      ('春色满园', '园内到处都是春天美景', '春天来了，春色满园。'),
    ]);
    await _insert(dao, 203, KnowledgeType.poem, const [
      ('登鹳雀楼', '王之涣；白日依山尽，黄河入海流。欲穷千里目，更上一层楼。', '二年级古诗积累'),
      ('望庐山瀑布', '李白；日照香炉生紫烟，遥看瀑布挂前川。飞流直下三千尺，疑是银河落九天。', '二年级古诗积累'),
      ('草', '白居易；离离原上草，一岁一枯荣。野火烧不尽，春风吹又生。', '二年级古诗积累'),
      ('早发白帝城', '李白；朝辞白帝彩云间，千里江陵一日还。两岸猿声啼不住，轻舟已过万重山。', '二年级古诗积累'),
    ]);
    await _insert(dao, 204, KnowledgeType.word, const [
      ('乘法的意义', '求几个相同加数的和可以用乘法表示', '3+3+3+3=3×4=12'),
      ('九九乘法口诀', '熟练掌握一至九的乘法口诀', '三四十二，六九五十四'),
      ('除法的意义', '把总数平均分，每份同样多', '12÷3=4'),
      ('长度单位', '米和厘米是常用长度单位', '1米=100厘米'),
      ('角的初步认识', '角有一个顶点和两条边', '直角、锐角、钝角'),
      ('时间单位', '时和分是常用时间单位', '1时=60分'),
    ]);
    await _insert(dao, 206, KnowledgeType.english, const [
      ('eye', '眼睛', 'This is my eye.'),
      ('ear', '耳朵', 'This is my ear.'),
      ('nose', '鼻子', 'Touch your nose.'),
      ('mouth', '嘴巴', 'Open your mouth.'),
      ('hand', '手', 'Raise your hand.'),
      ('apple', '苹果', 'I like apples.'),
      ('banana', '香蕉', 'I like bananas.'),
      ('milk', '牛奶', 'I like milk.'),
      ('water', '水', 'Drink some water.'),
      ('cake', '蛋糕', 'This is a cake.'),
      ('shirt', '衬衫', 'This is my shirt.'),
      ('shoes', '鞋子', 'These are my shoes.'),
      ('home', '家', 'Welcome to my home.'),
      ('room', '房间', 'This is my room.'),
      ('sunny', '晴朗的', 'It is sunny today.'),
      ('rainy', '下雨的', 'It is rainy today.'),
      ('run', '跑步', 'I can run.'),
      ('jump', '跳', 'I can jump.'),
      ('sing', '唱歌', 'I can sing.'),
      ('draw', '画画', 'I can draw.'),
    ]);
  }

  static Future<void> _insert(
    KnowledgePointDao dao,
    int chapter,
    KnowledgeType type,
    List<(String, String, String)> rows,
  ) async {
    for (final (text, definition, extra) in rows) {
      // 与幼小衔接已有同名知识点时保留原章节归属，避免扩充数据把
      // 「日/月/水」等基础字从 chapter 5 移走。
      final existing = await dao.findByBookTypeText(_bookId, type, text);
      if (existing != null) continue;
      await dao.upsertByText(
        _bookId,
        type,
        text,
        chapter: chapter,
        page: chapter,
        definition: definition,
        extra: extra,
        source: 'manual',
      );
    }
  }
}
