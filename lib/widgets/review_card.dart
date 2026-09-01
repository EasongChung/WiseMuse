import 'dart:async';

import 'package:flutter/material.dart';

import '../core/debug/app_log.dart';
import '../core/models/knowledge_point.dart';
import '../core/models/word_entry.dart';
import '../core/storage/database.dart';
import '../core/storage/knowledge_point_dao.dart';
import '../core/theme/app_theme.dart';
import '../services/hybrid_tts_service.dart';
import '../services/spaced_repetition_service.dart';
import 'review_item.dart';
import '../../widgets/top_toast.dart';

/// [v0.1.35] 复习卡片：三种形态，艾宾浩斯双向掌握度流转。
/// [v0.1.66] 重构为儿童友好交互：空态保护、显式自评、保存反馈、TTS 拼写。
///
/// - [ReviewMode.flashcard]：卡片翻转记忆（看词 → 翻转看释义/例句 → 自评）
/// - [ReviewMode.choice]：选择题辨析（不暴露答案，语义/听音选词）
/// - [ReviewMode.spelling]：拼写复习（隐藏目标词，听音输入，重播按钮）
class ReviewCard extends StatefulWidget {
  const ReviewCard({
    super.key,
    this.words = const [],
    this.items,
    this.onComplete,
    this.initialMode,
  });

  /// 普通生词复习。
  final List<WordEntry> words;

  /// 知识库等语义复习目标（优先于 [words]）。
  final List<ReviewItem>? items;
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

  final HybridTtsService _tts = HybridTtsService.instance;

  late final List<ReviewItem> _items;
  int _index = 0;
  ReviewMode _mode = ReviewMode.flashcard;
  bool _flipped = false;
  bool _answered = false;
  bool _lastCorrect = false;
  String? _selectedChoice;
  final _spellingCtrl = TextEditingController();
  List<String> _options = [];
  bool _saving = false;
  String? _saveError;
  bool _spellingPlaying = false;

  @override
  void initState() {
    super.initState();
    _items =
        widget.items ?? widget.words.map(ReviewItem.fromWordEntry).toList();
    _mode = widget.initialMode ?? ReviewMode.flashcard;
    if (_items.isNotEmpty) {
      _prepareChoice();
    }
  }

  @override
  void dispose() {
    _spellingCtrl.dispose();
    unawaited(_tts.stop());
    super.dispose();
  }

  ReviewItem? get _current => _items.isEmpty ? null : _items[_index];

  // ===== 题目准备 =====

  void _prepareChoice() {
    final current = _current;
    if (current == null) {
      _options = [];
      return;
    }
    final candidates =
        _items
            .where((it) => it.text != current.text && it.lang == current.lang)
            .map((it) => it.text)
            .toSet()
            .toList();
    candidates.shuffle();
    _options = [current.text, ...candidates.take(2)]..shuffle();
  }

  // ===== 状态推进 =====

  void _resetForCurrent() {
    setState(() {
      _flipped = false;
      _answered = false;
      _lastCorrect = false;
      _selectedChoice = null;
      _spellingCtrl.clear();
      _saveError = null;
      _spellingPlaying = false;
    });
    _prepareChoice();
  }

  void _next() {
    if (_index + 1 >= _items.length) {
      widget.onComplete?.call();
      if (mounted) Navigator.of(context).pop();
      return;
    }
    setState(() => _index++);
    _resetForCurrent();
  }

  void _skip() {
    _next();
  }

  void _switchMode(ReviewMode mode) {
    if (_mode == mode) return;
    unawaited(_tts.stop());
    setState(() {
      _mode = mode;
      _flipped = false;
      _answered = false;
      _lastCorrect = false;
      _selectedChoice = null;
      _spellingCtrl.clear();
      _saveError = null;
      _spellingPlaying = false;
    });
    _prepareChoice();
  }

  // ===== 提交/保存 =====

