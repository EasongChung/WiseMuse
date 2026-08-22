import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/debug/app_log.dart';
import '../../widgets/char_select_grid.dart';
import '../../widgets/knowledge_scope_picker.dart';
import '../../core/models/learning_record.dart';
import '../../core/storage/database.dart';
import '../../core/storage/knowledge_point_dao.dart';
import '../../core/storage/learning_record_dao.dart';
import '../../core/storage/word_entry_dao.dart';
import '../../core/theme/app_theme.dart';
import '../../services/dictation_engine.dart';
import '../../services/mastery_service.dart';
import '../../services/native_tts_service.dart';
import '../../services/tts_service.dart';
import 'sentence_dictation_page.dart';
import '../../widgets/top_toast.dart';

/// 一次答题记录（供完成后家长检查）。
class _AnswerRecord {
  _AnswerRecord({
    required this.word,
    required this.correct,
    this.selected,
  });

  final String word;
  final bool correct;
  final String? selected;
}

/// [v0.1.0] 听写页面：中文听音选字 / 朗读列表 两种模式。
///
/// 词源：生词本（优先未掌握词）或手动输入。
/// 结果记入 LearningRecord。
///
/// [v0.1.56] 儿童化改造：
/// - 选字模式：答后显示对错文字 + 颜色反馈，2.5 秒自动进入下一题
/// - 拼写模式改为「朗读列表」：全屏显示词语，自动朗读，3 秒自动切换
/// - 拼字积木直接作为听写一级目录选项
/// - 完成后展示答题记录供家长检查
class DictationPage extends StatefulWidget {
  const DictationPage({super.key});

  @override
  State<DictationPage> createState() => _DictationPageState();
}

class _DictationPageState extends State<DictationPage> {
  static const _tag = 'dictation';

  final TtsService _tts = NativeTtsService();

  // 题目状态
  List<DictationQuestion> _questions = const [];
  int _currentIndex = 0;
  int _correctCount = 0;

  // 答题记录（家长检查用）
  final List<_AnswerRecord> _records = [];

  // 选字模式已选
  String? _selectedOption;

  // 反馈状态
  bool _showResult = false;

  bool _loading = true;
  bool _started = false;
  bool _ttsPlaying = false;
  bool _submitting = false;

  // 自动倒计时
  Timer? _autoNextTimer;

