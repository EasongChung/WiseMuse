import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/debug/app_log.dart';
import '../../core/models/learning_record.dart';
import '../../core/models/word_entry.dart';
import '../../core/storage/database.dart';
import '../../core/storage/learning_record_dao.dart';
import '../../core/storage/word_entry_dao.dart';
import '../../core/theme/app_theme.dart';
import '../../services/asr_service.dart';
import '../../services/native_tts_service.dart';
import '../../services/tts_service.dart';
import '../../services/vosk_asr_service.dart';
import '../../widgets/model_panel.dart';
import '../debug/log_page.dart';
import 'asr_demo_page.dart';
import 'scoring.dart';
import '../debug/llm_demo_page.dart';

/// [v0.1.0] 跟读练习页（核心链路：放音 → 录音 → 识别 → 评分 → 生词落库）。
///
/// 流程：
/// 1. 通过 [ModelPanel] 加载 Vosk 模型
/// 2. 输入/选例句 → 「播放」TTS 放音
/// 3. 「开始录音/停止」→ Vosk 识别
/// 4. 自动评分（[FollowScorer]），逐字标色反馈
/// 5. 分 <80 时整句写入生词本 + 学习记录
class FollowPage extends StatefulWidget {
  const FollowPage({super.key});

  @override
  State<FollowPage> createState() => _FollowPageState();
}

class _FollowPageState extends State<FollowPage> with WidgetsBindingObserver {
  static const _tag = 'follow';

  final AsrService _asr = VoskAsrService();
  final TtsService _tts = NativeTtsService();
  final _panelKey = GlobalKey<ModelPanelState>();
  final _sentenceController = TextEditingController();

  bool _listening = false;
  bool _playing = false;
  bool _operationBusy = false;
  bool _navigating = false;
  bool _appActive = true;
  int _playRequest = 0;
  int _lifecycleRequest = 0;
  FollowScore? _lastScore;
  String _recognized = '';
  String _status = '选择句子，点播放跟读';

  static const List<String> _sampleSentences = [
    '今天天气真好',
    '我喜欢读书',
    '小猫在草地上玩耍',
    '妈妈做的饭真香',
    '我们一起上学去',
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sentenceController.text = _sampleSentences.first;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final nextActive = state == AppLifecycleState.resumed;
    if (nextActive == _appActive) return;
    _appActive = nextActive;
    if (!_appActive) {
      final request = ++_lifecycleRequest;
      _playRequest++;
      setState(() => _operationBusy = true);
      unawaited(_suspendPractice(request));
    }
  }

