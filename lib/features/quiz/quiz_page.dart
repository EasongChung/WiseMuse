import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/debug/app_log.dart';
import '../../core/models/book.dart';
import '../../core/models/learning_record.dart';
import '../../core/models/quiz_attempt.dart';
import '../../core/settings/settings_service.dart';
import '../../core/storage/database.dart';
import '../../core/storage/knowledge_point_dao.dart';
import '../../core/storage/learning_record_dao.dart';
import '../../core/storage/quiz_attempt_dao.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/json_util.dart';
import '../../services/ai_service.dart';
import '../../services/mastery_service.dart';
import '../../services/native_tts_service.dart';
import '../../widgets/char_select_grid.dart';
import 'quiz_question_builder.dart';
import 'quiz_scorer.dart';

/// [v0.3.0] 章节测验页：三题型状态机。
///
/// 从知识点出题，逐题记录，完成时汇总写入 QuizAttempt。
class QuizPage extends StatefulWidget {
  const QuizPage({super.key, required this.book, this.chapter});

  final Book book;
  final int? chapter;

  @override
  State<QuizPage> createState() => _QuizPageState();
}

class _QuizPageState extends State<QuizPage> {
  static const _tag = 'quiz_page';

  final NativeTtsService _tts = NativeTtsService();
  final AiService _ai = AiService();

  List<QuizQuestion> _questions = const [];
  int _currentIndex = 0;

  // 各题型分数
  final List<double> _readScores = [];
  final List<bool> _charResults = [];
  final List<bool> _choiceResults = [];

  // 当前状态
  bool _loading = true;
  bool _ttsPlaying = false;
  bool _answered = false;
  bool _correct = false;
  bool _submitting = false;

  // 选择题状态
  List<String> _choiceOptions = const [];
  String? _selectedChoice;

  // 听音选字状态
  String? _selectedOption;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final db = await DatabaseProvider.database;
      final kpDao = KnowledgePointDao(db);

      final points =
          widget.chapter != null
              ? await kpDao.getByChapter(widget.book.id, widget.chapter!)
              : await kpDao.getByBook(widget.book.id);

      if (!mounted) return;

      // 检测 AI 是否可用
      final configured = await SettingsService.instance.isApiConfigured();
      final hasAi = configured;

      final questions = QuizQuestionBuilder.buildQuestions(
        points,
        hasAi: hasAi,
      );

      setState(() {
        _questions = questions;
        _loading = false;
      });