  Future<void> _submit({required bool correct}) async {
    if (_saving || _answered) return;
    setState(() {
      _saving = true;
      _answered = true;
      _lastCorrect = correct;
      _saveError = null;
    });
    try {
      final current = _current;
      if (current != null) {
        await _persistResult(current, correct);
      }
      AppLog.d(_tag, '复习 ${correct ? "✓" : "✗"}: ${current?.text ?? ""}');
    } catch (e) {
      AppLog.e(_tag, '复习保存失败: $e');
      setState(() => _saveError = '保存失败，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _persistResult(ReviewItem item, bool correct) async {
    final db = await DatabaseProvider.database;
    if (item.isKnowledgePoint && item.knowledgePoint != null) {
      // 知识库复习：回写 knowledge_points。
      final kp = item.knowledgePoint!;
      final newMastery =
          correct ? (kp.mastery + 1).clamp(0, 5) : (kp.mastery - 1).clamp(0, 5);
      await KnowledgePointDao(db).update(
        KnowledgePoint(
          id: kp.id,
          bookId: kp.bookId,
          page: kp.page,
          chapter: kp.chapter,
          type: kp.type,
          text: kp.text,
          definition: kp.definition,
          extra: kp.extra,
          source: kp.source,
          mastery: newMastery,
          wrongCount: correct ? kp.wrongCount : kp.wrongCount + 1,
          createdAt: kp.createdAt,
          updatedAt: DateTime.now().microsecondsSinceEpoch,
        ),
      );
    } else if (item.wordEntry != null) {
      // 普通生词：使用间隔重复服务。
      await SpacedRepetitionService.applyReviewResult(
        item.wordEntry!,
        correct: correct,
      );
    }
  }

  // ===== 模式交互 =====

  void _onChoiceSelected(String option) {
    if (_answered || _saving || _current == null) return;
    final correct = option == _current!.text;
    setState(() {
      _selectedChoice = option;
      _answered = true;
      _lastCorrect = correct;
    });
    _submit(correct: correct);
  }

  Future<void> _playSpelling() async {
    final current = _current;
    if (current == null || _spellingPlaying) return;
    setState(() => _spellingPlaying = true);
    try {
      await _tts.speak(current.text);
    } catch (e) {
      AppLog.e(_tag, '拼写 TTS 播放失败: $e');
      if (mounted) {
        TopToast.show(context, '语音播放失败，请检查 TTS 配置');
      }
    } finally {
      if (mounted) setState(() => _spellingPlaying = false);
    }
  }

  void _onSpellingSubmit() {
    if (_answered || _saving || _current == null) return;
    final input = _spellingCtrl.text.trim();
    final correct = input.toLowerCase() == _current!.text.toLowerCase();
    setState(() {
      _answered = true;
      _lastCorrect = correct;
    });
    _submit(correct: correct);
  }

  // ===== 构建 =====

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('复习'), centerTitle: true),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.menu_book_outlined,
                  size: 64,
                  color: StudyPalette.inkSoft.withValues(alpha: 0.4),
                ),
                const SizedBox(height: 16),
                Text('暂无待复习内容', style: titleStyle(fontSize: 18)),
                const SizedBox(height: 8),
                const Text(
                  '先在阅读中标记生词，或在知识库中选择范围',
                  style: TextStyle(fontSize: 13, color: StudyPalette.inkSoft),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      );
    }

    final current = _current!;
    final progress = '${_index + 1} / ${_items.length}';
    return Scaffold(
      appBar: AppBar(
        title: Text('${_mode.label}复习 · $progress'),
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () {
            unawaited(_tts.stop());
            Navigator.of(context).pop();
          },
        ),
        actions: [
          PopupMenuButton<ReviewMode>(
            icon: const Icon(Icons.swap_horiz_outlined),
            tooltip: '切换模式',
            onSelected: _switchMode,
            itemBuilder:
                (_) =>
                    ReviewMode.values
                        .map(
                          (m) => PopupMenuItem(value: m, child: Text(m.label)),
                        )
                        .toList(),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            LinearProgressIndicator(
              value: (_index + 1) / _items.length,
              minHeight: 3,
              backgroundColor: StudyPalette.linen,
              color: StudyPalette.ember,
            ),
            Expanded(child: _buildModeContent(current)),
            if (_saveError != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: Text(
                  _saveError!,
                  style: const TextStyle(
                    color: Color(0xFFB3261E),
                    fontSize: 13,
                  ),
                ),
              ),
            if (_answered) _buildResultBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildModeContent(ReviewItem item) {
    switch (_mode) {
      case ReviewMode.flashcard:
        return _buildFlashcard(item);
      case ReviewMode.choice:
        return _buildChoice(item);
      case ReviewMode.spelling:
        return _buildSpelling(item);
    }
  }

  // ===== 卡片翻转模式 =====

  Widget _buildFlashcard(ReviewItem item) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          const SizedBox(height: 16),
          GestureDetector(
            onTap: () => setState(() => _flipped = !_flipped),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child:
                  _flipped
                      ? _buildFlashcardBack(item)
                      : _buildFlashcardFront(item),
            ),
          ),
          const SizedBox(height: 16),
          TextButton.icon(
            onPressed: () => setState(() => _flipped = !_flipped),
            icon: const Icon(Icons.flip_outlined, size: 18),
            label: Text(_flipped ? '看词语' : '看释义'),
          ),
        ],
      ),
    );
  }

  Widget _buildFlashcardFront(ReviewItem item) {
    return Container(
      key: const ValueKey('front'),
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 200),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: StudyPalette.parchmentDeep,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: StudyPalette.linen, width: 1),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.psychology_outlined,
            size: 36,
            color: StudyPalette.inkSoft.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 16),
          Text(
            item.text,
            style: titleStyle(fontSize: 32),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            '轻触查看释义',
            style: TextStyle(
              fontSize: 13,
              color: StudyPalette.inkSoft.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFlashcardBack(ReviewItem item) {
    return Container(
      key: const ValueKey('back'),
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 200),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: StudyPalette.moss.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: StudyPalette.moss.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(item.text, style: titleStyle(fontSize: 28)),
          const SizedBox(height: 12),
          if (item.definition != null && item.definition!.isNotEmpty)
            Text(
              item.definition!,
              style: const TextStyle(fontSize: 15, height: 1.6),
            ),
          if (item.extra != null && item.extra!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              '示例：${item.extra!}',
              style: TextStyle(
                fontSize: 13,
                color: StudyPalette.inkSoft.withValues(alpha: 0.7),
                height: 1.5,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Text(
            '掌握度 ${item.mastery}/5 · 已错 ${item.wrongCount} 次',
            style: TextStyle(
              fontSize: 12,
              color: StudyPalette.inkSoft.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }

  // ===== 选择题模式 =====

  Widget _buildChoice(ReviewItem item) {
    final canSemantic = item.hasSemantic;
    final question =
        canSemantic
            ? (item.definition != null && item.definition!.isNotEmpty
                ? item.definition!
                : item.extra!)
            : '';
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 16),
          // 题干：优先释义，隐藏目标词
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: StudyPalette.parchmentDeep,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: StudyPalette.linen),
            ),
            child: Column(
              children: [
                if (canSemantic) ...[
                  Text(
                    '看到下面的词语，它是什么意思？',
                    style: titleStyle(fontSize: 16),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    question,
                    style: const TextStyle(fontSize: 15, height: 1.6),
                    textAlign: TextAlign.center,
                  ),
                ] else ...[
                  Icon(
                    Icons.volume_up_outlined,
                    size: 32,
                    color: StudyPalette.ember,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '听语音，选出正确的词语',
                    style: titleStyle(fontSize: 16),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: _spellingPlaying ? null : _playSpelling,
                    icon: const Icon(Icons.volume_up, size: 18),
                    label: const Text('播放语音'),
                    style: FilledButton.styleFrom(
                      backgroundColor: StudyPalette.ember,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 20),
          // 选项
          ..._options.map((option) {
            final selected = _selectedChoice == option;
            final isCorrect = option == item.text;
            Color? borderColor;
            Color? bgColor;
            if (_answered && selected) {
              borderColor = isCorrect ? StudyPalette.moss : Colors.red;
              bgColor =
                  isCorrect
                      ? StudyPalette.moss.withValues(alpha: 0.08)
                      : Colors.red.withValues(alpha: 0.05);
            } else if (selected) {
              borderColor = StudyPalette.ember;
              bgColor = StudyPalette.ember.withValues(alpha: 0.05);
            }
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: bgColor ?? Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: _answered ? null : () => _onChoiceSelected(option),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: borderColor ?? StudyPalette.linen,
                        width: _answered && selected ? 2 : 1,
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            option,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight:
                                  selected
                                      ? FontWeight.w600
                                      : FontWeight.normal,
                              color:
                                  selected
                                      ? StudyPalette.ember
                                      : StudyPalette.ink,
                            ),
                          ),
                        ),
                        if (_answered && isCorrect)
                          const Icon(
                            Icons.check_circle,
                            color: StudyPalette.moss,
                            size: 20,
                          )
                        else if (_answered && selected && !isCorrect)
                          const Icon(Icons.cancel, color: Colors.red, size: 20),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }),
          if (_answered) ...[
            const SizedBox(height: 12),
            Center(
              child: Text(
                _lastCorrect ? '答对了！' : '答错了，正确答案是 ${item.text}',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: _lastCorrect ? StudyPalette.moss : Colors.red,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ===== 拼写/听写模式 =====

  Widget _buildSpelling(ReviewItem item) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          const SizedBox(height: 16),
          // 隐藏目标词，显示提示
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: StudyPalette.parchmentDeep,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: StudyPalette.linen),
            ),
            child: Column(
              children: [
                Icon(Icons.edit_outlined, size: 32, color: StudyPalette.ember),
                const SizedBox(height: 12),
                Text(
                  '先听语音，再写出听到的词语',
                  style: titleStyle(fontSize: 16),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _spellingPlaying ? null : _playSpelling,
                  icon: const Icon(Icons.volume_up, size: 18),
                  label: const Text('播放语音'),
                  style: FilledButton.styleFrom(
                    backgroundColor: StudyPalette.ember,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _spellingCtrl,
            enabled: !_answered && !_saving,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 18),
            decoration: InputDecoration(
              hintText: '输入你听到的词语',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 14,
              ),
            ),
            onSubmitted: (_) => _onSpellingSubmit(),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed:
                (_answered || _saving || _spellingCtrl.text.trim().isEmpty)
                    ? null
                    : _onSpellingSubmit,
            icon: const Icon(Icons.check),
            label: const Text('确认'),
            style: FilledButton.styleFrom(
              backgroundColor: StudyPalette.moss,
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
            ),
          ),
          if (_answered) ...[
            const SizedBox(height: 16),
            Text(
              _lastCorrect ? '答对了！' : '答错了，正确答案是 ${item.text}',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: _lastCorrect ? StudyPalette.moss : Colors.red,
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ===== 结果栏 =====

  Widget _buildResultBar() {
    final canAdvance = !_saving;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: StudyPalette.parchmentDeep,
        border: Border(top: BorderSide(color: StudyPalette.linen, width: 1)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Icon(
                _lastCorrect ? Icons.check_circle : Icons.cancel,
                color: _lastCorrect ? StudyPalette.moss : Colors.red,
                size: 24,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _lastCorrect ? '太棒了，掌握了！' : '没关系，再复习一遍',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color:
                        _lastCorrect ? StudyPalette.moss : StudyPalette.ember,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: canAdvance ? _skip : null,
                  child: const Text('跳过'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: FilledButton.icon(
                  onPressed: canAdvance ? _next : null,
                  icon: const Icon(Icons.arrow_forward),
                  label: Text(_index + 1 >= _items.length ? '完成' : '下一题'),
                  style: FilledButton.styleFrom(
                    backgroundColor: StudyPalette.ember,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
