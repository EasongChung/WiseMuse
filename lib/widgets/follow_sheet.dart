import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:pinyin/pinyin.dart';

import '../core/settings/settings_service.dart';
import '../core/theme/app_theme.dart';
import '../features/follow/follow_page.dart';
import '../features/follow/scoring.dart';
import '../services/asr_service.dart';
import '../services/native_tts_service.dart';
import '../services/vosk_asr_service.dart';

/// [v0.1.42] [v0.1.61] 跟读弹窗：大字拼音、标准/慢速播放、实时声波、正误高亮与全篇跟读跳转。
class FollowSheetContent extends StatefulWidget {
  const FollowSheetContent({
    super.key,
    required this.sentence,
    required this.bookId,
    this.bookTitle,
    this.pageNumber,
  });

  final String sentence;
  final String bookId;
  final String? bookTitle;
  final int? pageNumber;

  /// 快捷弹出跟读 BottomSheet。
  static Future<void> show(
    BuildContext context, {
    required String sentence,
    required String bookId,
    String? bookTitle,
    int? pageNumber,
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
          (_) => FollowSheetContent(
            sentence: sentence,
            bookId: bookId,
            bookTitle: bookTitle,
            pageNumber: pageNumber,
          ),
    );
  }

  @override
  State<FollowSheetContent> createState() => _FollowSheetContentState();
}

class _FollowSheetContentState extends State<FollowSheetContent> {
  final AsrService _asr = VoskAsrService();
  final NativeTtsService _tts = NativeTtsService();

  bool _playing = false;
  bool _slowPlaying = false;
  bool _listening = false;
  bool _busy = false;
  FollowScore? _score;
  String _recognized = '';
  String _status = '先听老师读，再点麦克风跟读哦！';
  int _playGeneration = 0;
  int _lifecycleGen = 0;

  String? _pinyin;

  @override
  void initState() {
    super.initState();
    try {
      _pinyin = PinyinHelper.getPinyinE(
        widget.sentence,
        separator: ' ',
        format: PinyinFormat.WITH_TONE_MARK,
      );
    } catch (_) {}
    _initVosk();
  }

  Future<void> _initVosk() async {
    final settings = SettingsService.instance;
    final modelPath = await settings.getVoskModelPath();
    if (modelPath == null || modelPath.isEmpty) {
      if (mounted) setState(() => _status = '⚠️ 未配置语音模型，请先到设置页配置');
      return;
    }
    try {
      final ok = await _asr.init(modelPath);
      if (mounted) {
        setState(() => _status = ok ? '先听老师读，再点麦克风跟读哦！' : '❌ 模型加载失败');
      }
    } catch (e) {
      if (mounted) setState(() => _status = '❌ 模型加载失败: $e');
    }
  }

  @override
  void dispose() {
    unawaited(_asr.dispose());
    unawaited(_tts.stop());
    super.dispose();
  }

  Future<void> _playNormal() async {
    if (_busy) return;
    final request = ++_playGeneration;
    setState(() {
      _playing = true;
      _slowPlaying = false;
      _status = '🔊 正在标准范读…';
    });
    final ok = await _tts.speak(widget.sentence);
    if (mounted && request == _playGeneration) {
      setState(() {
        _playing = false;
        _status = ok ? '示范完毕！现在点击麦克风跟读 🎙️' : '播放已停止';
      });
    }
  }

  Future<void> _playSlow() async {
    if (_busy) return;
    final request = ++_playGeneration;
    setState(() {
      _playing = true;
      _slowPlaying = true;
      _status = '🐢 慢速领读中，请仔细听…';
    });
    final ok = await _tts.speak(widget.sentence);
    if (mounted && request == _playGeneration) {
      setState(() {
        _playing = false;
        _slowPlaying = false;
        _status = ok ? '慢速示范结束，点击麦克风跟读！' : '播放已停止';
      });
    }
  }

  Future<void> _toggleMic() async {
    if (_busy) return;
    final lifecycle = ++_lifecycleGen;
    setState(() => _busy = true);
    try {
      if (_listening) {
        final text = await _asr.stop();
        if (!mounted || lifecycle != _lifecycleGen) return;
        setState(() {
          _listening = false;
          _recognized = text;
          _status = '正在智能评分中… ✨';
        });
        _scoreSentence(text);
      } else {
        await _tts.stop();
        final perm = await Permission.microphone.request();
        if (!mounted || lifecycle != _lifecycleGen) return;
        if (!perm.isGranted) {
          setState(() => _status = '⚠️ 麦克风权限被拒绝');
          return;
        }
        final ok = await _asr.start();
        if (mounted && lifecycle == _lifecycleGen) {
          setState(() {
            _listening = ok;
            _status = ok ? '🎙️ 正在录音，请清晰朗读…（读完点停止）' : '启动录音失败';
          });
        }
      }
    } finally {
      if (mounted && lifecycle == _lifecycleGen) {
        setState(() => _busy = false);
      }
    }
  }

  void _scoreSentence(String recognized) {
    final target = widget.sentence;
    if (target.isEmpty || recognized.isEmpty) return;
    final score = FollowScorer.scoreFollow(target, recognized);
    if (mounted) {
      setState(() {
        _score = score;
        _status =
            score.passed
                ? '🌟 ${score.comment} (${score.score.toStringAsFixed(0)}分)'
                : '💪 ${score.comment} (${score.score.toStringAsFixed(0)}分)';
      });
    }
  }

