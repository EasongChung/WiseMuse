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

/// [v0.1.35] 复习卡片：形态流转与掌握度更新。
/// [v0.1.66] [v0.1.67] 重构为儿童友好交互：听写模式（大字+小喇叭+已掌握/未掌握按钮）与选择题。
///
/// - [ReviewMode.dictation]：听写模式（大字显示、语音播放、直接自评掌握状态）
/// - [ReviewMode.choice]：选择题辨析（不暴露答案，语义/听音选词）
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
  dictation('听写'),
  choice('选择题');

  const ReviewMode(this.label);
  final String label;
}

class _ReviewCardState extends State<ReviewCard> {
  static const _tag = 'review';

  final HybridTtsService _tts = HybridTtsService.instance;

  late final List<ReviewItem> _items;
  int _index = 0;
  ReviewMode _mode = ReviewMode.dictation;
  bool _answered = false;
  bool _lastCorrect = false;
  String? _selectedChoice;
  List<String> _options = [];
  bool _saving = false;
  String? _saveError;
  bool _dictationPlaying = false;

  @override
  void initState() {
    super.initState();
    _items =
        widget.items ?? widget.words.map(ReviewItem.fromWordEntry).toList();
    _mode = widget.initialMode ?? ReviewMode.dictation;
    if (_items.isNotEmpty) {
      _prepareChoice();
      _autoPlayIfDictation();
    }
  }

  @override
  void dispose() {
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

  void _autoPlayIfDictation() {
    if (_mode == ReviewMode.dictation && _current != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _mode == ReviewMode.dictation) {
          _playDictation();
        }
      });
    }
  }

  // ===== 状态推进 =====

  void _resetForCurrent() {
    setState(() {
      _answered = false;
      _lastCorrect = false;
      _selectedChoice = null;
      _saveError = null;
      _dictationPlaying = false;
    });
    _prepareChoice();
    _autoPlayIfDictation();
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
      _answered = false;
      _lastCorrect = false;
      _selectedChoice = null;
      _saveError = null;
      _dictationPlaying = false;
    });
    _prepareChoice();
    _autoPlayIfDictation();
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

  Future<void> _playDictation() async {
    final current = _current;
    if (current == null || _dictationPlaying) return;
    setState(() => _dictationPlaying = true);
    try {
      await _tts.speak(current.text);
    } catch (e) {
      AppLog.e(_tag, '听写 TTS 播放失败: $e');
      if (mounted) {
        TopToast.show(context, '语音播放失败，请检查 TTS 配置');
      }
    } finally {
      if (mounted) setState(() => _dictationPlaying = false);
    }
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
      case ReviewMode.dictation:
        return _buildDictation(item);
      case ReviewMode.choice:
        return _buildChoice(item);
    }
  }

  // ===== 听写模式（参照练习中的听写：大字展示 + 小喇叭 + 已掌握/未掌握按钮） =====

  Widget _buildDictation(ReviewItem item) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          // 1. 当前词语（大字显示，上移设计）
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
            decoration: BoxDecoration(
              color: StudyPalette.parchmentDeep.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: StudyPalette.ember.withValues(alpha: 0.35),
                width: 2,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  item.text,
                  style: const TextStyle(
                    fontSize: 40,
                    fontWeight: FontWeight.w700,
                    color: StudyPalette.ink,
                  ),
                  textAlign: TextAlign.center,
                ),
                if (item.definition != null && item.definition!.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    item.definition!,
                    style: const TextStyle(
                      fontSize: 14,
                      color: StudyPalette.inkSoft,
                      height: 1.4,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 2. 小喇叭（播放 / 再听一遍）
          IconButton(
            icon: Icon(
              _dictationPlaying ? Icons.volume_up : Icons.volume_up_outlined,
              size: 42,
              color: StudyPalette.ember,
            ),
            onPressed: _dictationPlaying ? null : _playDictation,
            tooltip: '再听一遍',
          ),
          const SizedBox(height: 20),

          // 3. 腾出一行2个按钮的位置：‘未掌握’‘已掌握’
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(
                    Icons.close,
                    size: 20,
                    color: StudyPalette.ember,
                  ),
                  label: const Text(
                    '未掌握',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: StudyPalette.ember,
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    side: const BorderSide(
                      color: StudyPalette.ember,
                      width: 1.5,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed:
                      _answered || _saving
                          ? null
                          : () => _submit(correct: false),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: FilledButton.icon(
                  icon: const Icon(Icons.check, size: 20, color: Colors.white),
                  label: const Text(
                    '已掌握',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: StudyPalette.moss,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed:
                      _answered || _saving
                          ? null
                          : () => _submit(correct: true),
                ),
              ),
            ],
          ),

          if (_answered) ...[
            const SizedBox(height: 16),
            Text(
              _lastCorrect ? '太棒了，已掌握！' : '已记录未掌握，稍后继续复习',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: _lastCorrect ? StudyPalette.moss : StudyPalette.ember,
              ),
            ),
          ],
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
                  const Icon(
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
                    onPressed: _dictationPlaying ? null : _playDictation,
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

  // ===== 结果栏 =====

  Widget _buildResultBar() {
    final canAdvance = !_saving;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: const BoxDecoration(
        color: StudyPalette.parchmentDeep,
        border: Border(top: BorderSide(color: StudyPalette.linen, width: 1)),
      ),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: canAdvance ? _skip : null,
              child: const Text('跳过'),
            ),
          ),
          const SizedBox(width: 16),
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
    );
  }
}
