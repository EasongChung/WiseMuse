import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/settings/settings_service.dart';
import '../core/theme/app_theme.dart';
import '../features/follow/scoring.dart';
import '../services/asr_service.dart';
import '../services/native_tts_service.dart';
import '../services/vosk_asr_service.dart';

/// [v0.1.42] 跟读弹窗：播放 → 录音 → 识别 → 评分。
///
/// 供阅读页和练习页复用，支持在 BottomSheet 内完成跟读闭环。
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
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: StudyPalette.parchment,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
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
  bool _listening = false;
  bool _busy = false;
  FollowScore? _score;
  String _recognized = '';
  String _status = '点击播放听句子';
  int _playGeneration = 0;
  int _lifecycleGen = 0;

  @override
  void initState() {
    super.initState();
    _initVosk();
  }

  Future<void> _initVosk() async {
    final settings = SettingsService.instance;
    final modelPath = await settings.getVoskModelPath();
    if (modelPath == null || modelPath.isEmpty) {
      if (mounted) setState(() => _status = '未配置语音模型，请先到设置页配置');
      return;
    }
    try {
      final ok = await _asr.init(modelPath);
      if (mounted) {
        setState(() => _status = ok ? '点击播放听句子' : '模型加载失败');
      }
    } catch (e) {
      if (mounted) setState(() => _status = '模型加载失败: $e');
    }
  }

  @override
  void dispose() {
    unawaited(_asr.dispose());
    super.dispose();
  }

  Future<void> _play() async {
    if (_busy) return;
    final request = ++_playGeneration;
    setState(() => _playing = true);
    final ok = await _tts.speak(widget.sentence);
    if (mounted && request == _playGeneration) {
      setState(() {
        _playing = false;
        _status = ok ? '点击麦克风录音跟读' : '播放失败';
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
          _status = '识别完成';
        });
        _scoreSentence(text);
      } else {
        final perm = await Permission.microphone.request();
        if (!mounted || lifecycle != _lifecycleGen) return;
        if (!perm.isGranted) {
          setState(() => _status = '麦克风权限被拒绝');
          return;
        }
        final ok = await _asr.start();
        if (mounted && lifecycle == _lifecycleGen) {
          setState(() {
            _listening = ok;
            _status = ok ? '录音中… 说完点停止' : '启动录音失败';
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
    if (mounted) setState(() => _score = score);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 32,
              height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: StudyPalette.linen,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Text(
            '跟读',
            style: titleStyle(fontSize: 18),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                widget.sentence,
                style: const TextStyle(
                  fontSize: 18,
                  height: 1.6,
                  color: StudyPalette.ink,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _playing || _busy ? null : _play,
                  icon: Icon(
                    _playing ? Icons.hourglass_top : Icons.volume_up,
                    size: 18,
                  ),
                  label: Text(
                    _playing ? '播放中' : '播放',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _playing || _busy ? null : _toggleMic,
                  icon: Icon(_listening ? Icons.stop : Icons.mic, size: 18),
                  label: Text(
                    _listening ? '停止' : '跟读',
                    style: const TextStyle(fontSize: 13),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor:
                        _listening ? StudyPalette.spinePdf : StudyPalette.ember,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _status,
            style: const TextStyle(fontSize: 12, color: StudyPalette.inkSoft),
            textAlign: TextAlign.center,
          ),
          if (_score != null) ...[
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Text(
                          '${_score!.score.toStringAsFixed(0)} 分',
                          style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                            color:
                                _score!.passed
                                    ? StudyPalette.moss
                                    : StudyPalette.ember,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          _score!.comment,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color:
                                _score!.passed
                                    ? StudyPalette.moss
                                    : StudyPalette.ember,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '识别：$_recognized',
                      style: const TextStyle(
                        fontSize: 12,
                        color: StudyPalette.inkSoft,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