      // 若第一题是 choice，预加载选项
      if (questions.isNotEmpty && questions.first.type == QuestionType.choice) {
        _loadChoiceOptions();
      }
    } catch (e, s) {
      AppLog.e(_tag, '测验初始化失败: $e\n$s');
      if (mounted) setState(() => _loading = false);
    }
  }

  QuizQuestion get _currentQuestion {
    assert(
      _questions.isNotEmpty && _currentIndex < _questions.length,
      'currentQuestion 越界',
    );
    return _questions[_currentIndex];
  }

  bool get _isLast => _currentIndex >= _questions.length - 1;

  Future<void> _playCurrent() async {
    if (_currentIndex >= _questions.length) return;
    setState(() => _ttsPlaying = true);
    await _tts.stop();
    await _tts.speak(_questions[_currentIndex].target);
    if (mounted) setState(() => _ttsPlaying = false);
  }

  // ===== 听音选字 =====

  void _onCharSelect(String option) {
    if (_submitting || _answered) return;
    final q = _currentQuestion;
    final correct = option == q.target;

    setState(() {
      _selectedOption = option;
      _answered = true;
      _correct = correct;
    });
    _recordResult(correct);
  }

  // ===== 朗读 =====

  void _markRead() {
    if (_submitting || _answered) return;
    setState(() {
      _answered = true;
      _correct = true;
    });
    _readScores.add(100.0);
    _recordResult(true);
  }

  void _skipRead() {
    if (_submitting || _answered) return;
    setState(() {
      _answered = true;
      _correct = false;
    });
    _readScores.add(0.0);
    _recordResult(false);
  }

  // ===== 选择题 =====

  Future<void> _loadChoiceOptions() async {
    if (_currentIndex >= _questions.length) return;
    final q = _currentQuestion;
    setState(() => _submitting = true);

    try {
      final prompt =
          '知识点: "${q.target}", 释义: "${q.knowledgePoint?.definition ?? ''}"\n'
          '请生成 3 个与它相似但不正确的干扰选项，只输出 JSON 数组，如 ["干扰1","干扰2","干扰3"]';
      final result = await _ai.complete(prompt, jsonObject: true);
      if (result != null) {
        final parsed = parseLooseJsonObject(result.text);
        final distractors = (parsed?['options'] as List?)?.cast<String>() ?? [];
        final all = [q.target, ...distractors]..shuffle();
        if (mounted) {
          setState(() {
            _choiceOptions = all;
            _submitting = false;
          });
        }
        return;
      }
    } catch (e) {
      AppLog.w(_tag, 'AI 生成选项失败: $e');
    }

    // AI 不可用/失败时回退到简单选项
    if (mounted) {
      setState(() {
        _choiceOptions = [q.target, '其他选项 A', '其他选项 B', '其他选项 C']..shuffle();
        _submitting = false;
      });
    }
  }

  void _onChoiceSelect(String option) {
    if (_submitting || _answered) return;
    final q = _currentQuestion;
    final correct = option == q.target;

    setState(() {
      _selectedChoice = option;
      _answered = true;
      _correct = correct;
    });
    _choiceResults.add(correct);
    _recordResult(correct);
  }

  // ===== 记录结果 =====

  Future<void> _recordResult(bool correct) async {
    if (_currentIndex >= _questions.length) return;
    final q = _currentQuestion;
    setState(() => _submitting = true);

    try {
      final db = await DatabaseProvider.database;
      final recordDao = LearningRecordDao(db);

      await recordDao.insert(
        LearningRecord.create(
          type: LearningType.quiz,
          target: q.target,
          result: correct ? 100.0 : 0.0,
        ),
      );

      // 更新掌握度
      if (q.knowledgePoint != null) {
        await MasteryService.applyKnowledgeResult(
          q.knowledgePoint!,
          correct: correct,
        );
      }

      // 答错 → 插入生词本
      if (!correct) {
        await MasteryService.applyWordResult(
          q.target,
          correct: false,
          bookId: widget.book.id,
        );
      }

      AppLog.d(_tag, '${correct ? "✓" : "✗"} ${q.type.label}: ${q.target}');
    } catch (e, s) {
      AppLog.e(_tag, '记录结果失败: $e\n$s');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  // ===== 导航 =====

  void _next() {
    if (_isLast) {
      _finish();
      return;
    }
    setState(() {
      _currentIndex++;
      _answered = false;
      _correct = false;
      _selectedOption = null;
      _selectedChoice = null;
      _choiceOptions = const [];
    });

    // 若下一题是 choice，预加载
    if (_currentIndex < _questions.length &&
        _questions[_currentIndex].type == QuestionType.choice) {
      _loadChoiceOptions();
    }
  }

  Future<void> _finish() async {
    // 计算各题分数
    final readAvg =
        _readScores.isEmpty
            ? null
            : _readScores.reduce((a, b) => a + b) / _readScores.length;

    final charScore =
        _charResults.isEmpty
            ? null
            : QuizScorer.percent(
              _charResults.where((c) => c).length,
              _charResults.length,
            );

    final choiceScore =
        _choiceResults.isEmpty
            ? null
            : QuizScorer.percent(
              _choiceResults.where((c) => c).length,
              _choiceResults.length,
            );

    final totalScore = QuizScorer.compute(readAvg, charScore, choiceScore);

    // 写入 QuizAttempt
    try {
      final db = await DatabaseProvider.database;
      final correctCount =
          _readScores.where((s) => s >= 80).length +
          _charResults.where((c) => c).length +
          _choiceResults.where((c) => c).length;

      await QuizAttemptDao(db).insert(
        QuizAttempt.create(
          bookId: widget.book.id,
          chapter: widget.chapter ?? 0,
          totalScore: totalScore,
          questionCount: _questions.length,
          correctCount: correctCount,
        ),
      );
      AppLog.d(
        _tag,
        '测验完成: 总分=$totalScore, 正确=$correctCount/${_questions.length}',
      );
    } catch (e, s) {
      AppLog.e(_tag, '保存测验记录失败: $e\n$s');
    }

    if (!mounted) return;
    _showSummary(readAvg, charScore, choiceScore, totalScore);
  }

  void _showSummary(
    double? readAvg,
    double? charScore,
    double? choiceScore,
    double totalScore,
  ) {
    final star = QuizScorer.starRating(totalScore);
    final correctCount =
        _readScores.where((s) => s >= 80).length +
        _charResults.where((c) => c).length +
        _choiceResults.where((c) => c).length;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder:
          (context) => AlertDialog(
            title: Row(
              children: [
                const Text('测验完成！'),
                const Spacer(),
                Text(
                  '$star ★',
                  style: titleStyle(fontSize: 24, color: StudyPalette.ember),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _scoreRow('总分', totalScore, isTotal: true),
                const Divider(height: 16),
                if (readAvg != null) _scoreRow('朗读', readAvg),
                if (charScore != null) _scoreRow('听音选字', charScore),
                if (choiceScore != null) _scoreRow('选择题', choiceScore),
                const SizedBox(height: 8),
                Text(
                  '共 ${_questions.length} 题，正确 $correctCount 题',
                  style: const TextStyle(
                    fontSize: 14,
                    color: StudyPalette.inkSoft,
                  ),
                ),
              ],
            ),
            actions: [
              FilledButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  Navigator.of(context).pop(); // 返回测验首页
                },
                child: const Text('完成'),
              ),
            ],
          ),
    );
  }

  Widget _scoreRow(String label, double score, {bool isTotal = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: isTotal ? 18 : 14,
              fontWeight: isTotal ? FontWeight.w700 : FontWeight.w500,
              color: StudyPalette.ink,
            ),
          ),
          const Spacer(),
          Text(
            '${score.round()} 分',
            style: titleStyle(
              fontSize: isTotal ? 28 : 20,
              color:
                  score >= 80
                      ? StudyPalette.moss
                      : score >= 60
                      ? StudyPalette.ember
                      : StudyPalette.ember,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('章节测验')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_questions.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('章节测验')),
        body: const Center(
          child: Text(
            '暂无知识点，请先提取或手动添加',
            style: TextStyle(color: StudyPalette.inkSoft),
          ),
        ),
      );
    }

    final q = _currentQuestion;
    final progress = '${_currentIndex + 1} / ${_questions.length}';

    return Scaffold(
      appBar: AppBar(title: Text('章节测验 · $progress')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 进度条
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
              '${q.type.label}  ·  $progress',
              style: const TextStyle(fontSize: 13, color: StudyPalette.inkSoft),
            ),
            const SizedBox(height: 24),

            // 题目内容
            Expanded(child: _buildQuestionContent(q)),

            // 结果反馈 + 下一题
            if (_answered) _buildResultBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildQuestionContent(QuizQuestion q) {
    switch (q.type) {
      case QuestionType.read:
        return _buildReadContent(q);
      case QuestionType.charSelect:
        return _buildCharSelectContent(q);
      case QuestionType.choice:
        return _buildChoiceContent(q);
    }
  }

  Widget _buildReadContent(QuizQuestion q) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          '请朗读以下内容',
          style: TextStyle(fontSize: 14, color: StudyPalette.inkSoft),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              q.target,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w600,
                color: StudyPalette.ink,
                height: 1.5,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
        const SizedBox(height: 20),
        IconButton(
          icon: Icon(
            _ttsPlaying ? Icons.volume_up : Icons.volume_up_outlined,
            size: 48,
            color: StudyPalette.ember,
          ),
          onPressed:
              _answered || _submitting || _ttsPlaying ? null : _playCurrent,
          tooltip: '播放',
        ),
        const SizedBox(height: 8),
        const Text(
          '先听播放，朗读后点「已朗读」',
          style: TextStyle(fontSize: 12, color: StudyPalette.inkSoft),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _answered || _submitting ? null : _skipRead,
                icon: const Icon(Icons.close),
                label: const Text('跳过'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: _answered || _submitting ? null : _markRead,
                icon: const Icon(Icons.check),
                label: const Text('已朗读'),
                style: FilledButton.styleFrom(
                  backgroundColor: StudyPalette.moss,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildCharSelectContent(QuizQuestion q) {
    return Center(
      child: CharSelectGrid(
        options: q.options ?? [],
        correctAnswer: q.target,
        selectedOption: _selectedOption,
        showResult: _answered,
        isPlaying: _ttsPlaying,
        onReplay: _answered ? null : _playCurrent,
        onSelect: _onCharSelect,
      ),
    );
  }

  Widget _buildChoiceContent(QuizQuestion q) {
    if (_submitting) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_choiceOptions.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '正在生成选项…',
              style: TextStyle(color: StudyPalette.inkSoft),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _loadChoiceOptions,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '请选择正确答案',
          style: TextStyle(fontSize: 14, color: StudyPalette.inkSoft),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              q.target,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: StudyPalette.ink,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
        const SizedBox(height: 16),
        ...List.generate(_choiceOptions.length, (i) {
          final opt = _choiceOptions[i];
          final selected = _selectedChoice == opt;
          Color bg;
          Color fg;

          if (_answered) {
            if (opt == q.target) {
              bg = StudyPalette.mossSoft;
              fg = StudyPalette.moss;
            } else if (selected) {
              bg = StudyPalette.ember.withValues(alpha: 0.15);
              fg = StudyPalette.ember;
            } else {
              bg = Colors.white.withValues(alpha: 0.6);
              fg = StudyPalette.inkSoft;
            }
          } else if (selected) {
            bg = StudyPalette.emberSoft;
            fg = StudyPalette.ember;
          } else {
            bg = Colors.white.withValues(alpha: 0.6);
            fg = StudyPalette.ink;
          }

          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Material(
              color: bg,
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: _answered ? null : () => _onChoiceSelect(opt),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 14,
                  ),
                  child: Text(
                    opt,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                      color: fg,
                    ),
                  ),
                ),
              ),
            ),
          );
        }),
      ],
    );
  }

  Widget _buildResultBar() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 16),
        Icon(
          _correct ? Icons.check_circle : Icons.cancel,
          size: 40,
          color: _correct ? StudyPalette.moss : StudyPalette.ember,
        ),
        const SizedBox(height: 4),
        Text(
          _correct ? '正确！' : '答错了',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: _correct ? StudyPalette.moss : StudyPalette.ember,
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _submitting ? null : _next,
          icon: Icon(_isLast ? Icons.check : Icons.arrow_forward),
          label: Text(_isLast ? '完成' : '下一题'),
        ),
      ],
    );
  }
}