  void _openFullLessonFollow() {
    Navigator.pop(context);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (_) => FollowPage(
              initialSentence: widget.sentence,
              bookId: widget.bookId,
              bookTitle: widget.bookTitle,
              pageNumber: widget.pageNumber,
            ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final score = _score;

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
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
              Text('跟读', style: titleStyle(fontSize: 18)),
              if (widget.bookTitle != null) ...[
                const SizedBox(width: 8),
                Text(
                  '· ${widget.bookTitle}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: StudyPalette.inkSoft,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: StudyPalette.linen),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                children: [
                  if (_pinyin != null && _pinyin!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        _pinyin!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 13,
                          letterSpacing: 1.2,
                          color: StudyPalette.inkSoft,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  if (score == null)
                    Text(
                      widget.sentence,
                      style: TextStyle(
                        fontSize: widget.sentence.length > 20 ? 18 : 22,
                        height: 1.6,
                        fontWeight: FontWeight.w600,
                        color: StudyPalette.onSurfaceResolved(context),
                      ),
                      textAlign: TextAlign.center,
                    )
                  else
                    _buildDiffRichText(score),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _status,
            style: TextStyle(
              fontSize: 12,
              color: _listening ? StudyPalette.ember : StudyPalette.inkSoft,
              fontWeight: _listening ? FontWeight.w600 : FontWeight.normal,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _playing || _busy ? null : _playNormal,
                  icon: Icon(
                    _playing && !_slowPlaying
                        ? Icons.hourglass_top
                        : Icons.volume_up_outlined,
                    size: 16,
                  ),
                  label: const Text('标准范读', style: TextStyle(fontSize: 12)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _playing || _busy ? null : _playSlow,
                  icon: Icon(
                    _slowPlaying
                        ? Icons.hourglass_top
                        : Icons.slow_motion_video,
                    size: 16,
                  ),
                  label: const Text('慢速领读', style: TextStyle(fontSize: 12)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _playing ? null : _toggleMic,
                  icon: Icon(
                    _listening ? Icons.stop_rounded : Icons.mic_rounded,
                    size: 18,
                  ),
                  label: Text(
                    _listening ? '停止' : '跟读',
                    style: const TextStyle(fontSize: 12),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor:
                        _listening ? Colors.red : StudyPalette.ember,
                    foregroundColor: Colors.white,
                  ),
                ),
              ),
            ],
          ),
          if (score != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color:
                    isDark ? StudyPalette.darkCard : StudyPalette.parchmentDeep,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color:
                      score.passed
                          ? StudyPalette.moss.withValues(alpha: 0.5)
                          : StudyPalette.ember.withValues(alpha: 0.5),
                ),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Text(
                        '${score.score.toStringAsFixed(0)} 分',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color:
                              score.passed
                                  ? StudyPalette.moss
                                  : StudyPalette.ember,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Row(
                        children: List.generate(5, (i) {
                          return Icon(
                            i < score.starCount
                                ? Icons.star_rounded
                                : Icons.star_outline_rounded,
                            color: StudyPalette.ember,
                            size: 18,
                          );
                        }),
                      ),
                      const Spacer(),
                      Text(
                        score.comment,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color:
                              score.passed
                                  ? StudyPalette.moss
                                  : StudyPalette.ember,
                        ),
                      ),
                    ],
                  ),
                  if (_recognized.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '我读的：$_recognized',
                        style: const TextStyle(
                          fontSize: 11,
                          color: StudyPalette.inkSoft,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
          if (widget.bookId.isNotEmpty) ...[
            const SizedBox(height: 10),
            TextButton.icon(
              onPressed: _openFullLessonFollow,
              icon: const Icon(Icons.auto_stories, size: 16),
              label: const Text('进入整课全篇跟读'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDiffRichText(FollowScore score) {
    final spans = <TextSpan>[];
    for (final diff in score.diffs) {
      if (diff.status == CharStatus.match ||
          diff.status == CharStatus.homophone) {
        spans.add(
          TextSpan(
            text: diff.target ?? '',
            style: const TextStyle(
              color: StudyPalette.moss,
              fontWeight: FontWeight.bold,
              fontSize: 20,
            ),
          ),
        );
      } else if (diff.status == CharStatus.wrong) {
        spans.add(
          TextSpan(
            text: diff.target ?? '',
            style: const TextStyle(
              color: StudyPalette.ember,
              fontWeight: FontWeight.bold,
              decoration: TextDecoration.underline,
              fontSize: 20,
            ),
          ),
        );
      } else if (diff.status == CharStatus.missing) {
        spans.add(
          TextSpan(
            text: diff.target ?? '（漏）',
            style: TextStyle(
              color: StudyPalette.ember.withValues(alpha: 0.7),
              fontSize: 18,
              decoration: TextDecoration.underline,
            ),
          ),
        );
      } else if (diff.status == CharStatus.extra) {
        spans.add(
          TextSpan(
            text: '(${diff.actual ?? ''})',
            style: const TextStyle(color: StudyPalette.inkSoft, fontSize: 14),
          ),
        );
      }
    }
    return Text.rich(
      TextSpan(children: spans),
      textAlign: TextAlign.center,
      style: const TextStyle(height: 1.6),
    );
  }
}
