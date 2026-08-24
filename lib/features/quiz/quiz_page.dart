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
import '../../core/storage/word_entry_dao.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/json_util.dart';
import '../../services/ai_service.dart';
import '../../services/hybrid_tts_service.dart';
import '../../services/mastery_service.dart';
import '../../services/tts_service.dart';
import '../../widgets/char_select_grid.dart';
import '../assistant/tutor_interactive_sheet.dart';
import 'quiz_question_builder.dart';
import 'quiz_scorer.dart';

/// [v0.3.0] [v0.1.62] 章节测验页：三阶分级题型（基础认读/词句理解/拓展应用）+ 即时正误动效 + 错题沉淀与 AI 助教直达讲评。
class QuizPage extends StatefulWidget {
  const QuizPage({
    super.key,
    required this.book,
    this.chapter,
    this.isWrongWordMode = false,
  });

  final Book book;
  final int? chapter;
  final bool isWrongWordMode;

  @override
  State<QuizPage> createState() => _QuizPageState();
}

class _QuizPageState extends State<QuizPage> {
  static const _tag = 'quiz_page';

  final TtsService _tts = HybridTtsService.instance;
  final AiService _ai = AiService();

  List<QuizQuestion> _questions = const [];
  int _currentIndex = 0;

  // 各题型得分统计
  final List<double> _readScores = [];
  final List<bool> _charResults = [];
  final List<bool> _meaningResults = [];
  final List<bool> _choiceResults = [];

  // 本次错题列表（供成绩单复盘）
  final List<QuizQuestion> _wrongQuestions = [];

  // 当前状态
  bool _loading = true;
  bool _ttsPlaying = false;
  bool _answered = false;
  bool _correct = false;
  bool _submitting = false;

  // 选项与已选状态
  List<String> _choiceOptions = const [];
  String? _selectedChoice;
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
      final wordDao = WordEntryDao(db);

      if (widget.isWrongWordMode) {
        final unmastered = await wordDao.getUnmastered(threshold: 3);
        final allPoints = await kpDao.getAll();
        final wrongWordList = unmastered.map((w) => w.word).toList();

        final questions = QuizQuestionBuilder.buildWrongWordQuestions(
          wrongWordList,
          allPoints,
        );

        if (!mounted) return;
        setState(() {
          _questions = questions;
          _loading = false;
        });
        return;
      }

      final points =
          widget.chapter != null && widget.chapter! > 0
              ? await kpDao.getByChapter(widget.book.id, widget.chapter!)
              : await kpDao.getByBook(widget.book.id);

      if (!mounted) return;

      final configured = await SettingsService.instance.isApiConfigured();
      final hasAi = configured;

      final questions = QuizQuestionBuilder.buildQuestions(
        points,
        hasAi: hasAi,
        wrongWords: await _loadWrongWords(),
      );

      setState(() {
        _questions = questions;
        _loading = false;
      });

