import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart' as perm;

import '../../core/debug/app_log.dart';
import '../../core/models/learning_record.dart';
import '../../core/storage/database.dart';
import '../../core/storage/learning_record_dao.dart';
import '../../core/theme/app_theme.dart';
import '../../services/asr_service.dart';
import '../../services/mastery_service.dart';
import '../../services/native_tts_service.dart';
import '../../services/tts_service.dart';
import '../../services/vosk_asr_service.dart';
import '../../widgets/model_panel.dart';
import '../follow/scoring.dart';

/// [v2.9.0] Sentence dictation page for the dictation module.
///
/// Two modes:
/// - [SentenceDictMode.wordJigsaw]: listen then tap word cards in order
/// - [SentenceDictMode.voiceDictation]: listen then speak for Vosk scoring
class SentenceDictationPage extends StatefulWidget {
  const SentenceDictationPage({
    super.key,
    required this.sentences,
    this.bookId,
  });

  final List<String> sentences;
  final String? bookId;

  @override
  State<SentenceDictationPage> createState() => _SentenceDictationPageState();
}

enum SentenceDictMode {
  wordJigsaw('拼字积木'),
  voiceDictation('语音默写');

  const SentenceDictMode(this.label);
  final String label;
}

class _SentenceDictationPageState extends State<SentenceDictationPage> {
  static const _tag = 'sent_dict';

  final TtsService _tts = NativeTtsService();
  final AsrService _asr = VoskAsrService();
  final _panelKey = GlobalKey<ModelPanelState>();

  SentenceDictMode _mode = SentenceDictMode.wordJigsaw;
  int _currentIndex = 0;
  int _correctCount = 0;
  bool _loading = true;
  bool _ttsPlaying = false;
  bool _operationBusy = false;
  bool _submitting = false;
  String _status = '准备中...';
  String? _recognized;

