import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/debug/app_log.dart';
import '../../core/models/knowledge_point.dart';
import '../../core/models/learning_record.dart';
import '../../core/models/sentence.dart';
import '../../core/models/word_entry.dart';
import '../../core/settings/settings_service.dart';
import '../../core/storage/database.dart';
import '../../core/storage/knowledge_point_dao.dart';
import '../../core/storage/learning_record_dao.dart';
import '../../core/storage/sentence_dao.dart';
import '../../core/storage/word_entry_dao.dart';
import '../../core/theme/app_theme.dart';
import '../../services/asr_service.dart';
import '../../services/native_tts_service.dart';
import '../../services/tts_service.dart';
import '../../services/vosk_asr_service.dart';
import '../settings/settings_page.dart';
import '../../widgets/knowledge_scope_picker.dart';
import 'scoring.dart';

/// [v0.1.0] [v2.9.0] 跟读练习页（核心链路：放音 → 录音 → 识别 → 评分 → 生词落库）。
///
/// v2.9.0 增强：
/// - 慢速示范播放
/// - 录音波形动画
/// - 星级 + 友好评语
/// - 音节相似度指标
class FollowPage extends StatefulWidget {
  const FollowPage({
    super.key,
    this.initialSentence,
    this.bookId,
    this.bookTitle,
    this.pageNumber,
  });

  final String? initialSentence;
  final String? bookId;
  final String? bookTitle;
  final int? pageNumber;

  @override
  State<FollowPage> createState() => _FollowPageState();
}

