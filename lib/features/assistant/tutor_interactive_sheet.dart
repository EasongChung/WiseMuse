import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../services/ai_tutor_service.dart';
import '../../services/hybrid_tts_service.dart';
import '../../widgets/top_toast.dart';

/// [v0.1.62] 角色化交互式 AI 助教辅导弹窗：多维启发讲解 + 趣味例句 + 思考追问 + 变式练习。
class TutorInteractiveSheet extends StatefulWidget {
  const TutorInteractiveSheet({
    super.key,
    required this.target,
    this.contextSnippet,
  });

  final String target;
  final String? contextSnippet;

  static Future<void> show(
    BuildContext context,
    String target, {
    String? contextSnippet,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: isDark ? StudyPalette.darkCard : StudyPalette.parchment,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder:
          (_) => TutorInteractiveSheet(
            target: target,
            contextSnippet: contextSnippet,
          ),
    );
  }

  @override
  State<TutorInteractiveSheet> createState() => _TutorInteractiveSheetState();
}

class _TutorInteractiveSheetState extends State<TutorInteractiveSheet> {
  final AiTutorService _tutor = AiTutorService.instance;
  final HybridTtsService _tts = HybridTtsService.instance;

  TutorExplanation? _explanation;
  TutorChallenge? _challenge;
  bool _loading = true;
  bool _loadingChallenge = false;
  bool _reading = false;

  // 变式挑战答题状态
  String? _selectedOption;
  bool? _isCorrect;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void dispose() {
    unawaited(_tts.stop());
    super.dispose();
  }

  Future<void> _fetch() async {
    final exp = await _tutor.explainStructured(
      widget.target,
      context: widget.contextSnippet,
    );
    if (!mounted) return;
    setState(() {
      _explanation = exp;
      _loading = false;
    });
  }

  Future<void> _loadChallenge() async {
    if (_challenge != null || _loadingChallenge) return;
    setState(() => _loadingChallenge = true);
    final ch = await _tutor.generateSimilarChallenge(widget.target);
    if (!mounted) return;
    setState(() {
      _challenge = ch;
      _loadingChallenge = false;
    });
  }

