import 'package:flutter/material.dart';

import '../core/debug/app_log.dart';
import '../core/models/word_entry.dart';
import '../core/theme/app_theme.dart';
import '../services/mastery_service.dart';

/// [v0.1.0] 复习卡片：逐个展示生词，点「掌握」增加 mastery。
///
/// 用法：
/// ```dart
/// Navigator.push(context, MaterialPageRoute(
///   builder: (_) => ReviewCard(words: words, onComplete: () => ...),
/// ));
/// ```
class ReviewCard extends StatefulWidget {
  const ReviewCard({super.key, required this.words, this.onComplete});

  final List<WordEntry> words;
  final VoidCallback? onComplete;

  @override
  State<ReviewCard> createState() => _ReviewCardState();
}

class _ReviewCardState extends State<ReviewCard> {
  static const _tag = 'review';

  int _index = 0;
  bool _saving = false;

  List<WordEntry> get _words => widget.words;

  void _markKnown() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final entry = _words[_index];
      await MasteryService.recordReview(entry);
      AppLog.d(_tag, '复习: ${entry.word} mastery=${entry.mastery}');
      _next();
    } catch (e) {
      AppLog.e(_tag, '复习保存失败: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
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
    setState(() => _index++);
  }

  @override
  Widget build(BuildContext context) {
    final entry = _words[_index];
    final progress = '${_index + 1} / ${_words.length}';

    return Scaffold(
      appBar: AppBar(
        title: Text('复习  ·  $progress'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () {
            widget.onComplete?.call();
            Navigator.of(context).pop();
          },
        ),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 进度条
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: (_index + 1) / _words.length,
                  minHeight: 6,
                  backgroundColor: StudyPalette.parchmentDeep,
                  valueColor: const AlwaysStoppedAnimation<Color>(
                    StudyPalette.ember,
                  ),
                ),
              ),
              const SizedBox(height: 48),

              // 词卡片
              Card(
                color: Colors.white.withValues(alpha: 0.85),
                elevation: 2,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 32,
                    vertical: 48,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        entry.word,
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w700,
                          color: StudyPalette.ink,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '掌握度 ${entry.mastery}/5  ·  已错 ${entry.wrongCount} 次',
                        style: const TextStyle(
                          fontSize: 14,
                          color: StudyPalette.inkSoft,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 40),

              // 操作按钮
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _saving ? null : _skip,
                      icon: const Icon(Icons.skip_next_outlined),
                      label: const Text('跳过'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        side: const BorderSide(color: StudyPalette.inkSoft),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _saving ? null : _markKnown,
                      icon:
                          _saving
                              ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                              : const Icon(Icons.check_circle_outline),
                      label: Text(_saving ? '保存中…' : '掌握了'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        backgroundColor: StudyPalette.moss,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