  late List<_WordCard> _wordCards;
  final List<String> _placedWords = [];
  int _playCount = 2;
  int _playsRemaining = 2;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final mode = await showDialog<SentenceDictMode>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('选择默写模式'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children:
                  SentenceDictMode.values.map((m) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        title: Text(
                          m.label,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          m == SentenceDictMode.wordJigsaw
                              ? '听句子 → 点击词语卡片按正确顺序排列'
                              : '听句子 → 跟读录音 → Vosk 自动评分',
                        ),
                        leading: Icon(
                          m == SentenceDictMode.wordJigsaw
                              ? Icons.grid_view
                              : Icons.record_voice_over,
                          color: StudyPalette.ember,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: const BorderSide(color: StudyPalette.linen),
                        ),
                        onTap: () => Navigator.of(ctx).pop(m),
                      ),
                    );
                  }).toList(),
            ),
          ),
    );
    if (mode == null || !mounted) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    _mode = mode;
    setState(() => _loading = false);
    _nextSentence();
  }

  String get _currentSentence => widget.sentences[_currentIndex];

  void _nextSentence() {
    if (_currentIndex >= widget.sentences.length) {
      _finish();
      return;
    }
    if (_mode == SentenceDictMode.wordJigsaw) {
      _initJigsaw();
    }
    _playsRemaining = _playCount;
    setState(() {
      _submitting = false;
      _recognized = null;
      _placedWords.clear();
      _status = '听句子，准备默写';
    });
    _playSentence();
  }

  void _initJigsaw() {
    final words = _splitWords(_currentSentence);
    _wordCards = List.generate(
      words.length,
      (i) => _WordCard(word: words[i], index: i),
    )..shuffle();
  }

  List<String> _splitWords(String s) {
    if (s.contains(' ')) {
      return s.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    }
    return s.split('').where((c) => c.trim().isNotEmpty).toList();
  }

  // ===== TTS =====

  Future<void> _playSentence() async {
    if (_ttsPlaying) return;
    await _tts.stop();
    setState(() {
      _ttsPlaying = true;
      _status = '播放中... (剩余 $_playsRemaining 次)';
    });
    await _tts.speak(_currentSentence);
    if (!mounted) return;
    _playsRemaining--;
    setState(() => _ttsPlaying = false);
    _status =
        _playsRemaining > 0
            ? '再听一次？($_playsRemaining 次剩余)'
            : (_mode == SentenceDictMode.wordJigsaw
                ? '点击词语卡片，按正确顺序排列'
                : '点击麦克风跟读默写');
  }

  // ===== Word Jigsaw =====

  void _onCardTap(int cardIndex) {
    if (_submitting || _ttsPlaying) return;
    final card = _wordCards[cardIndex];
    if (card.placed) return;
    final nextExpected = _placedWords.length;
    final correct = card.index == nextExpected;
    setState(() {
      card.placed = true;
      _placedWords.add(card.word);
      card.correct = correct;
    });
    if (correct && _placedWords.length == _wordCards.length) {
      _onCorrect();
    } else if (!correct) {
      _onWrong();
    }
  }

  void _resetJigsaw() {
    setState(() {
      for (final c in _wordCards) {
        c.placed = false;
        c.correct = false;
      }
      _placedWords.clear();
      _status = '再试一次，仔细听顺序';
    });
    _playSentence();
  }

  // ===== Voice Dictation =====

  Future<void> _startVoice() async {
    if (_ttsPlaying || _operationBusy || _submitting) return;
    final mic = await perm.Permission.microphone.request();
    if (!mic.isGranted) {
      _setStatus('麦克风权限被拒绝');
      return;
    }
    setState(() => _operationBusy = true);
    await _tts.stop();
    if (!(_panelKey.currentState?.isReady ?? false)) {
      _setStatus('请先加载语音模型');
      setState(() => _operationBusy = false);
      return;
    }
    if (!await _asr.start()) {
      _setStatus('启动录音失败');
      setState(() => _operationBusy = false);
      return;
    }
    _setStatus('录音中... 说完点停止');
  }

  Future<void> _stopVoice() async {
    if (!_operationBusy) return;
    setState(() => _submitting = true);
    try {
      final text = await _asr.stop();
      setState(() => _operationBusy = false);
      if (!mounted) return;
      _recognized = text;
      final score = FollowScorer.scoreFollow(_currentSentence, text);
      if (score.passed) {
        _onCorrect();
      } else {
        _onWrong();
      }
    } catch (e) {
      AppLog.e(_tag, '识别失败: $e');
      if (mounted) {
        setState(() {
          _operationBusy = false;
          _submitting = false;
        });
      }
      _setStatus('识别失败，请重试');
    }
  }

  // ===== Scoring & Persistence =====

  void _onCorrect() {
    _correctCount++;
    setState(() {
      _submitting = true;
      _status = '✓ 正确！';
    });
    _persist(true);
  }

  void _onWrong() {
    setState(() {
      _submitting = true;
      _status = '✗ 答错了';
    });
    _persist(false);
  }

  Future<void> _persist(bool correct) async {
    try {
      final db = await DatabaseProvider.database;
      await LearningRecordDao(db).insert(
        LearningRecord.create(
          type: LearningType.dictation,
          target: _currentSentence,
          result: correct ? 100.0 : 0.0,
          detail: jsonEncode({'mode': _mode.name, 'recognized': _recognized}),
        ),
      );
      if (!correct) {
        for (final w in _splitWords(_currentSentence)) {
          await MasteryService.applyWordResult(
            w,
            correct: false,
            bookId: widget.bookId,
          );
        }
      }
      AppLog.d(_tag, '默写 ${correct ? "✓" : "✗"}: $_currentSentence');
    } catch (e) {
      AppLog.e(_tag, '落库失败: $e');
    }
    if (!mounted) return;
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (!mounted) return;
      setState(() {
        _currentIndex++;
        _submitting = false;
      });
      _nextSentence();
    });
  }

  void _finish() {
    final total = widget.sentences.length;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder:
          (ctx) => AlertDialog(
            title: const Text('默写完成！'),
            content: Text(
              '共 $total 句\n'
              '正确 $_correctCount 句\n'
              '得分 ${total > 0 ? (_correctCount * 100 / total).round() : 0} 分',
              style: const TextStyle(fontSize: 18, height: 1.6),
              textAlign: TextAlign.center,
            ),
            actions: [
              FilledButton(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  Navigator.of(context).pop();
                },
                child: const Text('完成'),
              ),
            ],
          ),
    );
  }

  void _setStatus(String s) {
    if (mounted) setState(() => _status = s);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${_mode.label} · ${_currentIndex + 1} / ${widget.sentences.length}',
        ),
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
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            LinearProgressIndicator(
              value: (_currentIndex + 1) / widget.sentences.length,
              minHeight: 6,
              backgroundColor: StudyPalette.parchmentDeep,
              valueColor: const AlwaysStoppedAnimation<Color>(
                StudyPalette.ember,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _status,
              style: const TextStyle(fontSize: 13, color: StudyPalette.inkSoft),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),

            // Playback controls
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                DropdownButton<int>(
                  value: _playCount,
                  underline: const SizedBox(),
                  items:
                      [1, 2, 3]
                          .map(
                            (n) => DropdownMenuItem(
                              value: n,
                              child: Text(
                                '播放 $n 次',
                                style: const TextStyle(fontSize: 13),
                              ),
                            ),
                          )
                          .toList(),
                  onChanged:
                      _submitting || _ttsPlaying
                          ? null
                          : (v) {
                            if (v != null) setState(() => _playCount = v);
                          },
                ),
                const SizedBox(width: 16),
                IconButton(
                  icon: Icon(
                    _ttsPlaying ? Icons.volume_up : Icons.volume_up_outlined,
                    size: 40,
                    color: StudyPalette.ember,
                  ),
                  onPressed: _ttsPlaying || _submitting ? null : _playSentence,
                  tooltip: '播放句子',
                ),
              ],
            ),
            const SizedBox(height: 24),

            Expanded(child: _buildContent()),
          ],
        ),
      ),
    );
  }

  Widget _buildContent() {
    switch (_mode) {
      case SentenceDictMode.wordJigsaw:
        return _buildJigsawContent();
      case SentenceDictMode.voiceDictation:
        return _buildVoiceContent();
    }
  }

  Widget _buildJigsawContent() {
    return Column(
      children: [
        // Placed chips area
        if (_placedWords.isNotEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: StudyPalette.parchmentDeep.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: List.generate(_placedWords.length, (i) {
                final wordFound = _wordCards.firstWhere(
                  (c) => c.word == _placedWords[i],
                  orElse: () => _WordCard(word: _placedWords[i], index: 0),
                );
                return Chip(
                  label: Text(
                    _placedWords[i],
                    style: const TextStyle(fontSize: 16),
                  ),
                  backgroundColor:
                      wordFound.correct
                          ? StudyPalette.moss.withValues(alpha: 0.2)
                          : StudyPalette.ember.withValues(alpha: 0.2),
                  side: BorderSide.none,
                );
              }),
            ),
          ),
        const SizedBox(height: 16),

        // Word cards
        Expanded(
          child: Center(
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              alignment: WrapAlignment.center,
              children: List.generate(_wordCards.length, (i) {
                final card = _wordCards[i];
                if (card.placed) return const SizedBox.shrink();
                return GestureDetector(
                  onTap: () => _onCardTap(i),
                  child: Container(
                    width: 60,
                    height: 60,
                    decoration: BoxDecoration(
                      color: StudyPalette.surfaceWithAlpha(context, alpha: 0.9),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: StudyPalette.ember.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Center(
                      child: Text(
                        card.word,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: StudyPalette.ink,
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
        ),

        // Reset button
        if (_placedWords.isNotEmpty && _placedWords.length < _wordCards.length)
          TextButton.icon(
            onPressed: _submitting ? null : _resetJigsaw,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('重新排列'),
          ),
      ],
    );
  }

  Widget _buildVoiceContent() {
    return Column(
      children: [
        // Recognition result
        if (_recognized != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  const Text(
                    '你说的是：',
                    style: TextStyle(fontSize: 13, color: StudyPalette.inkSoft),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _recognized!,
                    style: const TextStyle(
                      fontSize: 18,
                      color: StudyPalette.ink,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),

        const Spacer(),

        // Mic button
        if (!_submitting)
          Column(
            children: [
              IconButton(
                icon: Icon(
                  _operationBusy ? Icons.stop_circle : Icons.mic,
                  size: 64,
                  color:
                      _operationBusy
                          ? StudyPalette.ember
                          : StudyPalette.spinePdf,
                ),
                onPressed:
                    _ttsPlaying
                        ? null
                        : (_operationBusy ? _stopVoice : _startVoice),
                tooltip: _operationBusy ? '停止录音' : '开始录音',
              ),
              const SizedBox(height: 8),
              Text(
                _operationBusy ? '点击停止' : '点击麦克风跟读默写',
                style: const TextStyle(
                  fontSize: 12,
                  color: StudyPalette.inkSoft,
                ),
              ),
            ],
          )
        else
          const Center(child: CircularProgressIndicator()),

        const Spacer(),

        // Model panel (collapsed)
        SizedBox(height: 80, child: ModelPanel(key: _panelKey, asr: _asr)),
      ],
    );
  }
}

class _WordCard {
  _WordCard({required this.word, required this.index});
  final String word;
  final int index;
  bool placed = false;
  bool correct = false;
}