  Future<void> _readAloud(String text) async {
    setState(() => _reading = true);
    final ok = await _tts.speak(text);
    if (mounted) setState(() => _reading = false);
    if (!ok && mounted) {
      TopToast.show(context, '朗读失败');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final exp = _explanation;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
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
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: StudyPalette.emberSoft,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.auto_awesome,
                  color: StudyPalette.ember,
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('AI 伴学助教讲评', style: titleStyle(fontSize: 16)),
                    Text(
                      '重点字词：${widget.target}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: StudyPalette.inkSoft,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(
                  _reading ? Icons.hourglass_top : Icons.volume_up_outlined,
                  color: StudyPalette.ember,
                ),
                tooltip: '朗读助教讲评',
                onPressed:
                    exp == null
                        ? null
                        : () => _readAloud('${exp.meaning}。${exp.example}'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(height: 1),
          const SizedBox(height: 12),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Column(
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 12),
                    Text(
                      '助教正在为你准备生动讲解… ✨',
                      style: TextStyle(color: StudyPalette.inkSoft),
                    ),
                  ],
                ),
              ),
            )
          else if (exp == null)
            const Center(child: Text('生成讲解失败，请稍后重试'))
          else
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 1. 生动释义卡片
                    _buildSectionCard(
                      icon: Icons.menu_book,
                      iconColor: StudyPalette.ember,
                      title: '生动释义',
                      content: exp.meaning,
                      isDark: isDark,
                    ),
                    const SizedBox(height: 10),

                    // 2. 生活小场景
                    _buildSectionCard(
                      icon: Icons.lightbulb_outline,
                      iconColor: StudyPalette.moss,
                      title: '生活小场景',
                      content: exp.example,
                      isDark: isDark,
                    ),
                    const SizedBox(height: 10),

                    // 3. 启发小追问
                    _buildSectionCard(
                      icon: Icons.psychology_outlined,
                      iconColor: StudyPalette.spinePdf,
                      title: '想一想 (启发思考)',
                      content: exp.question,
                      isDark: isDark,
                    ),
                    const SizedBox(height: 14),

                    // 4. 变式小挑战
                    if (_challenge == null && !_loadingChallenge)
                      FilledButton.tonalIcon(
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onPressed: _loadChallenge,
                        icon: const Icon(Icons.quiz_outlined, size: 18),
                        label: const Text('🎯 变式小挑战：做一道巩固题'),
                      )
                    else if (_loadingChallenge)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.all(12),
                          child: Text(
                            '助教正在出题中…',
                            style: TextStyle(
                              fontSize: 12,
                              color: StudyPalette.inkSoft,
                            ),
                          ),
                        ),
                      )
                    else
                      _buildChallengeSection(_challenge!, isDark),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSectionCard({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String content,
    required bool isDark,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? StudyPalette.darkCard : StudyPalette.parchmentDeep,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: StudyPalette.linen),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: iconColor),
              const SizedBox(width: 6),
              Text(title, style: titleStyle(fontSize: 13)),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            content,
            style: const TextStyle(
              fontSize: 13,
              height: 1.5,
              color: StudyPalette.ink,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChallengeSection(TutorChallenge ch, bool isDark) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? StudyPalette.darkCard : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: StudyPalette.emberSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.stars, color: StudyPalette.ember, size: 18),
              const SizedBox(width: 6),
              Text('巩固练习题', style: titleStyle(fontSize: 14)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            ch.question,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          ...ch.options.map((opt) {
            final isSelected = _selectedOption == opt;
            final isCorrectOpt = opt == ch.correctAnswer;
            Color btnColor = StudyPalette.linen;
            if (_selectedOption != null) {
              if (isCorrectOpt) {
                btnColor = StudyPalette.moss;
              } else if (isSelected) {
                btnColor = StudyPalette.ember;
              }
            }

            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap:
                    _selectedOption == null
                        ? () {
                          setState(() {
                            _selectedOption = opt;
                            _isCorrect = isCorrectOpt;
                          });
                        }
                        : null,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color:
                        _selectedOption != null && (isCorrectOpt || isSelected)
                            ? btnColor.withValues(alpha: 0.15)
                            : (isDark
                                ? StudyPalette.darkBorder
                                : StudyPalette.parchmentDeep),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color:
                          _selectedOption != null &&
                                  (isCorrectOpt || isSelected)
                              ? btnColor
                              : StudyPalette.linen,
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          opt,
                          style: TextStyle(
                            fontSize: 13,
                            color:
                                _selectedOption != null &&
                                        (isCorrectOpt || isSelected)
                                    ? btnColor
                                    : StudyPalette.ink,
                            fontWeight:
                                isSelected
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                          ),
                        ),
                      ),
                      if (_selectedOption != null && isCorrectOpt)
                        const Icon(
                          Icons.check_circle,
                          color: StudyPalette.moss,
                          size: 18,
                        ),
                      if (_selectedOption != null &&
                          isSelected &&
                          !isCorrectOpt)
                        const Icon(
                          Icons.cancel,
                          color: StudyPalette.ember,
                          size: 18,
                        ),
                    ],
                  ),
                ),
              ),
            );
          }),
          if (_selectedOption != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color:
                    (_isCorrect ?? false)
                        ? StudyPalette.moss.withValues(alpha: 0.1)
                        : StudyPalette.ember.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                (_isCorrect ?? false)
                    ? '🎉 答对啦！${ch.explanation}'
                    : '💡 答错了哦。${ch.explanation}',
                style: TextStyle(
                  fontSize: 12,
                  color:
                      (_isCorrect ?? false)
                          ? StudyPalette.moss
                          : StudyPalette.ember,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