class _FollowPageState extends State<FollowPage>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  static const _tag = 'follow';

  final AsrService _asr = VoskAsrService();
  final TtsService _tts = NativeTtsService();
  final _sentenceController = TextEditingController();

  bool _listening = false;
  bool _playing = false;
  bool _operationBusy = false;
  bool _appActive = true;
  int _playRequest = 0;
  int _lifecycleRequest = 0;
  FollowScore? _lastScore;
  String _recognized = '';
  String _status = '选择句子，点播放跟读';
  late final AnimationController _waveAnimCtrl;
  final List<double> _waveBars = List.generate(16, (_) => 0.3);
  bool _waveActive = false;

  // [v2.11.0] 从阅读页传入的当前页句子列表
  List<Sentence> _pageSentences = const [];

  // [v2.11.0] 知识库选择范围标签
  String? _scopeLabel;

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
    _waveAnimCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..addListener(_onWaveTick);
    _sentenceController.text = widget.initialSentence ?? _sampleSentences.first;
    // [v2.11.0] 加载当前页句子（从阅读页进入时）
    _loadPageSentences();
    // [v2.11.0] 从设置中自动加载 Vosk 模型
    _autoLoadVosk();
  }

  /// [v2.11.0] 从阅读页加载当前页的句子列表。
  Future<void> _loadPageSentences() async {
    if (widget.bookId == null || widget.pageNumber == null) return;
    try {
      final db = await DatabaseProvider.database;
      final dao = SentenceDao(db);
      final pageSentences = await dao.getByPage(
        widget.bookId!,
        widget.pageNumber!,
      );
      if (mounted && pageSentences.isNotEmpty) {
        setState(() => _pageSentences = pageSentences);
      }
    } catch (e) {
      AppLog.w(_tag, '加载阅读页句子失败: $e');
    }
  }

  Future<void> _autoLoadVosk() async {
    final settings = SettingsService.instance;
    final modelPath = await settings.getVoskModelPath();
    if (modelPath == null || modelPath.isEmpty) {
      if (mounted) {
        setState(() => _status = '请先在设置中配置 Vosk 语音识别模型');
      }
      return;
    }
    // 检查文件是否仍存在
    final modelDir = Directory(modelPath);
    if (!await modelDir.exists()) {
      AppLog.w(_tag, 'Vosk 模型目录已不存在，需重新配置');
      if (mounted) {
        setState(() => _status = '模型文件已丢失，请在设置中重新配置');
      }
      return;
    }
    setState(() => _status = '正在加载语音模型…');
    try {
      final ok = await _asr.init(modelPath);
      if (mounted) {
        setState(() {
          _status = ok ? '模型已加载 ✓ 选择句子跟读' : '模型加载失败';
        });
      }
    } catch (e) {
      AppLog.e(_tag, 'Vosk 自动加载失败: $e');
      if (mounted) {
        setState(() => _status = '模型加载失败: $e');
      }
    }
  }

  /// [v2.11.0] 检查模型是否已就绪
  bool get _modelReady => _asr.isLoaded;

  void _onWaveTick() {
    if (!_waveActive) return;
    setState(() {
      for (var i = 0; i < _waveBars.length; i++) {
        _waveBars[i] =
            0.15 +
            (i.isEven ? 0.35 : 0.25) +
            (0.5 * (_waveAnimCtrl.value * (i % 3 + 1) % 1.0)).abs();
      }
    });
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
    } else {
      // [v2.11.0] 返回前台时自动重新加载模型
      if (!_modelReady) {
        _autoLoadVosk();
      }
    }
  }

  Future<void> _suspendPractice(int request) async {
    final stopped = await _tts.stop();
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
          stopped
              ? (_appActive ? '语音已停止，可继续练习' : '已暂停，返回应用后可继续')
              : '语音停止失败，请重新进入页面';
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _waveAnimCtrl.dispose();
    _appActive = false;
    _lifecycleRequest++;
    _playRequest++;
    unawaited(_tts.stop());
    unawaited(_disposeAsr());
    _sentenceController.dispose();
    super.dispose();
  }

  Future<void> _play() async {
    if (!_appActive || _playing || _listening || _operationBusy) {
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
      _status = '播放中...';
    });

    final ready = await _tts.init();
    if (!mounted || request != _playRequest) return;
    if (!ready) {
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

  /// 慢速示范播放（用于儿童跟读前聆听）。
  Future<void> _slowPlay() async {
    if (!_appActive || _playing || _listening || _operationBusy) {
      return;
    }
    final text = _sentenceController.text.trim();
    if (text.isEmpty) {
      _setStatus('请先输入要跟读的句子');
      return;
    }
    final request = ++_playRequest;
    setState(() {
      _playing = true;
      _status = '慢速示范播放中...';
    });
    final ready = await _tts.init();
    if (!mounted || request != _playRequest) return;
    if (!ready) {
      setState(() {
        _playing = false;
        _status = '语音引擎不可用';
      });
      return;
    }
    final ok = await _tts.speak(text);
    if (!mounted || request != _playRequest) return;
    setState(() {
      _playing = false;
      _status = ok ? '示范结束，点跟读开始练习' : '播放已停止';
    });
  }

  bool _isLifecycleCurrent(int request) {
    return mounted && _appActive && request == _lifecycleRequest;
  }

  Future<void> _toggleListen() async {
    if (!_appActive || _playing || _operationBusy) return;
    final lifecycleRequest = _lifecycleRequest;
    setState(() => _operationBusy = true);
    try {
      if (_listening) {
        AppLog.d(_tag, '停止录音');
        _waveActive = false;
        _waveAnimCtrl.stop();
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
        _playRequest++;
        final stopped = await _tts.stop();
        if (!_isLifecycleCurrent(lifecycleRequest)) return;
        if (!stopped) {
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
          _status = ok ? '录音中... 说完点停止' : '启动录音失败';
        });
        if (ok) {
          _waveActive = true;
          _waveAnimCtrl.repeat(reverse: true);
        } else {
          _waveActive = false;
          _waveAnimCtrl.stop();
        }
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

  /// [v2.11.0] 跟读时自动将词语同步到知识点库（按书/页分类，已存在则跳过）。
  Future<void> _syncToKnowledgeBase(String word) async {
    if (widget.bookId == null) return;
    try {
      final db = await DatabaseProvider.database;
      final dao = KnowledgePointDao(db);
      // 已存在则跳过
      final existing = await dao.findByBookTypeText(
        widget.bookId!,
        KnowledgeType.word,
        word,
      );
      if (existing != null) return;
      await dao.upsertByText(
        widget.bookId!,
        KnowledgeType.word,
        word,
        page: widget.pageNumber,
        source: 'follow',
      );
      AppLog.d(_tag, '已同步到知识点库: $word');
    } catch (e) {
      AppLog.w(_tag, '同步知识点库失败: $e');
    }
  }

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
    // [v2.11.0] 同步到知识点库（按书/页分类）
    unawaited(_syncToKnowledgeBase(target));
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
    if (mounted) setState(() => _status = s);
  }

  Future<void> _disposeAsr() async {
    try {
      await _asr.dispose();
    } catch (e) {
      AppLog.w(_tag, 'ASR dispose 失败: $e');
    }
  }

  /// [v2.11.0] 模型状态卡片 + 设置入口。
  Widget _buildModelStatus() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(
              _modelReady ? Icons.check_circle : Icons.settings,
              color: _modelReady ? StudyPalette.moss : StudyPalette.inkSoft,
              size: 28,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _modelReady ? '语音模型已就绪' : '语音识别模型未配置',
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      color: StudyPalette.ink,
                    ),
                  ),
                  Text(
                    _status,
                    style: const TextStyle(
                      fontSize: 12,
                      color: StudyPalette.inkSoft,
                    ),
                  ),
                ],
              ),
            ),
            if (!_modelReady)
              TextButton.icon(
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('去设置', style: TextStyle(fontSize: 12)),
                onPressed: _openSettings,
              ),
          ],
        ),
      ),
    );
  }

  /// [v2.11.0] 当前页句子列表（从阅读页传入时显示）。
  Widget _buildPageSentenceList() {
    if (_pageSentences.isEmpty) return const SizedBox();
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: Text('当前页句子', style: titleStyle(fontSize: 14)),
          ),
          const Divider(height: 1),
          ...List.generate(_pageSentences.length, (i) {
            final s = _pageSentences[i];
            final selected = _sentenceController.text == s.text;
            return ListTile(
              dense: true,
              selected: selected,
              selectedTileColor: StudyPalette.emberSoft.withValues(alpha: 0.3),
              leading: Text(
                '${i + 1}',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: StudyPalette.inkSoft,
                ),
              ),
              title: Text(
                s.text,
                style: const TextStyle(fontSize: 14, color: StudyPalette.ink),
              ),
              trailing: IconButton(
                icon: Icon(
                  selected
                      ? Icons.play_circle_filled
                      : Icons.play_circle_outline,
                  size: 20,
                  color: selected ? StudyPalette.ember : StudyPalette.inkSoft,
                ),
                onPressed: () {
                  setState(() {
                    _sentenceController.text = s.text;
                    _lastScore = null;
                  });
                  _play();
                },
              ),
              onTap: () {
                setState(() {
                  _sentenceController.text = s.text;
                  _lastScore = null;
                });
              },
            );
          }),
        ],
      ),
    );
  }

  void _openSettings() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const SettingsPage()));
  }

  /// [v2.11.0] 打开知识库范围选择器，选中后加载对应知识点作为跟读句子。
  Future<void> _openKnowledgeScope() async {
    final scope = await KnowledgeScopePicker.show(context);
    if (scope == null || !mounted) return;
    setState(() {
      _scopeLabel =
          '${scope.bookTitle}'
          '${scope.chapter != null && scope.chapter! > 0 ? ' · 第${scope.chapter}单元' : ''}'
          '${scope.page != null && scope.page! > 0 ? ' · 第${scope.page}课' : ''}';
      _pageSentences = const [];
    });
    try {
      final db = await DatabaseProvider.database;
      final dao = KnowledgePointDao(db);
      final points = await dao.getByBook(scope.bookId);
      var filtered = points;
      if (scope.chapter != null && scope.chapter! > 0) {
        filtered = filtered.where((p) => p.chapter == scope.chapter).toList();
      }
      if (scope.page != null && scope.page! > 0) {
        filtered = filtered.where((p) => p.page == scope.page).toList();
      }
      if (!mounted) return;
      setState(() {
        _pageSentences =
            filtered
                .map(
                  (kp) => Sentence(
                    id: kp.id,
                    bookId: scope.bookId,
                    page: kp.page ?? 0,
                    chapter: kp.chapter ?? 0,
                    index: 0,
                    text: kp.text,
                  ),
                )
                .toList();
      });
    } catch (e) {
      AppLog.e(_tag, '加载知识库句子失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final canPractice = _modelReady;
    return Scaffold(
      appBar: AppBar(title: const Text('跟读练习')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // [v2.11.0] 模型就绪状态 + 配置入口
          _buildModelStatus(),
          // [v2.11.0] 从知识库选择练习范围
          Card(
            child: ListTile(
              leading: const Icon(
                Icons.auto_stories,
                size: 20,
                color: StudyPalette.spinePdf,
              ),
              title: const Text('从知识库选择', style: TextStyle(fontSize: 14)),
              subtitle: Text(
                _scopeLabel ?? '选教材→单元→课，从中跟读',
                style: const TextStyle(
                  fontSize: 12,
                  color: StudyPalette.inkSoft,
                ),
              ),
              trailing: const Icon(
                Icons.chevron_right,
                size: 18,
                color: StudyPalette.inkSoft,
              ),
              onTap: () => _openKnowledgeScope(),
            ),
          ),
          // [v2.11.0] 当前页句子列表（从阅读页进入时）
          if (_pageSentences.isNotEmpty) ...[
            const SizedBox(height: 12),
            _buildPageSentenceList(),
          ],
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
                  label: Text(_playing ? '播放中...' : '播放'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  onPressed:
                      canPractice && !_playing && !_listening && !_operationBusy
                          ? _slowPlay
                          : null,
                  icon: const Icon(Icons.hearing),
                  label: Text(_playing ? '播放中...' : '慢速'),
                  style: FilledButton.styleFrom(
                    backgroundColor: StudyPalette.spinePdf,
                  ),
                ),
              ),
              const SizedBox(width: 8),
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
          if (_listening)
            SizedBox(
              height: 48,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(_waveBars.length, (i) {
                  final h = _waveBars[i].clamp(0.2, 1.0);
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 100),
                      width: 4,
                      height: 48 * h,
                      decoration: BoxDecoration(
                        color: StudyPalette.ember.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  );
                }),
              ),
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

  /// 构建星级行（1-5 星）。
  Widget _buildStarRating(int stars) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) {
        return Icon(
          i < stars ? Icons.star : Icons.star_border,
          size: 28,
          color: i < stars ? StudyPalette.ember : StudyPalette.inkSoft,
        );
      }),
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
                  _buildStarRating(s.starCount),
                  const Spacer(),
                  Icon(
                    s.passed ? Icons.check_circle : Icons.replay,
                    color: color,
                    size: 28,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                s.comment,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  const Icon(Icons.mic, size: 14, color: StudyPalette.inkSoft),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      '你说的是：$_recognized',
                      style: const TextStyle(
                        fontSize: 13,
                        color: StudyPalette.inkSoft,
                      ),
                    ),
                  ),
                  Text(
                    '音节相似 ${(s.syllableSim * 100).round()}%',
                    style: const TextStyle(
                      fontSize: 11,
                      color: StudyPalette.spinePdf,
                    ),
                  ),
                ],
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
              text: '+${d.actual}',
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