      if (questions.isNotEmpty && questions.first.type == QuestionType.choice) {
        _loadAiChoiceOptions();
      }
    } catch (e, s) {
      AppLog.e(_tag, '测验初始化失败: $e\n$s');
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<Map<String, int>> _loadWrongWords() async {
    try {
      final db = await DatabaseProvider.database;
      final dao = WordEntryDao(db);
      final words = await dao.getAll();
      final result = <String, int>{};
      for (final w in words) {
        if (w.wrongCount > 0) {
          result[w.word] = w.wrongCount;
        }
      }
      return result;
    } catch (e) {
      AppLog.e('quiz', '加载错词失败: $e');
      return const {};
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

  // ===== 1. 听音选字 =====
  void _onCharSelect(String option) {
    if (_submitting || _answered) return;
    final q = _currentQuestion;
    final correct = option == q.target;

    setState(() {
      _selectedOption = option;
      _answered = true;
      _correct = correct;
    });
    _charResults.add(correct);
    _recordResult(correct);
  }

  // ===== 2. 朗读认读 =====
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

  // ===== 3. 词句释义选择 =====
  void _onMeaningSelect(String option) {
    if (_submitting || _answered) return;
    final q = _currentQuestion;
    final correct = option == q.effectiveAnswer;

    setState(() {
      _selectedChoice = option;
      _answered = true;
      _correct = correct;
    });
    _meaningResults.add(correct);
    _recordResult(correct);
  }

  // ===== 4. AI 拓展选择题 =====
  Future<void> _loadAiChoiceOptions() async {
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
    final correct = option == q.effectiveAnswer;

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
    if (!correct && !_wrongQuestions.contains(q)) {
      _wrongQuestions.add(q);
    }

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

      if (q.knowledgePoint != null) {
        await MasteryService.applyKnowledgeResult(
          q.knowledgePoint!,
          correct: correct,
        );
      }

      if (!correct) {
        await MasteryService.applyWordResult(
          q.target,
          correct: false,
          bookId: widget.book.id == 'wrong_words' ? null : widget.book.id,
        );
      }
    } catch (e, s) {
      AppLog.e(_tag, '记录结果失败: $e\n$s');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  // ===== 导航与下一题 =====
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

    if (_currentIndex < _questions.length &&
        _questions[_currentIndex].type == QuestionType.choice) {
      _loadAiChoiceOptions();
    }
  }

  Future<void> _finish() async {
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

    final meaningScore =
        _meaningResults.isEmpty
            ? null
            : QuizScorer.percent(
              _meaningResults.where((c) => c).length,
              _meaningResults.length,
            );

    final choiceScore =
        _choiceResults.isEmpty
            ? null
            : QuizScorer.percent(
              _choiceResults.where((c) => c).length,
              _choiceResults.length,
            );

    // 综合计算总分
    var totalWeight = 0.0;
    var weightedSum = 0.0;
    if (readAvg != null) {
      weightedSum += readAvg * 0.35;
      totalWeight += 0.35;
    }
    if (charScore != null) {
      weightedSum += charScore * 0.25;
      totalWeight += 0.25;
    }
    if (meaningScore != null) {
      weightedSum += meaningScore * 0.25;
      totalWeight += 0.25;
    }
    if (choiceScore != null) {
      weightedSum += choiceScore * 0.15;
      totalWeight += 0.15;
    }
    final totalScore =
        totalWeight > 0 ? (weightedSum / totalWeight).clamp(0.0, 100.0) : 0.0;

    final correctCount =
        _readScores.where((s) => s >= 80).length +
        _charResults.where((c) => c).length +
        _meaningResults.where((c) => c).length +
        _choiceResults.where((c) => c).length;

    try {
      if (!widget.isWrongWordMode) {
        final db = await DatabaseProvider.database;
        await QuizAttemptDao(db).insert(
          QuizAttempt.create(
            bookId: widget.book.id,
            chapter: widget.chapter ?? 0,
            totalScore: totalScore,
            questionCount: _questions.length,
            correctCount: correctCount,
          ),
        );
      }
    } catch (e, s) {
      AppLog.e(_tag, '保存测验记录失败: $e\n$s');
    }

    if (!mounted) return;
    _showSummaryDialog(totalScore, correctCount);
  }

  void _showSummaryDialog(double totalScore, int correctCount) {
    final stars = QuizScorer.starRating(totalScore);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: isDark ? StudyPalette.darkCard : StudyPalette.parchment,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 30),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: StudyPalette.linen,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.emoji_events,
                    color: StudyPalette.ember,
                    size: 24,
                  ),
                  const SizedBox(width: 8),
                  Text('测验成绩单', style: titleStyle(fontSize: 20)),
                ],
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color:
                      isDark
                          ? StudyPalette.darkBorder
                          : StudyPalette.parchmentDeep,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(5, (i) {
                        return Icon(
                          i < stars
                              ? Icons.star_rounded
                              : Icons.star_outline_rounded,
                          color: StudyPalette.ember,
                          size: 32,
                        );
                      }),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${totalScore.toStringAsFixed(0)} 分',
                      style: titleStyle(
                        fontSize: 32,
                        color:
                            totalScore >= 80
                                ? StudyPalette.moss
                                : StudyPalette.ember,
                      ),
                    ),
                    Text(
                      '共 ${_questions.length} 题 · 答对 $correctCount 题',
                      style: const TextStyle(
                        fontSize: 13,
                        color: StudyPalette.inkSoft,
                      ),
                    ),
                  ],
                ),
              ),
              if (_wrongQuestions.isNotEmpty) ...[
                const SizedBox(height: 14),
                Row(
                  children: [
                    const Icon(
                      Icons.error_outline,
                      size: 16,
                      color: StudyPalette.ember,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '本次错题清单 (${_wrongQuestions.length})',
                      style: titleStyle(fontSize: 14),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: _wrongQuestions.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder: (_, i) {
                      final wq = _wrongQuestions[i];
                      return Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color:
                              isDark ? StudyPalette.darkBorder : Colors.white,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: StudyPalette.linen),
                        ),
                        child: Row(
                          children: [
                            Text(
                              '✗',
                              style: const TextStyle(
                                color: StudyPalette.ember,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    wq.target,
                                    style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  if (wq.explanation != null)
                                    Text(
                                      wq.explanation!,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: StudyPalette.inkSoft,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            TextButton.icon(
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                              ),
                              icon: const Icon(
                                Icons.auto_awesome,
                                size: 14,
                                color: StudyPalette.ember,
                              ),
                              label: const Text(
                                '助教讲评',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: StudyPalette.ember,
                                ),
                              ),
                              onPressed:
                                  () => TutorInteractiveSheet.show(
                                    context,
                                    wq.target,
                                  ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
              const SizedBox(height: 16),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: StudyPalette.ember,
                ),
                onPressed: () {
                  Navigator.pop(ctx);
                  Navigator.pop(context);
                },
                child: const Text('完成测验'),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('测验中')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_questions.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('章节测验')),
        body: const Center(
          child: Text(
            '暂无可测验的题目，请先在知识库提取知识点',
            style: TextStyle(color: StudyPalette.inkSoft),
          ),
        ),
      );
    }

    final q = _currentQuestion;
    final progress = '${_currentIndex + 1} / ${_questions.length}';

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.isWrongWordMode ? '错题消灭特训' : '${widget.book.title} · 测验',
        ),
        actions: [
          IconButton(
            icon: const Icon(
              Icons.lightbulb_outline,
              color: StudyPalette.ember,
            ),
            tooltip: '助教点拨',
            onPressed: () => TutorInteractiveSheet.show(context, q.target),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 分阶段指示器 + 进度条
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: StudyPalette.emberSoft,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    q.type.stage.label,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: StudyPalette.ember,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${q.type.label} · 第 $progress 题',
                  style: const TextStyle(
                    fontSize: 12,
                    color: StudyPalette.inkSoft,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: (_currentIndex + 1) / _questions.length,
              minHeight: 4,
              backgroundColor: StudyPalette.linen,
              color: StudyPalette.ember,
            ),
            const SizedBox(height: 16),
            Expanded(child: _buildQuestionBody(q, isDark)),
            if (_answered) _buildResultBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildQuestionBody(QuizQuestion q, bool isDark) {
    switch (q.type) {
      case QuestionType.read:
        return _buildReadContent(q, isDark);
      case QuestionType.charSelect:
        return _buildCharSelectContent(q);
      case QuestionType.meaningChoice:
        return _buildMeaningChoiceContent(q, isDark);
      case QuestionType.choice:
        return _buildAiChoiceContent(q, isDark);
    }
  }

  Widget _buildReadContent(QuizQuestion q, bool isDark) {
    return SingleChildScrollView(
      child: Column(
        children: [
          Text(
            q.prompt ?? '请朗读以下词句：',
            style: const TextStyle(fontSize: 14, color: StudyPalette.inkSoft),
          ),
          const SizedBox(height: 16),
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: StudyPalette.linen),
            ),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                q.target,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
          const SizedBox(height: 16),
          IconButton(
            icon: Icon(
              _ttsPlaying ? Icons.hourglass_top : Icons.volume_up_outlined,
              size: 40,
              color: StudyPalette.ember,
            ),
            onPressed:
                _answered || _submitting || _ttsPlaying ? null : _playCurrent,
            tooltip: '听发音',
          ),
          const SizedBox(height: 8),
          const Text(
            '先听范读，朗读完毕后点击下方按钮：',
            style: TextStyle(fontSize: 12, color: StudyPalette.inkSoft),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _answered || _submitting ? null : _skipRead,
                  icon: const Icon(Icons.close),
                  label: const Text('不熟练(需复习)'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: StudyPalette.moss,
                  ),
                  onPressed: _answered || _submitting ? null : _markRead,
                  icon: const Icon(Icons.check),
                  label: const Text('朗读正确'),
                ),
              ),
            ],
          ),
        ],
      ),
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

  Widget _buildMeaningChoiceContent(QuizQuestion q, bool isDark) {
    final options = q.options ?? [];
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            q.prompt ?? '请选出正确答案：',
            style: const TextStyle(fontSize: 14, color: StudyPalette.inkSoft),
          ),
          const SizedBox(height: 14),
          ...options.map((opt) {
            final isSelected = _selectedChoice == opt;
            final isCorrect = opt == q.effectiveAnswer;
            Color borderCol = StudyPalette.linen;
            Color bgCol = isDark ? StudyPalette.darkCard : Colors.white;

            if (_answered) {
              if (isCorrect) {
                borderCol = StudyPalette.moss;
                bgCol = StudyPalette.moss.withValues(alpha: 0.15);
              } else if (isSelected) {
                borderCol = StudyPalette.ember;
                bgCol = StudyPalette.ember.withValues(alpha: 0.15);
              }
            }

            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: _answered ? null : () => _onMeaningSelect(opt),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: bgCol,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: borderCol),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          opt,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight:
                                isSelected
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                            color: StudyPalette.onSurfaceResolved(context),
                          ),
                        ),
                      ),
                      if (_answered && isCorrect)
                        const Icon(
                          Icons.check_circle,
                          color: StudyPalette.moss,
                          size: 20,
                        ),
                      if (_answered && isSelected && !isCorrect)
                        const Icon(
                          Icons.cancel,
                          color: StudyPalette.ember,
                          size: 20,
                        ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildAiChoiceContent(QuizQuestion q, bool isDark) {
    if (_submitting) return const Center(child: CircularProgressIndicator());
    final options =
        _choiceOptions.isNotEmpty ? _choiceOptions : (q.options ?? []);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            q.prompt ?? '请选出最合适的一项：',
            style: const TextStyle(fontSize: 14, color: StudyPalette.inkSoft),
          ),
          const SizedBox(height: 14),
          ...options.map((opt) {
            final isSelected = _selectedChoice == opt;
            final isCorrect = opt == q.effectiveAnswer;
            Color borderCol = StudyPalette.linen;
            Color bgCol = isDark ? StudyPalette.darkCard : Colors.white;

            if (_answered) {
              if (isCorrect) {
                borderCol = StudyPalette.moss;
                bgCol = StudyPalette.moss.withValues(alpha: 0.15);
              } else if (isSelected) {
                borderCol = StudyPalette.ember;
                bgCol = StudyPalette.ember.withValues(alpha: 0.15);
              }
            }

            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: _answered ? null : () => _onChoiceSelect(opt),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: bgCol,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: borderCol),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          opt,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight:
                                isSelected
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                            color: StudyPalette.onSurfaceResolved(context),
                          ),
                        ),
                      ),
                      if (_answered && isCorrect)
                        const Icon(
                          Icons.check_circle,
                          color: StudyPalette.moss,
                          size: 20,
                        ),
                      if (_answered && isSelected && !isCorrect)
                        const Icon(
                          Icons.cancel,
                          color: StudyPalette.ember,
                          size: 20,
                        ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildResultBar() {
    final q = _currentQuestion;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color:
            _correct
                ? StudyPalette.moss.withValues(alpha: 0.12)
                : StudyPalette.ember.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Icon(
                _correct ? Icons.check_circle : Icons.cancel,
                color: _correct ? StudyPalette.moss : StudyPalette.ember,
              ),
              const SizedBox(width: 8),
              Text(
                _correct ? '回答正确！' : '回答错误',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: _correct ? StudyPalette.moss : StudyPalette.ember,
                ),
              ),
              const Spacer(),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: StudyPalette.ember,
                ),
                onPressed: _submitting ? null : _next,
                icon: Icon(_isLast ? Icons.check : Icons.arrow_forward),
                label: Text(_isLast ? '查看成绩' : '下一题'),
              ),
            ],
          ),
          if (!_correct && q.explanation != null) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '💡 解析：${q.explanation}',
                style: const TextStyle(fontSize: 12, color: StudyPalette.ink),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
