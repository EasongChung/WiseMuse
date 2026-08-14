import 'package:flutter/material.dart';

import '../core/debug/app_log.dart';
import '../core/models/word_entry.dart';
import '../core/theme/app_theme.dart';
import '../services/dictation_engine.dart';
import '../services/spaced_repetition_service.dart';

/// [v2.9.0] 复习卡片：三种形态，艾宾浩斯双向掌握度流转。
///
/// - [ReviewMode.flashcard]：卡片翻转记忆（看词 → 翻转看释义 → 自评）
/// - [ReviewMode.choice]：选择题辨析（看词选正确项）
/// - [ReviewMode.spelling]：拼写复习（听音输入拼写）
///
/// 结果通过 [SpacedRepetitionService.applyReviewResult] 落库：
/// 答对 → mastery+1，答错 → mastery-1 并 wrongCount+1。
class ReviewCard extends StatefulWidget {
  const ReviewCard({
    super.key,
    required this.words,
    this.onComplete,
    this.initialMode,
  });

  final List<WordEntry> words;
  final VoidCallback? onComplete;
  final ReviewMode? initialMode;

  @override
  State<ReviewCard> createState() => _ReviewCardState();
}

/// 复习形态。
enum ReviewMode {
  flashcard('卡片翻转'),
  choice('选择题'),
  spelling('拼写');

  const ReviewMode(this.label);
  final String label;
}

class _ReviewCardState extends State<ReviewCard> {
  static const _tag = 'review';

  int _index = 0;
  bool _saving = false;
  bool _flipped = false;
  bool _answered = false;
  bool _lastCorrect = false;
  String? _selectedChoice;
  List<String> _choiceOptions = const [];
  final _spellingCtrl = TextEditingController();
  late ReviewMode _mode;

