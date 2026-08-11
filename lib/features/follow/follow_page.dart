import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/debug/app_log.dart';
import '../../core/models/learning_record.dart';
import '../../core/models/word_entry.dart';
import '../../core/storage/database.dart';
import '../../core/storage/learning_record_dao.dart';
import '../../core/storage/word_entry_dao.dart';
import '../../services/asr_service.dart';
import '../../services/native_tts_service.dart';
import '../../services/tts_service.dart';
import '../../services/vosk_asr_service.dart';
import '../../widgets/model_panel.dart';
import '../debug/log_page.dart';
import 'asr_demo_page.dart';
import 'scoring.dart';

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

class _FollowPageState extends State<FollowPage> {
  static const _tag = 'follow';

  final AsrService _asr = VoskAsrService();
  final TtsService _tts = NativeTtsService();
  final _panelKey = GlobalKey<ModelPanelState>();
  final _sentenceController = TextEditingController();

  bool _listening = false;
  final bool _busy = false;
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
    _sentenceController.text = _sampleSentences.first;
  }

  @override
  void dispose() {
    _sentenceController.dispose();
    super.dispose();
  }

  /// 播放当前句子。
  Future<void> _play() async {
    final text = _sentenceController.text.trim();
    if (text.isEmpty) {
      _setStatus('请先输入要跟读的句子');
      return;
    }
    AppLog.d(_tag, '播放: "$text"');
    setState(() => _status = '播放中…');
    final ttsReady = await _tts.init();
    if (!ttsReady) {
      _setStatus('语音引擎不可用（设备可能缺中文语音包）');
      return;
    }
    final ok = await _tts.speak(text);
    if (!mounted) return;
    _setStatus(ok ? '播放完成，点麦克风跟读' : '播放失败或中断');
  }

  Future<void> _toggleListen() async {
    if (_listening) {
      AppLog.d(_tag, '停止录音');
      final text = await _asr.stop();
      AppLog.d(_tag, '识别结果: "$text"');
      if (!mounted) return;
      setState(() {
        _listening = false;
        _recognized = text;
        _status = '识别完成';
      });
      await _scoreAndPersist(text);
    } else {
      final perm = await Permission.microphone.request();
      if (!perm.isGranted) {
        _setStatus('麦克风权限被拒绝');
        return;
      }
      AppLog.d(_tag, '开始录音');
      final ok = await _asr.start();
      if (!mounted) return;
      setState(() {
        _listening = ok;
        _status = ok ? '录音中… 说完点停止' : '启动录音失败';
      });
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

  void _openLog() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const LogPage()));
  }

  void _openDemo() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const AsrDemoPage()));
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
                  onPressed: () {
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
                  onPressed: canPractice && !_busy ? _play : null,
                  icon: const Icon(Icons.volume_up),
                  label: const Text('播放'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: canPractice && !_busy ? _toggleListen : null,
                  icon: Icon(_listening ? Icons.stop : Icons.mic),
                  label: Text(_listening ? '停止' : '跟读'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Center(child: Text(_status, style: const TextStyle(fontSize: 12))),
          const SizedBox(height: 16),
          if (_lastScore != null) ..._buildScoreCard(),
        ],
      ),
    );
  }

  List<Widget> _buildScoreCard() {
    final s = _lastScore!;
    final color = s.passed ? Colors.green : Colors.orange;
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    '${s.score.toStringAsFixed(0)} 分',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: color,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      s.passed ? '读得很好，继续加油！' : '有读错的，跟着再读一遍吧',
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text('你说的是：$_recognized', style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 8),
              Text.rich(_buildDiffSpans()),
            ],
          ),
        ),
      ),
    ];
  }

  /// 逐字标色：对=绿 / 同音=蓝 / 错=红 / 漏=灰划线 / 多=橙划线。
  InlineSpan _buildDiffSpans() {
    final spans = <InlineSpan>[];
    for (final d in _lastScore!.diffs) {
      switch (d.status) {
        case CharStatus.match:
          spans.add(
            TextSpan(
              text: d.target,
              style: const TextStyle(
                color: Colors.green,
                fontWeight: FontWeight.bold,
              ),
            ),
          );
        case CharStatus.homophone:
          spans.add(
            TextSpan(
              text: d.target,
              style: const TextStyle(
                color: Colors.blue,
                decoration: TextDecoration.underline,
              ),
            ),
          );
        case CharStatus.wrong:
          spans.add(
            TextSpan(
              text: '${d.target}(${d.actual})',
              style: const TextStyle(
                color: Colors.red,
                fontWeight: FontWeight.bold,
              ),
            ),
          );
        case CharStatus.missing:
          spans.add(
            TextSpan(
              text: d.target ?? '',
              style: const TextStyle(
                color: Colors.grey,
                decoration: TextDecoration.lineThrough,
              ),
            ),
          );
        case CharStatus.extra:
          spans.add(
            TextSpan(
              text: '＋${d.actual}',
              style: const TextStyle(
                color: Colors.orange,
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