  @override
  void initState() {
    super.initState();
    // [v0.1.55] 延迟到 mount 完成后弹出词源选择，避免刚构建时 context 异常
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showSourcePicker();
    });
  }

  @override
  void dispose() {
    _autoNextTimer?.cancel();
    super.dispose();
  }

  /// [v0.1.38] 选择词源：生词本 / 手动输入 / 知识库。
  Future<void> _showSourcePicker() async {
    final source = await showDialog<String>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('选择词源'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.book, color: StudyPalette.ember),
                  title: const Text('生词本'),
                  subtitle: const Text('优先未掌握词'),
                  onTap: () => Navigator.of(context).pop('wordbook'),
                ),
                ListTile(
                  leading: const Icon(Icons.edit, color: StudyPalette.spinePdf),
                  title: const Text('手动输入'),
                  subtitle: const Text('自行输入要听写的词'),
                  onTap: () => Navigator.of(context).pop('manual'),
                ),
                ListTile(
                  leading: const Icon(
                    Icons.auto_stories,
                    color: StudyPalette.spineWord,
                  ),
                  title: const Text('从知识库选择'),
                  subtitle: const Text('选书籍→单元→课，从中听写'),
                  onTap: () => Navigator.of(context).pop('knowledge'),
                ),
              ],
            ),
          ),
    );
    if (!mounted) return;
    switch (source) {
      case 'knowledge':
        await _loadFromKnowledge();
        break;
      case 'manual':
        await _loadManual();
        break;
      default:
        await _loadFromWordbook();
    }
  }

  Future<void> _loadFromKnowledge() async {
    final scope = await KnowledgeScopePicker.show(context);
    if (scope == null || !mounted) {
      // 取消选择范围，重新弹回词源选择器
      if (mounted) _showSourcePicker();
      return;
    }
    try {
      final db = await DatabaseProvider.database;
      final dao = KnowledgePointDao(db);
      final points = await dao.getByBook(scope.bookId);
      var filtered = points;
      if (scope.chapter != null && scope.chapter! > 0) {
        filtered = filtered.where((p) => p.chapter == scope.chapter).toList();
      }
      if (scope.page != null && scope.page! > 0) {
        filtered = filtered.where((p) => p.page == scope.page).toList();
      }
      final words =
          filtered.map((p) => p.text).where((t) => t.isNotEmpty).toList();
      if (words.isEmpty) {
        if (mounted) {
          TopToast.show(context, '该范围暂无知识点，请换个范围或词源');
          _showSourcePicker();
        }
        return;
      }
      _showModeAndStart(words);
    } catch (e) {
      AppLog.e(_tag, '从知识库加载失败: $e');
      if (mounted) {
        TopToast.show(context, '加载知识库失败，已切换至预设练习词');
        _showModeAndStart(const [
          '大',
          '小',
          '上',
          '下',
          '人',
          '山',
          '水',
          '火',
          '日',
          '月',
        ]);
      }
    }
  }

  Future<void> _loadManual() async {
    final input = await _showWordInputDialog();
    if (input == null || !mounted) {
      // 取消手动输入，重新弹回词源选择器
      if (mounted) _showSourcePicker();
      return;
    }
    final words =
        input.split(RegExp(r'[\s,，、]+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) {
      if (mounted) {
        TopToast.show(context, '未输入有效词语');
        _showSourcePicker();
      }
      return;
    }
    _showModeAndStart(words);
  }

  Future<void> _loadFromWordbook() async {
    try {
      final db = await DatabaseProvider.database;
      final entries = await WordEntryDao(db).getUnmastered(threshold: 3);
      final words = entries.map((e) => e.word).toList();
      if (!mounted) return;

      if (words.isEmpty) {
        TopToast.show(context, '生词本暂无未掌握生词，已为您准备基础汉字练习');
        _showModeAndStart(const [
          '天',
          '地',
          '人',
          '你',
          '我',
          '他',
          '日',
          '月',
          '水',
          '火',
          '山',
          '石',
          '田',
          '禾',
        ]);
        return;
      }
      _showModeAndStart(words);
    } catch (e) {
      AppLog.e(_tag, '加载生词本失败: $e');
      if (mounted) {
        _showModeAndStart(const ['大', '小', '上', '下', '人', '山', '水', '火']);
      }
    }
  }

  void _showModeAndStart(List<String> words) {
    if (!mounted) return;
    setState(() {
      _loading = false;
    });
    _start(words);
  }

  void _start(List<String> words) async {
    final modeStr = await _showModeDialog();
    if (modeStr == null || !mounted) {
      if (mounted) Navigator.of(context).pop();
      return;
    }

    // 句子默写（拼字积木）模式
    if (modeStr == 'sentence') {
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder:
                (_) => SentenceDictationPage(
                  sentences: words.where((w) => w.length >= 4).toList(),
                  bookId: null,
                ),
          ),
        );
      }
      return;
    }

    // 拼字积木（直接跳转，强制 wordJigsaw 模式）
    if (modeStr == 'wordJigsaw') {
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder:
                (_) => SentenceDictationPage(
                  sentences: words.where((w) => w.length >= 2).toList(),
                  bookId: null,
                ),
          ),
        );
      }
      return;
    }

    final mode = DictationMode.values.firstWhere((m) => m.name == modeStr);

    final questions = DictationEngine.makeQuestions(
      words,
      mode: mode,
      count: 10,
    );

    if (questions.isEmpty && mounted) {
      TopToast.show(context, '没有适合该模式的题目，请换个词源或模式');
      _showSourcePicker();
      return;
    }

    if (!mounted) return;
    setState(() {
      _questions = questions;
      _started = true;
      _loading = false;
    });

    // 自动播放第一个词
    _playCurrent();
  }

  Future<String?> _showModeDialog() async {
    return showDialog<String>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('选择听写模式'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ...DictationMode.values.map((mode) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      title: Text(
                        mode.label,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(_modeDesc(mode)),
                      leading: Icon(
                        mode == DictationMode.charSelect
                            ? Icons.text_fields
                            : Icons.volume_up,
                        color: StudyPalette.ember,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: const BorderSide(color: StudyPalette.linen),
                      ),
                      onTap: () => Navigator.of(context).pop(mode.name),
                    ),
                  );
                }),
                const Divider(height: 1),
                ListTile(
                  title: const Text(
                    '拼字积木',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: const Text('听句子 → 点击词语卡片按顺序排列'),
                  leading: const Icon(Icons.grid_view, color: StudyPalette.ember),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.all(Radius.circular(12)),
                    side: BorderSide(color: StudyPalette.linen),
                  ),
                  onTap: () => Navigator.of(context).pop('wordJigsaw'),
                ),
                ListTile(
                  title: const Text(
                    '句子默写',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: const Text('逐句拼字积木，适合较长句子'),
                  leading: const Icon(Icons.article, color: StudyPalette.ember),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.all(Radius.circular(12)),
                    side: BorderSide(color: StudyPalette.linen),
                  ),
                  onTap: () => Navigator.of(context).pop('sentence'),
                ),
              ],
            ),
          ),
    );
  }

  String _modeDesc(DictationMode mode) {
    switch (mode) {
      case DictationMode.charSelect:
        return '听发音 → 从 4 个字中选正确的';
      case DictationMode.spelling:
        return '听发音 → 看词语跟读记忆';
    }
  }

  Future<String?> _showWordInputDialog() async {
    final ctrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('输入要听写的词'),
            content: TextField(
              controller: ctrl,
              decoration: const InputDecoration(hintText: '用空格或逗号分隔多个词'),
              autofocus: true,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(ctrl.text.trim()),
                child: const Text('开始'),
              ),
            ],
          ),
    );
    ctrl.dispose();
    return result;
  }

  Future<void> _playCurrent() async {
    if (_currentIndex >= _questions.length) return;
    setState(() => _ttsPlaying = true);
    await _tts.stop();
    await _tts.speak(_questions[_currentIndex].word);
    if (mounted) setState(() => _ttsPlaying = false);
  }

  void _submitCharSelect(String option) {
    if (_submitting || _showResult) return;
    final q = _questions[_currentIndex];
    final correct = DictationEngine.checkCharSelect(q.word, option);

    // 记录答题
    _records.add(_AnswerRecord(word: q.word, correct: correct, selected: option));

    setState(() {
      _selectedOption = option;
      _showResult = true;
      _submitting = true;
    });

    _record(correct);

    // 2.5 秒后自动进入下一题
    _autoNextTimer?.cancel();
    _autoNextTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted && !_submitting) {
        _next();
      }
    });
  }

  void _record(bool correct) async {
    try {
      final q = _questions[_currentIndex];
      if (correct) _correctCount++;
      final db = await DatabaseProvider.database;
      await LearningRecordDao(db).insert(
        LearningRecord.create(
          type: LearningType.dictation,
          target: q.word,
          result: correct ? 100.0 : 0.0,
        ),
      );
      // 闭环断点①：写回生词本掌握度
      await MasteryService.applyWordResult(q.word, correct: correct);
      AppLog.d(_tag, '听写 ${correct ? "✓" : "✗"}: ${q.word}');
    } catch (e) {
      AppLog.e(_tag, '记录听写结果失败: $e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _next() {
    _autoNextTimer?.cancel();
    if (_currentIndex + 1 >= _questions.length) {
      _finish();
      return;
    }
    setState(() {
      _currentIndex++;
      _showResult = false;
      _selectedOption = null;
    });
    _playCurrent();
  }

  void _finish() {
    _autoNextTimer?.cancel();
    final total = _questions.length;
    final correct = _correctCount;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder:
          (context) => AlertDialog(
            title: const Text('听写完成！'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '共 $total 题\n正确 $correct 题\n'
                  '得分 ${total > 0 ? (correct * 100 / total).round() : 0} 分',
                  style: const TextStyle(fontSize: 18, height: 1.6),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                const Text(
                  '答题记录',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: StudyPalette.inkSoft,
                  ),
                ),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 200),
                  child: ListView(
                    children: _records.map((r) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          children: [
                            Icon(
                              r.correct ? Icons.check_circle : Icons.cancel,
                              size: 16,
                              color:
                                  r.correct
                                      ? StudyPalette.moss
                                      : StudyPalette.ember,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              r.word,
                              style: const TextStyle(fontSize: 16),
                            ),
                            if (r.selected != null && !r.correct) ...[
                              const SizedBox(width: 8),
                              Text(
                                '（选了「${r.selected}」）',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: StudyPalette.inkSoft,
                                ),
                              ),
                            ],
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ],
            ),
            actions: [
              FilledButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  Navigator.of(context).pop();
                },
                child: const Text('完成'),
              ),
            ],
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!_started) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final mode =
        _questions.isNotEmpty
            ? (_questions.first.options != null
                ? DictationMode.charSelect
                : DictationMode.spelling)
            : DictationMode.charSelect;

    return Scaffold(
      appBar: AppBar(
        title: Text(mode.label),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () {
            if (_currentIndex > 0) {
              _finish();
            } else {
              Navigator.of(context).pop();
            }
          },
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          children: [
            const SizedBox(height: 16),
            // 进度
            LinearProgressIndicator(
              value: (_currentIndex + 1) / _questions.length,
              minHeight: 6,
              backgroundColor: StudyPalette.parchmentDeep,
              valueColor: const AlwaysStoppedAnimation<Color>(
                StudyPalette.ember,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${_currentIndex + 1} / ${_questions.length}  ·  '
              '正确 $_correctCount',
              style: const TextStyle(fontSize: 13, color: StudyPalette.inkSoft),
            ),
            const SizedBox(height: 32),

            // 题目内容
            Expanded(
              child:
                  mode == DictationMode.charSelect
                      ? _buildCharSelect()
                      : _buildReadAloudList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCharSelect() {
    final q = _questions[_currentIndex];
    return CharSelectGrid(
      options: q.options ?? [],
      correctAnswer: q.word,
      selectedOption: _selectedOption,
      showResult: _showResult,
      isPlaying: _ttsPlaying,
      onReplay: _ttsPlaying ? null : _playCurrent,
      onSelect: _submitCharSelect,
    );
  }

  /// [v0.1.56] 朗读列表模式：全屏显示当前词语，自动朗读，3 秒后自动切换下一词。
  Widget _buildReadAloudList() {
    final q = _questions[_currentIndex];
    final isLast = _currentIndex + 1 >= _questions.length;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // 进度提示
        Text(
          '${_currentIndex + 1} / ${_questions.length}',
          style: const TextStyle(
            fontSize: 14,
            color: StudyPalette.inkSoft,
          ),
        ),
        const SizedBox(height: 16),

        // 当前词语（大字显示）
        Container(
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: StudyPalette.parchmentDeep.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: StudyPalette.ember.withValues(alpha: 0.3),
              width: 2,
            ),
          ),
          child: Text(
            q.word,
            style: const TextStyle(
              fontSize: 48,
              fontWeight: FontWeight.w700,
              color: StudyPalette.ink,
            ),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 32),

        // 重新播放
        IconButton(
          icon: Icon(
            _ttsPlaying ? Icons.volume_up : Icons.volume_up_outlined,
            size: 48,
            color: StudyPalette.ember,
          ),
          onPressed: _ttsPlaying ? null : _playCurrent,
          tooltip: '再听一遍',
        ),
        const SizedBox(height: 16),

        // 已朗读词语列表
        if (_records.isNotEmpty)
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '已读词语',
                  style: TextStyle(
                    fontSize: 13,
                    color: StudyPalette.inkSoft,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _records.map((r) {
                    return Chip(
                      label: Text(r.word),
                      backgroundColor:
                          r.correct
                              ? StudyPalette.moss.withValues(alpha: 0.2)
                              : StudyPalette.ember.withValues(alpha: 0.2),
                      side: BorderSide.none,
                    );
                  }).toList(),
                ),
              ],
            ),
          ),

        const SizedBox(height: 16),

        // 下一题按钮（也可等自动切换）
        FilledButton.icon(
          onPressed: _submitting ? null : _next,
          icon: Icon(isLast ? Icons.flag : Icons.arrow_forward),
          label: Text(isLast ? '完成' : '下一词'),
        ),
      ],
    );
  }
}