  Future<void> _suspendPractice(int request) async {
    final ttsStopped = await _tts.stop();
    if (_listening) {
      try {
        await _asr.stop();
      } catch (e) {
        AppLog.w(_tag, '后台切换时停止录音失败: $e');
      }
    }
    if (!mounted || request != _lifecycleRequest) return;
    setState(() {
      _playing = false;
      _listening = false;
      _operationBusy = false;
      _status =
          ttsStopped
              ? (_appActive ? '语音已停止，可继续练习' : '已暂停，返回应用后可继续')
              : '语音停止失败，请重新进入页面';
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _appActive = false;
    _lifecycleRequest++;
    _playRequest++;
    unawaited(_tts.stop());
    unawaited(_disposeAsr());
    _sentenceController.dispose();
    super.dispose();
  }

  /// 播放当前句子。Future 直到系统 TTS 真正 onDone 后才完成。
  Future<void> _play() async {
    if (!_appActive ||
        _playing ||
        _listening ||
        _operationBusy ||
        _navigating) {
      return;
    }
    final text = _sentenceController.text.trim();
    if (text.isEmpty) {
      _setStatus('请先输入要跟读的句子');
      return;
    }

    final request = ++_playRequest;
    AppLog.d(_tag, '播放: "$text"');
    setState(() {
      _playing = true;
      _status = '播放中…';
    });

    final ttsReady = await _tts.init();
    if (!mounted || request != _playRequest) return;
    if (!ttsReady) {
      AppLog.w(_tag, 'TTS 初始化失败');
      setState(() {
        _playing = false;
        _status = '朗读失败：语音引擎不可用';
      });
      return;
    }

    final ok = await _tts.speak(text);
    if (!mounted || request != _playRequest) return;
    setState(() {
      _playing = false;
      _status = ok ? '播放完成，点麦克风跟读' : '朗读已停止或失败';
    });
    if (!ok) AppLog.w(_tag, 'TTS speak 未正常完成');
  }

  bool _isLifecycleCurrent(int request) {
    return mounted && _appActive && request == _lifecycleRequest;
  }

  Future<void> _toggleListen() async {
    if (!_appActive || _playing || _operationBusy || _navigating) return;
    final lifecycleRequest = _lifecycleRequest;
    setState(() => _operationBusy = true);
    try {
      if (_listening) {
        AppLog.d(_tag, '停止录音');
        // 先同步状态，避免生命周期回调对同一录音并发 stop。
        setState(() => _listening = false);
        final text = await _asr.stop();
        AppLog.d(_tag, '识别结果: "$text"');
        if (!_isLifecycleCurrent(lifecycleRequest)) return;
        setState(() {
          _recognized = text;
          _status = '识别完成';
        });
        await _scoreAndPersist(text);
      } else {
        // 防御性停止 TTS：只有取消屏障明确成立后才允许启动录音，避免
        // 扬声器内容被 Vosk 录入并污染跟读评分。
        _playRequest++;
        final ttsStopped = await _tts.stop();
        if (!_isLifecycleCurrent(lifecycleRequest)) return;
        if (!ttsStopped) {
          _setStatus('无法停止朗读，请重新进入页面后再试');
          return;
        }

        final perm = await Permission.microphone.request();
        if (!_isLifecycleCurrent(lifecycleRequest)) return;
        if (!perm.isGranted) {
          _setStatus('麦克风权限被拒绝');
          return;
        }
        AppLog.d(_tag, '开始录音');
        final ok = await _asr.start();
        if (!_isLifecycleCurrent(lifecycleRequest)) {
          if (ok) {
            try {
              await _asr.stop();
            } catch (e) {
              AppLog.w(_tag, '页面失活后回收录音失败: $e');
            }
          }
          return;
        }
        setState(() {
          _listening = ok;
          _status = ok ? '录音中… 说完点停止' : '启动录音失败';
        });
      }
    } finally {
      if (mounted && lifecycleRequest == _lifecycleRequest) {
        setState(() => _operationBusy = false);
      }
    }
  }

  Future<void> _scoreAndPersist(String recognized) async {
    final target = _sentenceController.text.trim();
    if (target.isEmpty) return;
    final score = FollowScorer.scoreFollow(target, recognized);
    if (!mounted) return;
    setState(() => _lastScore = score);

    if (!score.passed) {
      AppLog.d(_tag, '分=${score.score}，写入生词本');
      try {
        await _persistWord(target);
        await _persistRecord(target, recognized, score);
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已加入生词本，稍后可复习')));
      } catch (e, s) {
        AppLog.e(_tag, '落库失败: $e\n$s');
      }
    } else {
      AppLog.d(_tag, '分=${score.score}，通过');
    }
  }

  /// 读错句子写入生词本（同句重复失败累加 wrongCount）。
  Future<void> _persistWord(String target) async {
    final db = await DatabaseProvider.database;
    final dao = WordEntryDao(db);
    final existing = await dao.findByWord(target, lang: 'zh');
    if (existing != null) {
      existing.wrongCount++;
      existing.lastReviewAt = DateTime.now().microsecondsSinceEpoch;
      await dao.update(existing);
    } else {
      await dao.upsert(WordEntry.create(word: target, lang: 'zh'));
    }
  }

  Future<void> _persistRecord(
    String target,
    String recognized,
    FollowScore score,
  ) async {
    final db = await DatabaseProvider.database;
    await LearningRecordDao(db).insert(
      LearningRecord.create(
        type: LearningType.follow,
        target: target,
        result: score.score,
        detail: jsonEncode({'recognized': recognized, 'score': score.toJson()}),
      ),
    );
  }

  void _setStatus(String s) {
    if (!mounted) return;
    setState(() => _status = s);
  }

  Future<void> _openLog() => _openPage(const LogPage());

  Future<void> _openDemo() => _openPage(const AsrDemoPage());

  Future<void> _openLlmDemo() => _openPage(const LlmDemoPage());

  Future<void> _openPage(Widget page) async {
    if (!_appActive || _listening || _operationBusy || _navigating) return;
    final lifecycleRequest = _lifecycleRequest;
    final navigator = Navigator.of(context);
    setState(() => _navigating = true);
    try {
      _playRequest++;
      final stopped = await _tts.stop();
      if (!_isLifecycleCurrent(lifecycleRequest)) return;
      if (!stopped) {
        _setStatus('无法停止朗读，暂不能切换页面');
        return;
      }
      setState(() => _playing = false);
      await navigator.push(MaterialPageRoute<void>(builder: (_) => page));
    } finally {
      if (mounted) setState(() => _navigating = false);
    }
  }

  Future<void> _disposeAsr() async {
    try {
      await _asr.dispose();
    } catch (e) {
      AppLog.w(_tag, 'ASR dispose 失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final canPractice = _panelKey.currentState?.isReady ?? false;
    return Scaffold(
      appBar: AppBar(
        title: const Text('跟读练习'),
        actions: [
          IconButton(
            tooltip: 'Vosk PoC 调试页',
            icon: const Icon(Icons.science_outlined),
            onPressed: _openDemo,
          ),
          IconButton(
            tooltip: '本地 AI 引擎 PoC',
            icon: const Icon(Icons.psychology_outlined),
            onPressed: _openLlmDemo,
          ),
          IconButton(
            tooltip: '运行日志',
            icon: const Icon(Icons.bug_report_outlined),
            onPressed: _openLog,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ModelPanel(key: _panelKey, asr: _asr),
          const SizedBox(height: 16),
          TextField(
            controller: _sentenceController,
            enabled: !_playing && !_listening && !_operationBusy,
            decoration: const InputDecoration(
              labelText: '跟读句子',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final s in _sampleSentences)
                ActionChip(
                  label: Text(s, style: const TextStyle(fontSize: 12)),
                  onPressed:
                      _playing || _listening || _operationBusy
                          ? null
                          : () {
                            _sentenceController.text = s;
                            setState(() => _lastScore = null);
                          },
                ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed:
                      canPractice && !_playing && !_listening && !_operationBusy
                          ? _play
                          : null,
                  icon: const Icon(Icons.volume_up),
                  label: Text(_playing ? '播放中…' : '播放'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed:
                      canPractice && !_playing && !_operationBusy
                          ? _toggleListen
                          : null,
                  icon: Icon(_listening ? Icons.stop : Icons.mic),
                  label: Text(_listening ? '停止' : '跟读'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              _status,
              style: const TextStyle(fontSize: 12, color: StudyPalette.inkSoft),
            ),
          ),
          const SizedBox(height: 16),
          if (_lastScore != null) ..._buildScoreCard(),
        ],
      ),
    );
  }

  List<Widget> _buildScoreCard() {
    final s = _lastScore!;
    final color = s.passed ? StudyPalette.moss : StudyPalette.ember;
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    '${s.score.toStringAsFixed(0)} 分',
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      color: color,
                      fontFamily: 'ZCOOLKuaiLe',
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      s.passed ? '读得很好，继续加油！' : '有读错的，跟着再读一遍吧',
                      style: const TextStyle(
                        fontSize: 14,
                        color: StudyPalette.ink,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                '你说的是：$_recognized',
                style: const TextStyle(
                  fontSize: 13,
                  color: StudyPalette.inkSoft,
                ),
              ),
              const SizedBox(height: 10),
              Text.rich(_buildDiffSpans()),
            ],
          ),
        ),
      ),
    ];
  }

  /// 逐字标色：对=苔绿 / 同音=靛蓝 / 错=砖红 / 漏=暖灰划线 / 多=橙划线。
  InlineSpan _buildDiffSpans() {
    final spans = <InlineSpan>[];
    for (final d in _lastScore!.diffs) {
      switch (d.status) {
        case CharStatus.match:
          spans.add(
            TextSpan(
              text: d.target,
              style: const TextStyle(
                color: StudyPalette.moss,
                fontWeight: FontWeight.bold,
              ),
            ),
          );
        case CharStatus.homophone:
          spans.add(
            TextSpan(
              text: d.target,
              style: const TextStyle(
                color: StudyPalette.spinePdf,
                decoration: TextDecoration.underline,
              ),
            ),
          );
        case CharStatus.wrong:
          spans.add(
            TextSpan(
              text: '${d.target}(${d.actual})',
              style: const TextStyle(
                color: Color(0xFFB6482E),
                fontWeight: FontWeight.bold,
              ),
            ),
          );
        case CharStatus.missing:
          spans.add(
            TextSpan(
              text: d.target ?? '',
              style: const TextStyle(
                color: StudyPalette.inkSoft,
                decoration: TextDecoration.lineThrough,
              ),
            ),
          );
        case CharStatus.extra:
          spans.add(
            TextSpan(
              text: '＋${d.actual}',
              style: const TextStyle(
                color: StudyPalette.ember,
                decoration: TextDecoration.lineThrough,
              ),
            ),
          );
      }
    }
    return TextSpan(
      style: const TextStyle(fontSize: 20, height: 1.4),
      children: spans,
    );
  }
}
