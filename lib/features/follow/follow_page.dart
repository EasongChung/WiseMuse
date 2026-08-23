import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:pinyin/pinyin.dart';

import '../../core/debug/app_log.dart';
import '../../core/models/knowledge_point.dart';
import '../../core/models/learning_record.dart';
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
import '../../widgets/knowledge_scope_picker.dart';
import '../../widgets/top_toast.dart';
import '../settings/settings_page.dart';
import 'scoring.dart';

/// 单个跟读条目（句子或词语）。
class FollowItem {
  const FollowItem({
    required this.text,
    this.pinyin,
    this.sourceTitle,
    this.bookId,
    this.page,
    this.chapter,
  });

  final String text;
  final String? pinyin;
  final String? sourceTitle;
  final String? bookId;
  final int? page;
  final int? chapter;
}

/// [v0.1.61] 儿童化跟读练习页：列表关卡式流转、大字拼音卡片、慢速领读、声波反馈、逐字正误高亮与成绩汇总。
class FollowPage extends StatefulWidget {
  const FollowPage({
    super.key,
    this.initialSentence,
    this.sentences,
    this.items,
    this.title,
    this.bookId,
    this.bookTitle,
    this.pageNumber,
    this.initialIndex = 0,
  });

  final String? initialSentence;
  final List<String>? sentences;
  final List<FollowItem>? items;
  final String? title;
  final String? bookId;
  final String? bookTitle;
  final int? pageNumber;
  final int initialIndex;

  @override
  State<FollowPage> createState() => _FollowPageState();
}

