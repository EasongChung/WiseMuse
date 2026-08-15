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
import '../follow/follow_page.dart';
import 'sentence_dictation_page.dart';

/// [v0.1.0] 听写页面：中文听音选字 / 英文拼写 / 语音跟读 三种模式。
///
/// 词源：生词本（优先未掌握词）或手动输入。
/// 结果记入 LearningRecord。
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

  // 拼写输入
  final _spellingCtrl = TextEditingController();

  // 结果反馈
  bool _showResult = false;
  bool _lastCorrect = false;

  bool _loading = true;
  bool _started = false;
  bool _ttsPlaying = false;
  bool _submitting = false;

  // 选字模式已选
  String? _selectedOption;

  @override
  void initState() {
    super.initState();
    _showSourcePicker();
  }

  /// [v2.11.0] 选择词源：生词本 / 手动输入 / 知识库。
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
                  subtitle: const Text('选教材→单元→课，从中听写'),
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
      if (mounted) Navigator.of(context).pop();
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
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('该范围无可用知识点')));
        }
        return;
      }
      _showModeAndStart(words);
    } catch (e) {
      AppLog.e(_tag, '从知识库加载失败: $e');
    }
  }

  Future<void> _loadManual() async {
    final input = await _showWordInputDialog();
    if (input == null || !mounted) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    _showModeAndStart(
      input.split(RegExp(r'[\s,，、]+')).where((w) => w.isNotEmpty).toList(),
    );
  }

  Future<void> _loadFromWordbook() async {
    try {
      final db = await DatabaseProvider.database;
      final entries = await WordEntryDao(db).getUnmastered(threshold: 3);
      final words = entries.map((e) => e.word).toList();
      if (!mounted) return;

      if (words.isEmpty) {
        await _loadManual();
        return;
      }
      _showModeAndStart(words);
    } catch (e) {
      AppLog.e(_tag, '加载生词本失败: $e');
      if (mounted) _showModeAndStart(['大', '小', '上', '下', '人', '山', '水', '火']);
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

    // 句子默写模式
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

    final mode = DictationMode.values.firstWhere((m) => m.name == modeStr);

    // 语音跟读跳转到 FollowPage
    if (mode == DictationMode.voice) {
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const FollowPage()),
        );
      }
      return;
    }

    final questions = DictationEngine.makeQuestions(
      words,
      mode: mode,
      count: 10,
    );

    if (questions.isEmpty && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('没有适合该模式的题目，试试其他模式')));
      Navigator.of(context).pop();
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
                            : mode == DictationMode.spelling
                            ? Icons.keyboard
                            : Icons.record_voice_over,
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
                    '句子默写',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: const Text('拼字积木 / 语音默写，逐句评分'),
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
        return '听发音 → 拼写输入 → 自动判对错';
      case DictationMode.voice:
        return '听发音 → 跟读录音 → Vosk 识别评分';
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

    setState(() {
      _selectedOption = option;
      _lastCorrect = correct;
      _showResult = true;
      _submitting = true;
    });

    _record(correct);
  }

  void _submitSpelling() {
    if (_submitting || _showResult) return;
    final q = _questions[_currentIndex];
    final input = _spellingCtrl.text.trim();
    final correct = DictationEngine.checkSpelling(q.word, input);

    setState(() {
      _lastCorrect = correct;
      _showResult = true;
      _submitting = true;
    });

    _record(correct);
  }

  Future<void> _record(bool correct) async {
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
    if (_currentIndex + 1 >= _questions.length) {
      _finish();
      return;
    }
    setState(() {
      _currentIndex++;
      _showResult = false;
      _lastCorrect = false;
      _selectedOption = null;
      _spellingCtrl.clear();
    });
    _playCurrent();
  }

  void _finish() {
    final total = _questions.length;
    final correct = _correctCount;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder:
          (context) => AlertDialog(
            title: const Text('听写完成！'),
            content: Text(
              '共 $total 题\n正确 $correct 题\n得分 ${total > 0 ? (correct * 100 / total).round() : 0} 分',
              style: const TextStyle(fontSize: 18, height: 1.6),
              textAlign: TextAlign.center,
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
                      : _buildSpelling(),
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

  Widget _buildSpelling() {
    final q = _questions[_currentIndex];

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          '听发音，输入拼写',
          style: TextStyle(fontSize: 14, color: StudyPalette.inkSoft),
        ),
        const SizedBox(height: 12),

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
        const SizedBox(height: 24),

        // 输入框
        TextField(
          controller: _spellingCtrl,
          decoration: InputDecoration(
            hintText: '输入拼写',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            suffixIcon:
                _showResult
                    ? Icon(
                      _lastCorrect ? Icons.check : Icons.close,
                      color:
                          _lastCorrect ? StudyPalette.moss : StudyPalette.ember,
                    )
                    : IconButton(
                      icon: const Icon(Icons.send),
                      onPressed: _submitSpelling,
                    ),
          ),
          autofocus: true,
          textInputAction: TextInputAction.send,
          onSubmitted:
              (_showResult || _submitting) ? null : (_) => _submitSpelling(),
          enabled: !_showResult,
        ),

        const SizedBox(height: 16),

        if (_showResult)
          Column(
            children: [
              Text(
                _lastCorrect ? '正确！' : '答案是「${q.word}」',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: _lastCorrect ? StudyPalette.moss : StudyPalette.ember,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _submitting ? null : _next,
                icon: const Icon(Icons.arrow_forward),
                label: Text(
                  _currentIndex + 1 >= _questions.length ? '完成' : '下一题',
                ),
              ),
            ],
          ),
      ],
    );
  }
}