  List<WordEntry> get _words => widget.words;

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode ?? ReviewMode.flashcard;
    _prepareChoice();
  }

  @override
  void dispose() {
    _spellingCtrl.dispose();
    super.dispose();
  }

  WordEntry get _entry => _words[_index];

  /// 选择题选项（4 选 1：正确词 + 3 个同音/形近干扰）。
  void _prepareChoice() {
    final word = _entry.word;
    if (word.length == 1) {
      final q = DictationEngine.makeCharSelectQuestion(word);
      _choiceOptions = q.options ?? [word];
    } else {
      // 多字词：用其他生词作干扰项
      final distractors =
          _words
              .where((w) => w.word != word)
              .map((w) => w.word)
              .take(3)
              .toList();
      final options = <String>{word, ...distractors};
      final common = ['你好', '今天', '学习', '天气', '学校', '老师'];
      for (final c in common) {
        if (options.length >= 4) break;
        options.add(c);
      }
      _choiceOptions = options.toList()..shuffle();
    }
  }

  /// 提交复习结果（答对/答错），双向流转掌握度。
  Future<void> _submit({required bool correct}) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final entry = _entry;
      await SpacedRepetitionService.applyReviewResult(entry, correct: correct);
      AppLog.d(
        _tag,
        '复习 ${correct ? "✓" : "✗"}: ${entry.word} mastery=${entry.mastery}',
      );
      await Future<void>.delayed(const Duration(milliseconds: 800));
      if (!mounted) return;
      _next();
    } catch (e) {
      AppLog.e(_tag, '复习保存失败: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _markKnown() => _submit(correct: true);
  void _markUnknown() => _submit(correct: false);

  void _onChoiceSelected(String option) {
    if (_answered || _saving) return;
    setState(() {
      _selectedChoice = option;
      _answered = true;
      _lastCorrect = option == _entry.word;
    });
    _submit(correct: _lastCorrect);
  }

  void _onSpellingSubmit() {
    if (_answered || _saving) return;
    final input = _spellingCtrl.text.trim();
    final correct = DictationEngine.checkSpelling(_entry.word, input);
    setState(() {
      _answered = true;
      _lastCorrect = correct;
    });
    _submit(correct: correct);
  }

  void _skip() {
    _next();
  }

  void _next() {
    if (_index + 1 >= _words.length) {
      widget.onComplete?.call();
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _index++;
      _flipped = false;
      _answered = false;
      _lastCorrect = false;
      _selectedChoice = null;
      _spellingCtrl.clear();
    });
    _prepareChoice();
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.words[_index];
    final progress = '${_index + 1} / ${widget.words.length}';
    return Scaffold(
      appBar: AppBar(
        title: Text('${_mode.label}复习 · $progress'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () {
            widget.onComplete?.call();
            Navigator.of(context).pop();
          },
        ),
        actions: [
          PopupMenuButton<ReviewMode>(
            icon: const Icon(Icons.swap_horiz),
            tooltip: '切换复习形态',
            onSelected: (m) {
              setState(() {
                _mode = m;
                _answered = false;
                _lastCorrect = false;
                _selectedChoice = null;
                _spellingCtrl.clear();
              });
              _prepareChoice();
            },
            itemBuilder:
                (ctx) =>
                    ReviewMode.values
                        .map(
                          (m) => PopupMenuItem(value: m, child: Text(m.label)),
                        )
                        .toList(),
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(
                value: (_index + 1) / widget.words.length,
                minHeight: 6,
                backgroundColor: StudyPalette.parchmentDeep,
                valueColor: const AlwaysStoppedAnimation<Color>(
                  StudyPalette.ember,
                ),
              ),
              const SizedBox(height: 24),
              Expanded(child: _buildModeContent(entry)),
              if (_answered) _buildResultBar(),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildModeContent(WordEntry entry) {
    switch (_mode) {
      case ReviewMode.flashcard:
        return _buildFlashcard(entry);
      case ReviewMode.choice:
        return _buildChoice(entry);
      case ReviewMode.spelling:
        return _buildSpelling(entry);
    }
  }

  Widget _buildFlashcard(WordEntry entry) {
    return GestureDetector(
      onTap: _saving ? null : () => setState(() => _flipped = !_flipped),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        child: Card(
          key: ValueKey(_flipped),
          color: StudyPalette.surfaceWithAlpha(context, alpha: 0.85),
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _flipped ? Icons.auto_stories : Icons.style,
                  size: 40,
                  color: _flipped ? StudyPalette.ember : StudyPalette.spinePdf,
                ),
                const SizedBox(height: 12),
                Text(
                  _flipped ? '这个词你记住了吗？' : entry.word,
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    color: StudyPalette.ink,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  _flipped
                      ? '掌握度 ${entry.mastery}/5 · 已错 ${entry.wrongCount} 次'
                      : '点击翻转查看详情',
                  style: const TextStyle(
                    fontSize: 14,
                    color: StudyPalette.inkSoft,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildChoice(WordEntry entry) {
    return Column(
      mainAxisSize: MainAxisSize.min,
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
              entry.word,
              style: const TextStyle(
                fontSize: 22,
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
          Color bg, fg;
          if (_answered) {
            if (opt == entry.word) {
              bg = StudyPalette.moss.withValues(alpha: 0.2);
              fg = StudyPalette.moss;
            } else if (selected) {
              bg = StudyPalette.ember.withValues(alpha: 0.15);
              fg = StudyPalette.ember;
            } else {
              bg = StudyPalette.surfaceWithAlpha(context, alpha: 0.6);
              fg = StudyPalette.inkSoft;
            }
          } else if (selected) {
            bg = StudyPalette.emberSoft;
            fg = StudyPalette.ember;
          } else {
            bg = StudyPalette.surfaceWithAlpha(context, alpha: 0.6);
            fg = StudyPalette.ink;
          }
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Material(
              color: bg,
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap:
                    _answered || _saving ? null : () => _onChoiceSelected(opt),
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

  Widget _buildSpelling(WordEntry entry) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          '看词输入拼写',
          style: TextStyle(fontSize: 14, color: StudyPalette.inkSoft),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              entry.word,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w600,
                color: StudyPalette.ink,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _spellingCtrl,
          decoration: InputDecoration(
            hintText: '输入拼写',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            suffixIcon:
                _answered
                    ? Icon(
                      _lastCorrect ? Icons.check : Icons.close,
                      color:
                          _lastCorrect ? StudyPalette.moss : StudyPalette.ember,
                    )
                    : IconButton(
                      icon: const Icon(Icons.send),
                      onPressed: _onSpellingSubmit,
                    ),
          ),
          autofocus: true,
          textInputAction: TextInputAction.send,
          onSubmitted:
              (_answered || _saving) ? null : (_) => _onSpellingSubmit(),
          enabled: !_answered,
        ),
      ],
    );
  }

  Widget _buildResultBar() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _lastCorrect ? Icons.check_circle : Icons.cancel,
              size: 32,
              color: _lastCorrect ? StudyPalette.moss : StudyPalette.ember,
            ),
            const SizedBox(width: 8),
            Text(
              _lastCorrect ? '掌握 +1' : '再记一次（掌握 -1）',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: _lastCorrect ? StudyPalette.moss : StudyPalette.ember,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _saving ? null : _skip,
                icon: const Icon(Icons.skip_next_outlined),
                label: const Text('跳过'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  side: const BorderSide(color: StudyPalette.inkSoft),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: FilledButton.icon(
                onPressed: _saving ? null : _markUnknown,
                icon: const Icon(Icons.replay),
                label: const Text('没记住'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  backgroundColor: StudyPalette.ember,
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: FilledButton.icon(
                onPressed: _saving ? null : _markKnown,
                icon: const Icon(Icons.check_circle_outline),
                label: const Text('掌握了'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  backgroundColor: StudyPalette.moss,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