class _FollowPageState extends State<FollowPage>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  static const _tag = 'follow';

  final AsrService _asr = VoskAsrService();
  final TtsService _tts = NativeTtsService();

  List<FollowItem> _items = const [];
  int _currentIndex = 0;
  final Map<int, FollowScore> _scores = {};
  final Map<int, String> _recognizedMap = {};

  bool _loading = true;
  bool _listening = false;
  bool _playing = false;
  bool _slowPlaying = false;
  bool _operationBusy = false;
  bool _appActive = true;
  int _playRequest = 0;
  int _lifecycleRequest = 0;

  String _status = '先听老师读，再点麦克风跟读哦！';
  late final AnimationController _waveAnimCtrl;
  final List<double> _waveBars = List.generate(16, (_) => 0.3);
  bool _waveActive = false;

  Timer? _autoNextTimer;
  int _autoNextCountdown = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _waveAnimCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    )..addListener(_onWaveTick);

    _initData();
    _autoLoadVosk();
  }

  void _onWaveTick() {
    if (!_waveActive) return;
    setState(() {
      for (var i = 0; i < _waveBars.length; i++) {
        _waveBars[i] =
            0.2 +
            (i.isEven ? 0.35 : 0.2) +
            (0.45 * (_waveAnimCtrl.value * (i % 4 + 1) % 1.0)).abs();
      }
    });
  }

  Future<void> _initData() async {
    final list = <FollowItem>[];
    if (widget.items != null && widget.items!.isNotEmpty) {
      list.addAll(widget.items!);
    } else if (widget.sentences != null && widget.sentences!.isNotEmpty) {
      for (final s in widget.sentences!) {
        list.add(_buildItem(s, sourceTitle: widget.title ?? widget.bookTitle));
      }
    } else if (widget.initialSentence != null &&
        widget.initialSentence!.trim().isNotEmpty) {
      list.add(
        _buildItem(
          widget.initialSentence!,
          sourceTitle: widget.title ?? widget.bookTitle,
        ),
      );
    }

    if (list.isEmpty && widget.bookId != null && widget.pageNumber != null) {
      try {
        final db = await DatabaseProvider.database;
        final dao = SentenceDao(db);
        final pageSentences = await dao.getByPage(
          widget.bookId!,
          widget.pageNumber!,
        );
        for (final s in pageSentences) {
          list.add(
            _buildItem(
              s.text,
              sourceTitle: widget.bookTitle,
              page: s.page,
              chapter: s.chapter,
            ),
          );
        }
      } catch (e) {
        AppLog.w(_tag, '从页加载句子失败: $e');
      }
    }

    if (!mounted) return;
    setState(() {
      _items = list;
      _currentIndex = widget.initialIndex.clamp(
        0,
        list.isEmpty ? 0 : list.length - 1,
      );
      _loading = false;
    });

    if (list.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showSourceDialog();
      });
    }
  }

  FollowItem _buildItem(
    String text, {
    String? sourceTitle,
    int? page,
    int? chapter,
  }) {
    String? pinyin;
    try {
      pinyin = PinyinHelper.getPinyinE(
        text,
        separator: ' ',
        format: PinyinFormat.WITH_TONE_MARK,
      );
    } catch (_) {}
    return FollowItem(
      text: text.trim(),
      pinyin: pinyin,
      sourceTitle: sourceTitle,
      bookId: widget.bookId,
      page: page ?? widget.pageNumber,
      chapter: chapter,
    );
  }

  Future<void> _autoLoadVosk() async {
    final settings = SettingsService.instance;
    final modelPath = await settings.getVoskModelPath();
    if (modelPath == null || modelPath.isEmpty) {
      if (mounted) {
        setState(() => _status = '⚠️ 语音识别模型未配置，请先到「设置」中下载或配置');
      }
      return;
    }
    final modelDir = Directory(modelPath);
    if (!await modelDir.exists()) {
      if (mounted) {
        setState(() => _status = '⚠️ 模型文件已丢失，请在「设置」中重新下载');
      }
      return;
    }
    try {
      final ok = await _asr.init(modelPath);
      if (mounted) {
        setState(() {
          _status = ok ? '先听老师读，再点麦克风跟读哦！' : '❌ 语音识别模型加载失败';
        });
      }
    } catch (e) {
      AppLog.e(_tag, 'Vosk 自动加载失败: $e');
      if (mounted) {
        setState(() => _status = '❌ 语音模型加载失败: $e');
      }
    }
  }

  bool get _modelReady => _asr.isLoaded;
  FollowItem? get _currentItem =>
      _items.isNotEmpty && _currentIndex < _items.length
          ? _items[_currentIndex]
          : null;
  FollowScore? get _currentScore => _scores[_currentIndex];

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final nextActive = state == AppLifecycleState.resumed;
    if (nextActive == _appActive) return;
    _appActive = nextActive;
    if (!_appActive) {
      final request = ++_lifecycleRequest;
      _playRequest++;
      _cancelAutoNext();
      setState(() => _operationBusy = true);
      unawaited(_suspendPractice(request));
    } else {
      if (!_modelReady) _autoLoadVosk();
    }
  }

  Future<void> _suspendPractice(int request) async {
    final stopped = await _tts.stop();
    if (_listening) {
      try {
        await _asr.stop();
      } catch (_) {}
    }
    if (!mounted || request != _lifecycleRequest) return;
    setState(() {
      _playing = false;
      _slowPlaying = false;
      _listening = false;
      _operationBusy = false;
      _waveActive = false;
      _waveAnimCtrl.stop();
      _status = stopped ? '已暂停，回来后点击继续练习' : '语音停止失败，请重新尝试';
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancelAutoNext();
    _waveAnimCtrl.dispose();
    _appActive = false;
    _lifecycleRequest++;
    _playRequest++;
    unawaited(_tts.stop());
    unawaited(_asr.dispose());
    super.dispose();
  }

  void _cancelAutoNext() {
    _autoNextTimer?.cancel();
    _autoNextTimer = null;
    _autoNextCountdown = 0;
  }

  // ===== 播放控制 =====

  Future<void> _playNormal() async {
    final item = _currentItem;
    if (item == null ||
        !_appActive ||
        _playing ||
        _listening ||
        _operationBusy) {
      return;
    }
    _cancelAutoNext();
    final request = ++_playRequest;
    setState(() {
      _playing = true;
      _slowPlaying = false;
      _status = '🔊 正在标准范读…';
    });
    final ready = await _tts.init();
    if (!mounted || request != _playRequest) return;
    if (!ready) {
      setState(() {
        _playing = false;
        _status = '❌ 朗读失败：语音引擎不可用';
      });
      return;
    }
    final ok = await _tts.speak(item.text);
    if (!mounted || request != _playRequest) return;
    setState(() {
      _playing = false;
      _status = ok ? '示范完毕！现在轮到你跟读啦 🎙️' : '朗读已停止';
    });
  }

  Future<void> _playSlow() async {
    final item = _currentItem;
    if (item == null ||
        !_appActive ||
        _playing ||
        _listening ||
        _operationBusy) {
      return;
    }
    _cancelAutoNext();
    final request = ++_playRequest;
    setState(() {
      _playing = true;
      _slowPlaying = true;
      _status = '🐢 慢速领读中，请仔细听…';
    });
    final ready = await _tts.init();
    if (!mounted || request != _playRequest) return;
    if (!ready) {
      setState(() {
        _playing = false;
        _status = '❌ 语音引擎不可用';
      });
      return;
    }
    final ok = await _tts.speak(item.text);
    if (!mounted || request != _playRequest) return;
    setState(() {
      _playing = false;
      _slowPlaying = false;
      _status = ok ? '慢速示范结束，点击麦克风跟着读！' : '播放已停止';
    });
  }

  // ===== 录音与评分 =====

  Future<void> _toggleListen() async {
    if (!_appActive || _playing || _operationBusy) return;
    _cancelAutoNext();
    final lifecycleRequest = _lifecycleRequest;
    setState(() => _operationBusy = true);
    try {
      if (_listening) {
        AppLog.d(_tag, '停止跟读录音');
        _waveActive = false;
        _waveAnimCtrl.stop();
        setState(() {
          _listening = false;
          _status = '正在智能评分中… ✨';
        });
        final text = await _asr.stop();
        AppLog.d(_tag, '识别结果: "$text"');
        if (!mounted || lifecycleRequest != _lifecycleRequest) return;
        setState(() {
          _recognizedMap[_currentIndex] = text;
        });
        await _scoreAndPersist(text);
      } else {
        _playRequest++;
        await _tts.stop();
        if (!mounted || lifecycleRequest != _lifecycleRequest) return;

        final perm = await Permission.microphone.request();
        if (!mounted || lifecycleRequest != _lifecycleRequest) return;
        if (!perm.isGranted) {
          setState(() => _status = '⚠️ 需要麦克风权限才能进行语音跟读');
          TopToast.show(context, '请允许麦克风权限');
          return;
        }

        final ok = await _asr.start();
        if (!mounted || lifecycleRequest != _lifecycleRequest) {
          if (ok) unawaited(_asr.stop());
          return;
        }
        setState(() {
          _listening = ok;
          _status = ok ? '🎙️ 正在聆听，请大声朗读…（读完再次点击停止）' : '启动录音失败，请重试';
        });
        if (ok) {
          _waveActive = true;
          _waveAnimCtrl.repeat(reverse: true);
        }
      }
    } finally {
      if (mounted && lifecycleRequest == _lifecycleRequest) {
        setState(() => _operationBusy = false);
      }
    }
  }

  Future<void> _scoreAndPersist(String recognized) async {
    final item = _currentItem;
    if (item == null) return;
    final target = item.text;
    final score = FollowScorer.scoreFollow(target, recognized);
    if (!mounted) return;

    setState(() {
      _scores[_currentIndex] = score;
      _status =
          score.passed
              ? '🌟 ${score.comment} (${score.score.toStringAsFixed(0)}分)'
              : '💪 ${score.comment} (${score.score.toStringAsFixed(0)}分)';
    });

    try {
      final db = await DatabaseProvider.database;
      await LearningRecordDao(db).insert(
        LearningRecord.create(
          type: LearningType.follow,
          target: target,
          result: score.score,
          detail: jsonEncode({
            'recognized': recognized,
            'score': score.toJson(),
            'itemIndex': _currentIndex,
          }),
        ),
      );

      if (!score.passed) {
        await _persistUnmasteredWord(target, item);
      }
    } catch (e, s) {
      AppLog.e(_tag, '跟读落库失败: $e\n$s');
    }

    // 若通过（≥80 分），且不是最后一题，启动 2.5 秒倒计时自动进入下一题
    if (score.passed && _currentIndex < _items.length - 1) {
      _startAutoNext();
    }
  }

  Future<void> _persistUnmasteredWord(String target, FollowItem item) async {
    try {
      final db = await DatabaseProvider.database;
      final dao = WordEntryDao(db);
      final existing = await dao.findByWord(target, lang: 'zh');
      if (existing != null) {
        existing.wrongCount++;
        existing.lastReviewAt = DateTime.now().microsecondsSinceEpoch;
        await dao.update(existing);
      } else {
        await dao.upsert(
          WordEntry.create(word: target, lang: 'zh', fromBookId: item.bookId),
        );
      }

      if (item.bookId != null) {
        final kpDao = KnowledgePointDao(db);
        await kpDao.upsertByText(
          item.bookId!,
          KnowledgeType.word,
          target,
          page: item.page,
          chapter: item.chapter,
          source: 'follow',
        );
      }
    } catch (_) {}
  }

  void _startAutoNext() {
    _cancelAutoNext();
    setState(() => _autoNextCountdown = 2);
    _autoNextTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_autoNextCountdown <= 1) {
        _cancelAutoNext();
        _goToNext();
      } else {
        setState(() => _autoNextCountdown--);
      }
    });
  }

  void _goToIndex(int index) {
    if (index < 0 || index >= _items.length) return;
    _cancelAutoNext();
    _tts.stop();
    setState(() {
      _currentIndex = index;
      _status =
          _scores[index] != null
              ? '已跟读（${_scores[index]!.score.toStringAsFixed(0)}分），可继续重读'
              : '先听老师读，再点麦克风跟读哦！';
    });
  }

  void _goToNext() {
    if (_currentIndex < _items.length - 1) {
      _goToIndex(_currentIndex + 1);
    } else {
      _showFinishSummary();
    }
  }

  void _goToPrev() {
    if (_currentIndex > 0) {
      _goToIndex(_currentIndex - 1);
    }
  }

  // ===== 词源选择对话框 =====

  Future<void> _showSourceDialog() async {
    final choice = await showDialog<String>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('选择跟读内容'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(
                    Icons.menu_book,
                    color: StudyPalette.ember,
                  ),
                  title: const Text('课文/章节跟读'),
                  subtitle: const Text('从已导入的教材中选课全篇跟读'),
                  onTap: () => Navigator.pop(ctx, 'book'),
                ),
                ListTile(
                  leading: const Icon(
                    Icons.bookmark_outline,
                    color: StudyPalette.moss,
                  ),
                  title: const Text('重点生词跟读'),
                  subtitle: const Text('练习生词本中未掌握的发音'),
                  onTap: () => Navigator.pop(ctx, 'wordbook'),
                ),
                ListTile(
                  leading: const Icon(
                    Icons.psychology_outlined,
                    color: StudyPalette.spinePdf,
                  ),
                  title: const Text('知识库词句跟读'),
                  subtitle: const Text('按诗词、成语、重点句进行练习'),
                  onTap: () => Navigator.pop(ctx, 'knowledge'),
                ),
              ],
            ),
          ),
    );
    if (choice == null || !mounted) return;

    if (choice == 'book') {
      await _loadFromBookScope();
    } else if (choice == 'wordbook') {
      await _loadFromWordbook();
    } else if (choice == 'knowledge') {
      await _loadFromKnowledge();
    }
  }

  Future<void> _loadFromBookScope() async {
    final scope = await KnowledgeScopePicker.show(context);
    if (scope == null || !mounted) return;
    try {
      final db = await DatabaseProvider.database;
      final dao = SentenceDao(db);
      var sentences = await dao.getByBook(scope.bookId);
      if (scope.page != null && scope.page! > 0) {
        sentences = sentences.where((s) => s.page == scope.page).toList();
      }
      if (scope.chapter != null && scope.chapter! > 0) {
        sentences = sentences.where((s) => s.chapter == scope.chapter).toList();
      }

      final items =
          sentences
              .map(
                (s) => _buildItem(
                  s.text,
                  sourceTitle: scope.bookTitle,
                  page: s.page,
                  chapter: s.chapter,
                ),
              )
              .toList();

      if (items.isEmpty) {
        if (mounted) TopToast.show(context, '所选范围暂无可用句子');
        return;
      }
      setState(() {
        _items = items;
        _currentIndex = 0;
        _scores.clear();
        _recognizedMap.clear();
        _status = '先听老师读，再点麦克风跟读哦！';
      });
    } catch (e) {
      AppLog.e(_tag, '加载课文失败: $e');
    }
  }

  Future<void> _loadFromWordbook() async {
    try {
      final db = await DatabaseProvider.database;
      final unmastered = await WordEntryDao(db).getUnmastered(threshold: 3);
      var words = unmastered.map((w) => w.word).toList();
      if (words.isEmpty) {
        words = const ['苹果', '春天', '认真', '美丽', '学习', '太阳', '温暖', '快乐'];
        if (mounted) TopToast.show(context, '生词本暂无未掌握生词，已加载常用字词');
      }
      final items =
          words.map((w) => _buildItem(w, sourceTitle: '重点生词')).toList();
      setState(() {
        _items = items;
        _currentIndex = 0;
        _scores.clear();
        _recognizedMap.clear();
        _status = '重点生词已就绪，开始跟读吧！';
      });
    } catch (e) {
      AppLog.e(_tag, '加载生词本失败: $e');
    }
  }

  Future<void> _loadFromKnowledge() async {
    try {
      final db = await DatabaseProvider.database;
      final points = await KnowledgePointDao(db).getAll();
      if (points.isEmpty) {
        if (mounted) TopToast.show(context, '知识库暂无内容');
        return;
      }
      final items =
          points
              .take(20)
              .map(
                (kp) =>
                    _buildItem(kp.text, sourceTitle: '知识库 · ${kp.type.label}'),
              )
              .toList();
      setState(() {
        _items = items;
        _currentIndex = 0;
        _scores.clear();
        _recognizedMap.clear();
        _status = '知识库重点词句已就绪！';
      });
    } catch (e) {
      AppLog.e(_tag, '加载知识库失败: $e');
    }
  }

  // ===== 句子清单与结算 =====

  void _showSentenceListSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor:
          Theme.of(context).brightness == Brightness.dark
              ? StudyPalette.darkCard
              : StudyPalette.parchment,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(top: 12, bottom: 8),
                decoration: BoxDecoration(
                  color: StudyPalette.linen,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.format_list_bulleted,
                      color: StudyPalette.ember,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '跟读清单 (${_items.length} 句)',
                      style: titleStyle(fontSize: 16),
                    ),
                    const Spacer(),
                    Text(
                      '已完成 ${_scores.length} / ${_items.length}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: StudyPalette.inkSoft,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.all(12),
                  itemCount: _items.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (c, i) {
                    final item = _items[i];
                    final isCurrent = i == _currentIndex;
                    final score = _scores[i];
                    return ListTile(
                      dense: true,
                      selected: isCurrent,
                      selectedTileColor: StudyPalette.emberSoft.withValues(
                        alpha: 0.35,
                      ),
                      leading: CircleAvatar(
                        radius: 13,
                        backgroundColor:
                            score != null
                                ? (score.passed
                                    ? StudyPalette.moss
                                    : StudyPalette.ember)
                                : StudyPalette.linen,
                        child: Text(
                          '${i + 1}',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color:
                                score != null
                                    ? Colors.white
                                    : StudyPalette.inkSoft,
                          ),
                        ),
                      ),
                      title: Text(
                        item.text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight:
                              isCurrent ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                      trailing:
                          score != null
                              ? Text(
                                '${score.score.toStringAsFixed(0)}分',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color:
                                      score.passed
                                          ? StudyPalette.moss
                                          : StudyPalette.ember,
                                ),
                              )
                              : const Text(
                                '未跟读',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: StudyPalette.inkSoft,
                                ),
                              ),
                      onTap: () {
                        Navigator.pop(ctx);
                        _goToIndex(i);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showFinishSummary() {
    final total = _items.length;
    final completed = _scores.length;
    var totalScore = 0.0;
    var totalStars = 0;
    var passedCount = 0;
    for (final s in _scores.values) {
      totalScore += s.score;
      totalStars += s.starCount;
      if (s.passed) passedCount++;
    }
    final avgScore = completed > 0 ? (totalScore / completed).round() : 0;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder:
          (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.emoji_events,
                  color: StudyPalette.ember,
                  size: 26,
                ),
                const SizedBox(width: 8),
                Text('跟读挑战完成！', style: titleStyle(fontSize: 20)),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: StudyPalette.parchmentDeep,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildSummaryCol('总计获得', '⭐ $totalStars 颗'),
                      _buildSummaryCol('平均分', '$avgScore 分'),
                      _buildSummaryCol('通过率', '$passedCount / $total'),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  avgScore >= 80
                      ? '🎉 表现太出色了，发音字正腔圆！'
                      : '👍 很棒的尝试，不熟练的词已加入生词本，继续加油！',
                  style: const TextStyle(
                    fontSize: 13,
                    color: StudyPalette.inkSoft,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  setState(() {
                    _currentIndex = 0;
                    _scores.clear();
                    _recognizedMap.clear();
                    _status = '先听老师读，再点麦克风跟读哦！';
                  });
                },
                child: const Text('再练一遍'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: StudyPalette.ember,
                ),
                onPressed: () {
                  Navigator.pop(ctx);
                  Navigator.pop(context);
                },
                child: const Text('完成练习'),
              ),
            ],
          ),
    );
  }

  Widget _buildSummaryCol(String label, String value) {
    return Column(
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: StudyPalette.inkSoft),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            color: StudyPalette.ink,
          ),
        ),
      ],
    );
  }

  void _openSettings() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const SettingsPage()));
  }

  // ===== UI 构建 =====

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final item = _currentItem;
    final score = _currentScore;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title ?? (item?.sourceTitle ?? '跟读练习')),
        actions: [
          if (_items.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.format_list_bulleted),
              tooltip: '句子清单',
              onPressed: _showSentenceListSheet,
            ),
          IconButton(
            icon: const Icon(Icons.change_circle_outlined),
            tooltip: '切换内容',
            onPressed: _showSourceDialog,
          ),
        ],
      ),
      body:
          _loading
              ? const Center(child: CircularProgressIndicator())
              : _items.isEmpty
              ? _buildEmptyState()
              : Column(
                children: [
                  // 顶部总进度条
                  LinearProgressIndicator(
                    value:
                        _items.isNotEmpty
                            ? ((_currentIndex + 1) / _items.length).clamp(
                              0.0,
                              1.0,
                            )
                            : 0,
                    backgroundColor: StudyPalette.linen,
                    color: StudyPalette.ember,
                    minHeight: 4,
                  ),
                  if (!_modelReady) _buildModelWarningBanner(),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
                      child: Column(
                        children: [
                          // 题号与卡片
                          _buildMainCard(item!, score, isDark),
                          const SizedBox(height: 16),
                          // 状态与声波
                          _buildVoiceWaveSection(),
                          const SizedBox(height: 16),
                          // 播放与跟读大按钮
                          _buildControlButtons(),
                          if (score != null) ...[
                            const SizedBox(height: 16),
                            _buildScoreResultCard(score, isDark),
                          ],
                        ],
                      ),
                    ),
                  ),
                  _buildBottomNavBar(),
                ],
              ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.record_voice_over_outlined,
            size: 56,
            color: StudyPalette.inkSoft,
          ),
          const SizedBox(height: 16),
          Text('暂无跟读内容', style: titleStyle(fontSize: 18)),
          const SizedBox(height: 8),
          const Text(
            '点击下方按钮选择课文或生词进行跟读练习',
            style: TextStyle(color: StudyPalette.inkSoft, fontSize: 13),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: StudyPalette.ember),
            onPressed: _showSourceDialog,
            icon: const Icon(Icons.add),
            label: const Text('选择跟读内容'),
          ),
        ],
      ),
    );
  }

  Widget _buildModelWarningBanner() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: StudyPalette.emberSoft.withValues(alpha: 0.5),
      child: Row(
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            color: StudyPalette.ember,
            size: 20,
          ),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              '语音模型未就绪，录音评分将不可用',
              style: TextStyle(
                fontSize: 12,
                color: StudyPalette.ember,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          TextButton(
            onPressed: _openSettings,
            child: const Text(
              '去配置',
              style: TextStyle(fontSize: 12, color: StudyPalette.ember),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMainCard(FollowItem item, FollowScore? score, bool isDark) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: StudyPalette.linen),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 20),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: StudyPalette.emberSoft,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '第 ${_currentIndex + 1} / ${_items.length} 句',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: StudyPalette.ember,
                    ),
                  ),
                ),
                const Spacer(),
                if (score != null)
                  Row(
                    children: List.generate(5, (i) {
                      return Icon(
                        i < score.starCount
                            ? Icons.star_rounded
                            : Icons.star_outline_rounded,
                        color: StudyPalette.ember,
                        size: 20,
                      );
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            // 拼音行
            if (item.pinyin != null && item.pinyin!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  item.pinyin!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 14,
                    letterSpacing: 1.5,
                    color: StudyPalette.inkSoft,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            // 汉字主卡片
            if (score == null)
              Text(
                item.text,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: item.text.length > 20 ? 20 : 24,
                  height: 1.6,
                  fontWeight: FontWeight.w600,
                  color: StudyPalette.onSurfaceResolved(context),
                ),
              )
            else
              _buildDiffRichText(score),
          ],
        ),
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
              fontSize: 22,
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
              fontSize: 22,
            ),
          ),
        );
      } else if (diff.status == CharStatus.missing) {
        spans.add(
          TextSpan(
            text: diff.target ?? '（漏）',
            style: TextStyle(
              color: StudyPalette.ember.withValues(alpha: 0.7),
              fontSize: 20,
              decoration: TextDecoration.underline,
            ),
          ),
        );
      } else if (diff.status == CharStatus.extra) {
        spans.add(
          TextSpan(
            text: '(${diff.actual ?? ''})',
            style: const TextStyle(color: StudyPalette.inkSoft, fontSize: 16),
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

  Widget _buildVoiceWaveSection() {
    return Column(
      children: [
        if (_listening)
          SizedBox(
            height: 40,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(_waveBars.length, (i) {
                final h = _waveBars[i].clamp(0.2, 1.0);
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2.5),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 90),
                    width: 5,
                    height: 40 * h,
                    decoration: BoxDecoration(
                      color: StudyPalette.ember,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                );
              }),
            ),
          ),
        const SizedBox(height: 4),
        Text(
          _status,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            color: _listening ? StudyPalette.ember : StudyPalette.inkSoft,
            fontWeight: _listening ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ],
    );
  }

  Widget _buildControlButtons() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // 标准范读
        _buildActionBtn(
          icon:
              _playing && !_slowPlaying
                  ? Icons.pause_circle_filled
                  : Icons.volume_up_outlined,
          label: '标准范读',
          color: StudyPalette.emberSoft,
          textColor: StudyPalette.ember,
          onTap: _playing || _listening ? null : _playNormal,
        ),
        const SizedBox(width: 14),
        // 慢速领读
        _buildActionBtn(
          icon:
              _slowPlaying
                  ? Icons.pause_circle_filled
                  : Icons.slow_motion_video,
          label: '慢速领读',
          color: StudyPalette.spinePdf.withValues(alpha: 0.15),
          textColor: StudyPalette.spinePdf,
          onTap: _playing || _listening ? null : _playSlow,
        ),
        const SizedBox(width: 14),
        // 大号麦克风跟读
        GestureDetector(
          onTap: _modelReady && !_playing ? _toggleListen : null,
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: _listening ? Colors.red : StudyPalette.ember,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: (_listening ? Colors.red : StudyPalette.ember)
                      .withValues(alpha: 0.35),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Icon(
              _listening ? Icons.stop_rounded : Icons.mic_rounded,
              color: Colors.white,
              size: 38,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildActionBtn({
    required IconData icon,
    required String label,
    required Color color,
    required Color textColor,
    required VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          children: [
            Icon(icon, color: textColor, size: 22),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: textColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScoreResultCard(FollowScore score, bool isDark) {
    final recognized = _recognizedMap[_currentIndex] ?? '';
    return Card(
      elevation: 0,
      color: isDark ? StudyPalette.darkCard : StudyPalette.parchmentDeep,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color:
              score.passed
                  ? StudyPalette.moss.withValues(alpha: 0.5)
                  : StudyPalette.ember.withValues(alpha: 0.5),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                Text(
                  '${score.score.toStringAsFixed(0)} 分',
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                    color:
                        score.passed ? StudyPalette.moss : StudyPalette.ember,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    score.comment,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color:
                          score.passed ? StudyPalette.moss : StudyPalette.ember,
                    ),
                  ),
                ),
              ],
            ),
            if (recognized.isNotEmpty) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '我读的：$recognized',
                  style: const TextStyle(
                    fontSize: 12,
                    color: StudyPalette.inkSoft,
                  ),
                ),
              ),
            ],
            if (!score.passed) ...[
              const SizedBox(height: 6),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '💡 已将该句子记录到生词本，稍后可在生词本专项练习',
                  style: TextStyle(fontSize: 11, color: StudyPalette.ember),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildBottomNavBar() {
    final isLast = _currentIndex >= _items.length - 1;
    final score = _currentScore;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        border: const Border(top: BorderSide(color: StudyPalette.linen)),
      ),
      child: Row(
        children: [
          if (_currentIndex > 0)
            OutlinedButton.icon(
              onPressed: _goToPrev,
              icon: const Icon(Icons.arrow_back_ios, size: 14),
              label: const Text('上一句'),
            )
          else
            const SizedBox(width: 80),
          const Spacer(),
          if (score != null && _autoNextCountdown > 0)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ActionChip(
                label: Text('$_autoNextCountdown 秒后自动下一句 (取消)'),
                onPressed: _cancelAutoNext,
              ),
            ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor:
                  score != null && score.passed
                      ? StudyPalette.moss
                      : StudyPalette.ember,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            ),
            onPressed: () {
              if (isLast && score != null) {
                _showFinishSummary();
              } else {
                _goToNext();
              }
            },
            icon: Icon(
              isLast ? Icons.emoji_events : Icons.arrow_forward_ios,
              size: 16,
            ),
            label: Text(
              isLast ? (score != null ? '查看总成绩' : '跳过') : '下一句',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }
}
