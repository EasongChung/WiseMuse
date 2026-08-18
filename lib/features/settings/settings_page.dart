import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../core/debug/app_log.dart';
import '../../core/models/model_ids.dart';
import '../../core/settings/settings_service.dart';
import '../../core/storage/book_dao.dart';
import '../../core/storage/database.dart';
import '../../core/theme/app_theme.dart';
import '../../services/mlkit_translation_service.dart';
import '../../services/model_store.dart';
import '../../services/native_tts_service.dart';
import '../../services/openai_client.dart';
import '../../services/rag/embedding_service.dart';
import '../../services/rag/rag_retrieval_service.dart';
import '../../services/vosk_asr_service.dart';
import '../../services/llm_service.dart';

/// [v0.3.0] [v0.1.44] 设置页：翻译引擎配置 + 供应商管理 + 模型管理 + 朗读参数。
///
/// 「暖色书房」统一风格，[appBar] 标题使用站酷快乐体。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final SettingsService _settings = SettingsService.instance;
  final MlKitTranslationService _mlkit = MlKitTranslationService();
  final NativeTtsService _tts = NativeTtsService();

  // 当前翻译引擎
  String _engine = 'auto';

  // 翻译语种
  String _sourceLang = 'auto';
  String _targetLang = 'en';

  // 模型下载状态（按 BCP-47 代码）
  final Map<String, bool> _modelStatus = {};
  final Map<String, bool> _modelBusy = {};

  // 朗读参数
  double _ttsRate = 0.9;
  int _ttsRepeatCount = 1;
  int _ttsPauseMs = 300;
  String _ttsVoice = '';

  // AI 离线优先
  bool _preferOffline = false;

  // 本地 GGUF 模型状态
  List<_GgufModelInfo> _localModels = const [];

  // Embedding 模型名（RAG 知识库）
  String _embeddingModel = 'text-embedding-3-small';

  // RAG 知识库索引状态
  List<String> _indexedBooks = const [];

  // 本地模型管理
  bool _autoLoadLocal = true;
  String? _defaultLocalModel;
  bool _llmEngineAvailable = false;

  // Vosk 语音模型状态
  bool _voskBusy = false;
  String? _voskModelPath;
  bool _voskModelExists = false;
  bool _voskLoaded = false;

  // [v0.1.44] 供应商管理
  List<ApiProvider> _providers = const [];
  String _activeProviderId = 'siliconflow';
  String _activeEmbeddingProviderId = 'siliconflow';
  final _baseUrlCtrl = TextEditingController();
  final _apiKeyCtrl = TextEditingController();
  final _customModelCtrl = TextEditingController();
  bool _fetchingModels = false;
  String _currentLlmModel = '';

  bool _initDone = false;

  // 源语种选项（含自动识别）
  static const _sourceOptions = [
    ('auto', '自动识别'),
    ('zh', '中文'),
    ('en', '英语'),
    ('ja', '日语'),
    ('ko', '韩语'),
    ('fr', '法语'),
    ('de', '德语'),
    ('es', '西班牙语'),
  ];

  // 预设语言对（目标语种）
  static const _langs = [
    ('zh', '中文'),
    ('en', '英语'),
    ('ja', '日语'),
    ('ko', '韩语'),
    ('fr', '法语'),
    ('de', '德语'),
    ('es', '西班牙语'),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _baseUrlCtrl.dispose();
    _apiKeyCtrl.dispose();
    _customModelCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    _engine = await _settings.getTranslationEngine();
    _sourceLang = await _settings.getTranslationSource();
    _targetLang = await _settings.getTranslationTarget();

    _ttsRate = await _settings.getTtsRate();
    _ttsRepeatCount = await _settings.getTtsRepeatCount();
    _ttsPauseMs = await _settings.getTtsPauseMs();
    _ttsVoice = await _settings.getTtsVoice();
    _preferOffline = await _settings.getPreferOffline();

    // 供应商管理加载
    _providers = await _settings.getProviders();
    _activeProviderId =
        (await _settings.getActiveProviderId()) ?? 'siliconflow';
    _activeEmbeddingProviderId =
        (await _settings.getEmbeddingProviderId()) ?? _activeProviderId;
    _currentLlmModel = (await _settings.getApiModel()) ?? '';
    _embeddingModel = await _settings.getEmbeddingModel();

    await _syncActiveProviderToFields();

    // 扫描本地 GGUF 模型
    _localModels = await _scanLocalModels();

    // RAG / 本地模型管理
    _autoLoadLocal = await _settings.getAutoLoadLocalModel();
    _defaultLocalModel = await _settings.getDefaultLocalModel();
    unawaited(_refreshRagStatus());
    unawaited(_refreshVoskStatus());

    // 检查本地大模型引擎 (llama.android) 是否可用（Full 增强版 vs Standard 标准版）
    await _refreshLlmEngineStatus();

    // 检查常用语言模型下载状态
    for (final (code, _) in _langs) {
      final ok = await _mlkit.isModelDownloaded(code);
      _modelStatus[code] = ok;
    }
    if (mounted) setState(() => _initDone = true);
  }

  ApiProvider get _activeProvider {
    return _providers.firstWhere(
      (p) => p.id == _activeProviderId,
      orElse:
          () =>
              _providers.isNotEmpty
                  ? _providers.first
                  : const ApiProvider(
                    id: 'default',
                    name: '默认供应商',
                    baseUrl: '',
                    apiKey: '',
                  ),
    );
  }

  ApiProvider get _activeEmbeddingProvider {
    return _providers.firstWhere(
      (p) => p.id == _activeEmbeddingProviderId,
      orElse: () => _activeProvider,
    );
  }

  Future<void> _syncActiveProviderToFields() async {
    final p = _activeProvider;
    _baseUrlCtrl.text = p.baseUrl;
    _apiKeyCtrl.text = p.apiKey;

    // 记忆模型：若当前已有生效模型且在列表中则保留，否则优先用列表第一个
    if (_currentLlmModel.isEmpty || !p.models.contains(_currentLlmModel)) {
      if (p.models.isNotEmpty) {
        _currentLlmModel = p.models.first;
      }
    }
    _customModelCtrl.text = _currentLlmModel;

    // 同步写入活跃 API 设置
    if (p.baseUrl.isNotEmpty) {
      await _settings.setApiBaseUrl(p.baseUrl);
    }
    await _settings.setApiKey(p.apiKey);
    if (_currentLlmModel.isNotEmpty) {
      await _settings.setApiModel(_currentLlmModel);
    }
  }

  Future<void> _saveEngine(String v) async {
    await _settings.setTranslationEngine(v);
    setState(() => _engine = v);
  }

  Future<void> _toggleDownload(String code) async {
    setState(() => _modelBusy[code] = true);
    try {
      final ok = await _mlkit.downloadModel(code);
      _modelStatus[code] = ok;
      if (ok && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('${_langName(code)} 模型下载完成')));
      }
    } finally {
      if (mounted) setState(() => _modelBusy.remove(code));
    }
  }

  Future<void> _deleteModel(String code) async {
    setState(() => _modelBusy[code] = true);
    try {
      await _mlkit.deleteModel(code);
      _modelStatus[code] = false;
    } finally {
      if (mounted) setState(() => _modelBusy.remove(code));
    }
  }

  String _langName(String code) {
    for (final (c, n) in _langs) {
      if (c == code) return n;
    }
    return code;
  }

  Future<void> _saveSourceLang(String v) async {
    await _settings.setTranslationSource(v);
    setState(() => _sourceLang = v);
  }

  Future<void> _saveTargetLang(String v) async {
    await _settings.setTranslationTarget(v);
    setState(() => _targetLang = v);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body:
          _initDone
              ? ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
                children: [
                  _buildSectionTitle('翻译引擎'),
                  _buildEngineSelector(),
                  const SizedBox(height: 24),

                  _buildSectionTitle('翻译语种'),
                  _buildLanguageSelector(),
                  const SizedBox(height: 24),

                  _buildSectionTitle('离线翻译模型'),
                  _buildModelList(),
                  const SizedBox(height: 24),

                  // [v0.1.44] 朗读参数迁移至离线翻译模型下方
                  _buildSectionTitle('朗读参数'),
                  _buildTtsParams(),
                  const SizedBox(height: 24),

                  _buildSectionTitle('语音识别模型（Vosk 跟读）'),
                  _buildVoskSection(),
                  const SizedBox(height: 24),

                  _buildSectionTitle('云端 AI 供应商'),
                  _buildProviderSection(),
                  const SizedBox(height: 24),

                  _buildSectionTitle('RAG 知识库'),
                  _buildRagSection(),
                  const SizedBox(height: 24),

                  // [v0.1.44] 本地大模型管理（合入 AI 离线优先）
                  _buildSectionTitle('本地大模型管理'),
                  _buildLocalModelManager(),
                ],
              )
              : const Center(child: CircularProgressIndicator()),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(title, style: titleStyle(fontSize: 16)),
    );
  }

  // ===== 1. 翻译引擎（优化为下拉选择模式） =====

  Widget _buildEngineSelector() {
    final options = [
      ('auto', '智能自动', '云端优先 → 本地 AI → 谷歌机器翻译 逐级自动回落'),
      ('cloud', '云端大模型', 'OpenAI 兼容 API，翻译质量最高'),
      ('llm', '本地大模型', '本地 GGUF 模型，无网强语义'),
      ('mlkit', '离线快速', '谷歌机器翻译，极速轻量无需联网'),
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const SizedBox(width: 8),
                const Icon(
                  Icons.auto_mode,
                  size: 20,
                  color: StudyPalette.ember,
                ),
                const SizedBox(width: 8),
                Text('翻译引擎', style: titleStyle(fontSize: 14)),
                const Spacer(),
                DropdownButton<String>(
                  value: _engine,
                  underline: const SizedBox(),
                  items:
                      options.map((opt) {
                        return DropdownMenuItem(
                          value: opt.$1,
                          child: Text(
                            opt.$2,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight:
                                  _engine == opt.$1
                                      ? FontWeight.w600
                                      : FontWeight.normal,
                              color:
                                  _engine == opt.$1
                                      ? StudyPalette.ember
                                      : StudyPalette.onSurfaceResolved(context),
                            ),
                          ),
                        );
                      }).toList(),
                  onChanged: (v) {
                    if (v != null) _saveEngine(v);
                  },
                ),
              ],
            ),
            const Divider(height: 8, indent: 8),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 2),
              child: Text(
                options
                    .firstWhere(
                      (o) => o.$1 == _engine,
                      orElse: () => options.first,
                    )
                    .$3,
                style: const TextStyle(
                  fontSize: 12,
                  color: StudyPalette.inkSoft,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ===== 2. 翻译语种 =====

  Widget _buildLanguageSelector() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const SizedBox(width: 8),
                const Icon(Icons.translate, size: 20, color: StudyPalette.ink),
                const SizedBox(width: 8),
                Text('源语种', style: titleStyle(fontSize: 14)),
                const Spacer(),
                DropdownButton<String>(
                  value: _sourceLang,
                  underline: const SizedBox(),
                  items:
                      _sourceOptions.map((opt) {
                        return DropdownMenuItem(
                          value: opt.$1,
                          child: Text(
                            opt.$2,
                            style: const TextStyle(
                              color: StudyPalette.ink,
                              fontSize: 14,
                            ),
                          ),
                        );
                      }).toList(),
                  onChanged: (v) {
                    if (v != null) _saveSourceLang(v);
                  },
                ),
              ],
            ),
            const Divider(height: 16, indent: 8),
            Row(
              children: [
                const SizedBox(width: 8),
                const Icon(
                  Icons.g_translate,
                  size: 20,
                  color: StudyPalette.ink,
                ),
                const SizedBox(width: 8),
                Text('目标语种', style: titleStyle(fontSize: 14)),
                const Spacer(),
                DropdownButton<String>(
                  value: _targetLang,
                  underline: const SizedBox(),
                  items:
                      _langs.map((opt) {
                        return DropdownMenuItem(
                          value: opt.$1,
                          child: Text(
                            opt.$2,
                            style: const TextStyle(
                              color: StudyPalette.ink,
                              fontSize: 14,
                            ),
                          ),
                        );
                      }).toList(),
                  onChanged: (v) {
                    if (v != null) _saveTargetLang(v);
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Padding(
              padding: EdgeInsets.only(left: 8),
              child: Text(
                '源语种选「自动识别」时，App 会先检测原文语种再翻译',
                style: TextStyle(fontSize: 12, color: StudyPalette.inkSoft),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ===== 3. 离线翻译模型 =====

  Widget _buildModelList() {
    return Card(
      child: Column(
        children: [
          for (var i = 0; i < _langs.length; i++)
            _buildModelTile(_langs[i].$1, _langs[i].$2, i == _langs.length - 1),
        ],
      ),
    );
  }

  Widget _buildModelTile(String code, String name, bool isLast) {
    final downloaded = _modelStatus[code] ?? false;
    final busy = _modelBusy[code] ?? false;

    return Column(
      children: [
        ListTile(
          dense: true,
          title: Text(name, style: const TextStyle(fontSize: 14)),
          subtitle: Text(
            downloaded ? '已下载' : '未下载',
            style: TextStyle(
              fontSize: 12,
              color: downloaded ? StudyPalette.moss : StudyPalette.inkSoft,
            ),
          ),
          trailing:
              busy
                  ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                  : downloaded
                  ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.check_circle,
                        color: StudyPalette.moss,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        height: 28,
                        child: TextButton(
                          onPressed: () => _deleteModel(code),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            foregroundColor: StudyPalette.inkSoft,
                            textStyle: const TextStyle(fontSize: 12),
                          ),
                          child: const Text('删除'),
                        ),
                      ),
                    ],
                  )
                  : SizedBox(
                    height: 28,
                    child: FilledButton(
                      onPressed: () => _toggleDownload(code),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        textStyle: const TextStyle(fontSize: 12),
                      ),
                      child: const Text('下载'),
                    ),
                  ),
        ),
        if (!isLast) const Divider(height: 1, indent: 16),
      ],
    );
  }

  // ===== 4. 朗读参数（迁移至此，彻底打通） =====

  Widget _buildTtsParams() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 语速
            Row(
              children: [
                const Icon(Icons.speed, size: 20, color: StudyPalette.ink),
                const SizedBox(width: 8),
                Text('语速', style: titleStyle(fontSize: 14)),
                const Spacer(),
                Text(
                  '${_ttsRate.toStringAsFixed(1)}x',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: StudyPalette.ember,
                  ),
                ),
              ],
            ),
            Slider(
              value: _ttsRate,
              min: 0.5,
              max: 2.0,
              divisions: 15,
              label: '${_ttsRate.toStringAsFixed(1)}x',
              activeColor: StudyPalette.ember,
              onChanged: (v) {
                setState(() => _ttsRate = v);
                _tts.setRate(v);
              },
              onChangeEnd: (v) => _settings.setTtsRate(v),
            ),
            const Divider(height: 8),

            // 单句重复遍数
            Row(
              children: [
                const Icon(Icons.repeat, size: 20, color: StudyPalette.ink),
                const SizedBox(width: 8),
                Text('单句重复遍数', style: titleStyle(fontSize: 14)),
                const Spacer(),
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.remove_circle_outline),
                      onPressed:
                          _ttsRepeatCount > 1
                              ? () {
                                setState(() => _ttsRepeatCount--);
                                _settings.setTtsRepeatCount(_ttsRepeatCount);
                              }
                              : null,
                    ),
                    Text(
                      '$_ttsRepeatCount',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: StudyPalette.ember,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.add_circle_outline),
                      onPressed:
                          _ttsRepeatCount < 5
                              ? () {
                                setState(() => _ttsRepeatCount++);
                                _settings.setTtsRepeatCount(_ttsRepeatCount);
                              }
                              : null,
                    ),
                  ],
                ),
              ],
            ),
            const Divider(height: 8),

            // 连读句间停顿
            Row(
              children: [
                const Icon(
                  Icons.timer_outlined,
                  size: 20,
                  color: StudyPalette.ink,
                ),
                const SizedBox(width: 8),
                Text('连读句间停顿', style: titleStyle(fontSize: 14)),
                const Spacer(),
                Text(
                  '${_ttsPauseMs}ms',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: StudyPalette.ember,
                  ),
                ),
              ],
            ),
            Slider(
              value: _ttsPauseMs.toDouble(),
              min: 0,
              max: 1000,
              divisions: 10,
              label: '${_ttsPauseMs}ms',
              activeColor: StudyPalette.ember,
              onChanged: (v) => setState(() => _ttsPauseMs = v.round()),
              onChangeEnd: (v) => _settings.setTtsPauseMs(v.round()),
            ),
            const Divider(height: 8),

            // 音色选择
            Row(
              children: [
                const Icon(
                  Icons.record_voice_over,
                  size: 20,
                  color: StudyPalette.ink,
                ),
                const SizedBox(width: 8),
                Text('朗读音色', style: titleStyle(fontSize: 14)),
                const Spacer(),
                DropdownButton<String>(
                  value: _ttsVoice.isEmpty ? 'default' : _ttsVoice,
                  underline: const SizedBox(),
                  items: const [
                    DropdownMenuItem(value: 'default', child: Text('系统默认')),
                    DropdownMenuItem(value: 'zh-CN', child: Text('中文女声')),
                    DropdownMenuItem(
                      value: 'zh-CN-x-xiaoxuan',
                      child: Text('晓萱'),
                    ),
                    DropdownMenuItem(
                      value: 'zh-CN-x-xiaochen',
                      child: Text('晓辰'),
                    ),
                    DropdownMenuItem(
                      value: 'zh-CN-x-xiaohan',
                      child: Text('晓涵'),
                    ),
                    DropdownMenuItem(
                      value: 'zh-CN-x-xiaomo',
                      child: Text('晓墨'),
                    ),
                    DropdownMenuItem(
                      value: 'zh-CN-x-xiaorui',
                      child: Text('晓睿'),
                    ),
                    DropdownMenuItem(
                      value: 'zh-CN-x-xiaoyou',
                      child: Text('晓悠'),
                    ),
                    DropdownMenuItem(value: 'zh-HK', child: Text('粤语女声')),
                    DropdownMenuItem(value: 'en-US', child: Text('英语美音')),
                    DropdownMenuItem(value: 'en-GB', child: Text('英语英音')),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    final voice = v == 'default' ? '' : v;
                    setState(() => _ttsVoice = voice);
                    _settings.setTtsVoice(voice);
                    _tts.setVoice(voice);
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ===== 5. Vosk 语音模型（模型名称 + 删除按钮，不展示冗余绝对路径） =====

  Future<void> _refreshVoskStatus() async {
    final path = await _settings.getVoskModelPath();
    var exists = false;
    if (path != null && path.isNotEmpty) {
      exists = await Directory(path).exists();
    }
    final loaded = VoskAsrService().isLoaded;
    if (mounted) {
      setState(() {
        _voskModelPath = path;
        _voskModelExists = exists;
        _voskLoaded = loaded;
      });
    }
  }

  Widget _buildVoskSection() {
    final hasConfig = _voskModelPath != null && _voskModelPath!.isNotEmpty;
    final modelName = hasConfig ? p.basename(_voskModelPath!) : '未配置';
    final statusText =
        !hasConfig
            ? '未配置语音模型'
            : (!_voskModelExists
                ? '模型文件已丢失'
                : (_voskLoaded ? '模型已就绪 ✓' : '已配置（跟读时自动加载）'));
    final statusColor =
        !hasConfig || !_voskModelExists
            ? StudyPalette.ember
            : (_voskLoaded ? StudyPalette.moss : StudyPalette.inkSoft);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _voskBusy ? '操作中…' : '模型：$modelName',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: StudyPalette.ink,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        statusText,
                        style: TextStyle(
                          fontSize: 12,
                          color: statusColor,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_voskBusy)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else if (hasConfig && _voskModelExists)
                  IconButton(
                    icon: const Icon(
                      Icons.delete_outline,
                      size: 20,
                      color: StudyPalette.ember,
                    ),
                    tooltip: '删除此模型',
                    onPressed: _confirmDeleteVoskModel,
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.download, size: 16),
                    label: const Text('在线下载', style: TextStyle(fontSize: 12)),
                    onPressed: _voskBusy ? null : _downloadVoskModel,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.file_open, size: 16),
                    label: const Text(
                      '从 zip 导入',
                      style: TextStyle(fontSize: 12),
                    ),
                    onPressed: _voskBusy ? null : _importVoskModel,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDeleteVoskModel() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('删除 Vosk 语音模型'),
            content: const Text('确定要删除当前配置的 Vosk 语音模型吗？删除后可随时重新下载或导入。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: StudyPalette.ember,
                ),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('删除'),
              ),
            ],
          ),
    );
    if (confirm != true || !mounted) return;

    setState(() => _voskBusy = true);
    try {
      if (_voskModelPath != null && _voskModelPath!.isNotEmpty) {
        final dir = Directory(_voskModelPath!);
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      }
      await _settings.setVoskModelPath('');
      await _refreshVoskStatus();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Vosk 语音模型已删除')));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('删除失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _voskBusy = false);
    }
  }

  Future<void> _downloadVoskModel() async {
    setState(() => _voskBusy = true);
    try {
      final modelPath = await ModelStore.ensureVoskCnModel();
      await SettingsService.instance.setVoskModelPath(modelPath);
      await _refreshVoskStatus();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Vosk 中文模型下载完成 ✓')));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Vosk 下载失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _voskBusy = false);
    }
  }

  Future<void> _importVoskModel() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['zip'],
      dialogTitle: '选择 Vosk 模型 zip 文件',
    );
    if (result == null || result.files.isEmpty || !mounted) return;
    final path = result.files.single.path;
    if (path == null) return;
    setState(() => _voskBusy = true);
    try {
      final modelPath = await ModelStore.importFromZip(path);
      await SettingsService.instance.setVoskModelPath(modelPath);
      await _refreshVoskStatus();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Vosk 模型导入成功 ✓')));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Vosk 导入失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _voskBusy = false);
    }
  }

  // ===== 6. 云端 AI 供应商管理（支持多 Provider + 一键拉取模型列表 + 下拉选择） =====

  Widget _buildProviderSection() {
    final current = _activeProvider;
    final modelList = current.models;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 供应商选择行 + 新增/删除操作
            Row(
              children: [
                const Icon(
                  Icons.cloud_outlined,
                  size: 20,
                  color: StudyPalette.ink,
                ),
                const SizedBox(width: 8),
                Text('供应商', style: titleStyle(fontSize: 14)),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButton<String>(
                    value: _activeProviderId,
                    isExpanded: true,
                    underline: const SizedBox(),
                    items:
                        _providers.map((p) {
                          return DropdownMenuItem(
                            value: p.id,
                            child: Text(
                              p.name,
                              style: const TextStyle(fontSize: 13),
                              overflow: TextOverflow.ellipsis,
                            ),
                          );
                        }).toList(),
                    onChanged: (id) async {
                      if (id == null) return;
                      setState(() => _activeProviderId = id);
                      await _settings.setActiveProviderId(id);
                      await _syncActiveProviderToFields();
                    },
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add, size: 20),
                  tooltip: '添加供应商',
                  onPressed: _showAddProviderDialog,
                ),
                if (_providers.length > 1)
                  IconButton(
                    icon: const Icon(
                      Icons.delete_outline,
                      size: 20,
                      color: StudyPalette.ember,
                    ),
                    tooltip: '删除当前供应商',
                    onPressed: _deleteCurrentProvider,
                  ),
              ],
            ),
            const Divider(height: 12),

            // Base URL
            TextField(
              controller: _baseUrlCtrl,
              decoration: const InputDecoration(
                labelText: 'API 地址 (Base URL)',
                hintText: 'https://api.siliconflow.cn/v1',
                isDense: true,
              ),
              onChanged: (v) => _updateActiveProvider(baseUrl: v.trim()),
            ),
            const SizedBox(height: 10),

            // API Key
            TextField(
              controller: _apiKeyCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'API Key',
                hintText: 'sk-...',
                isDense: true,
              ),
              onChanged: (v) => _updateActiveProvider(apiKey: v.trim()),
            ),
            const SizedBox(height: 10),

            // 大语言模型选择框（Dropdown 下拉 + 获取按钮）
            Row(
              children: [
                Expanded(
                  child:
                      modelList.isNotEmpty
                          ? DropdownButtonFormField<String>(
                            initialValue:
                                modelList.contains(_currentLlmModel)
                                    ? _currentLlmModel
                                    : (modelList.isNotEmpty
                                        ? modelList.first
                                        : null),
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: 'LLM 对话模型',
                              isDense: true,
                            ),
                            items:
                                modelList.map((m) {
                                  return DropdownMenuItem(
                                    value: m,
                                    child: SingleChildScrollView(
                                      scrollDirection: Axis.horizontal,
                                      child: Text(
                                        m,
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                    ),
                                  );
                                }).toList(),
                            onChanged: (v) async {
                              if (v != null) {
                                setState(() => _currentLlmModel = v);
                                await _settings.setApiModel(v);
                              }
                            },
                          )
                          : TextField(
                            controller: _customModelCtrl,
                            decoration: const InputDecoration(
                              labelText: 'LLM 模型名称',
                              hintText: 'gpt-4o-mini',
                              isDense: true,
                            ),
                            onChanged: (v) async {
                              final text = v.trim();
                              setState(() => _currentLlmModel = text);
                              await _settings.setApiModel(text);
                            },
                          ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: 42,
                  child: FilledButton.tonal(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                    onPressed: _fetchingModels ? null : _fetchModelsFromApi,
                    child: Text(
                      _fetchingModels ? '获取中…' : '获取模型',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '已加载 ${modelList.length} 个模型',
                  style: const TextStyle(
                    fontSize: 12,
                    color: StudyPalette.inkSoft,
                  ),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.add, size: 14),
                  label: const Text('手动添加模型', style: TextStyle(fontSize: 12)),
                  onPressed: _showAddCustomModelDialog,
                ),
              ],
            ),
            const SizedBox(height: 10),
            // 测试 LLM 连接按钮
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.smart_toy_outlined, size: 16),
                label: const Text('测试 LLM 连接'),
                onPressed: _testLlmConnection,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _updateActiveProvider({
    String? baseUrl,
    String? apiKey,
    List<String>? models,
  }) {
    final cur = _activeProvider;
    final updated = cur.copyWith(
      baseUrl: baseUrl ?? cur.baseUrl,
      apiKey: apiKey ?? cur.apiKey,
      models: models ?? cur.models,
    );
    final list = _providers.map((p) => p.id == cur.id ? updated : p).toList();
    setState(() => _providers = list);
    _settings.setProviders(list);
    if (baseUrl != null) _settings.setApiBaseUrl(baseUrl);
    if (apiKey != null) _settings.setApiKey(apiKey);
  }

  Future<void> _fetchModelsFromApi() async {
    final cur = _activeProvider;
    if (cur.baseUrl.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先填写 API 地址')));
      return;
    }
    setState(() => _fetchingModels = true);
    try {
      final url =
          '${cur.baseUrl.endsWith('/') ? cur.baseUrl : '${cur.baseUrl}/'}models';
      final headers = <String, String>{};
      if (cur.apiKey.isNotEmpty) {
        headers['Authorization'] = 'Bearer ${cur.apiKey}';
      }
      final resp = await http
          .get(Uri.parse(url), headers: headers)
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode == 200) {
        final json = jsonDecode(resp.body) as Map<String, dynamic>;
        final data = json['data'] as List?;
        if (data != null && data.isNotEmpty) {
          final fetched =
              data
                  .map((e) => (e as Map<String, dynamic>)['id']?.toString())
                  .where((e) => e != null && e.isNotEmpty)
                  .cast<String>()
                  .toList();
          _updateActiveProvider(models: fetched);
          if (fetched.isNotEmpty) {
            await _settings.setApiModel(fetched.first);
          }
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('成功获取到 ${fetched.length} 个模型')),
            );
          }
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('获取模型失败: HTTP ${resp.statusCode}')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('获取模型失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _fetchingModels = false);
    }
  }

  Future<void> _showAddProviderDialog() async {
    final nameCtrl = TextEditingController();
    final urlCtrl = TextEditingController();
    final keyCtrl = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('添加供应商'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: '供应商名称',
                    hintText: '如：我的本地 Ollama',
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: urlCtrl,
                  decoration: const InputDecoration(
                    labelText: 'API 地址',
                    hintText: 'https://...',
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: keyCtrl,
                  decoration: const InputDecoration(
                    labelText: 'API Key (选填)',
                    hintText: 'sk-...',
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('添加'),
              ),
            ],
          ),
    );

    if (ok == true && nameCtrl.text.trim().isNotEmpty && mounted) {
      final newP = ApiProvider(
        id: newModelId('prov'),
        name: nameCtrl.text.trim(),
        baseUrl: urlCtrl.text.trim(),
        apiKey: keyCtrl.text.trim(),
      );
      final list = [..._providers, newP];
      setState(() {
        _providers = list;
        _activeProviderId = newP.id;
      });
      await _settings.setProviders(list);
      await _settings.setActiveProviderId(newP.id);
      _syncActiveProviderToFields();
    }
  }

  Future<void> _deleteCurrentProvider() async {
    if (_providers.length <= 1) return;
    final cur = _activeProvider;
    final confirm = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('删除供应商'),
            content: Text('确定要删除供应商「${cur.name}」吗？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: StudyPalette.ember,
                ),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('删除'),
              ),
            ],
          ),
    );
    if (confirm == true && mounted) {
      final list = _providers.where((p) => p.id != cur.id).toList();
      setState(() {
        _providers = list;
        _activeProviderId = list.first.id;
      });
      await _settings.setProviders(list);
      await _settings.setActiveProviderId(list.first.id);
      await _syncActiveProviderToFields();
    }
  }

  Future<void> _testLlmConnection() async {
    final configured = await _settings.isApiConfigured();
    if (!configured) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('⚠️ 请先配置云端 API 地址、密钥与模型')));
      }
      return;
    }
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('正在测试 LLM 对话连接…')));
    }
    try {
      final client = OpenAiClient();
      final url = await _settings.getApiBaseUrl() ?? '';
      final key = await _settings.getApiKey() ?? '';
      final model = await _settings.getApiModel() ?? '';
      final answer = await client.chat(
        user: '你好，请用简短一句话回复“连接成功”。',
        baseUrl: url,
        apiKey: key,
        model: model,
      );
      if (!mounted) return;
      if (answer != null && answer.isNotEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('✅ LLM 连接正常：$answer')));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('❌ LLM 测试失败，返回内容为空，请检查模型名称或配置')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('❌ LLM 连接失败: $e')));
      }
    }
  }

  Future<void> _showAddCustomModelDialog() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('手动添加模型'),
            content: TextField(
              controller: ctrl,
              decoration: const InputDecoration(
                labelText: '模型名称',
                hintText: '如：gpt-4o-mini',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('添加'),
              ),
            ],
          ),
    );
    if (ok == true && ctrl.text.trim().isNotEmpty) {
      final cur = _activeProvider;
      final m = ctrl.text.trim();
      if (!cur.models.contains(m)) {
        _updateActiveProvider(models: [...cur.models, m]);
        await _settings.setApiModel(m);
      }
    }
  }

  // ===== 7. RAG 知识库 =====

  Future<void> _refreshRagStatus() async {
    final indexed = await RagRetrievalService.instance.listIndexedBooks();
    if (mounted) setState(() => _indexedBooks = indexed);
  }

  Widget _buildRagSection() {
    final embProvider = _activeEmbeddingProvider;
    final models = embProvider.models;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 独立的 Embedding 供应商选择行
            Row(
              children: [
                const Icon(
                  Icons.cloud_outlined,
                  size: 20,
                  color: StudyPalette.ink,
                ),
                const SizedBox(width: 8),
                Text('向量供应商', style: titleStyle(fontSize: 14)),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButton<String>(
                    value:
                        _providers.any(
                              (p) => p.id == _activeEmbeddingProviderId,
                            )
                            ? _activeEmbeddingProviderId
                            : (_providers.isNotEmpty
                                ? _providers.first.id
                                : 'default'),
                    isExpanded: true,
                    underline: const SizedBox(),
                    items:
                        _providers.map((p) {
                          return DropdownMenuItem(
                            value: p.id,
                            child: Text(
                              p.name,
                              style: const TextStyle(fontSize: 13),
                              overflow: TextOverflow.ellipsis,
                            ),
                          );
                        }).toList(),
                    onChanged: (id) async {
                      if (id == null) return;
                      final selectedP = _providers.firstWhere(
                        (p) => p.id == id,
                        orElse: () => _activeProvider,
                      );
                      setState(() => _activeEmbeddingProviderId = id);
                      await _settings.setEmbeddingProviderId(id);
                      await _settings.setEmbeddingBaseUrl(selectedP.baseUrl);
                      await _settings.setEmbeddingApiKey(selectedP.apiKey);
                    },
                  ),
                ),
              ],
            ),
            const Divider(height: 12),

            // Embedding 模型选择（支持下拉或手动输入）
            Row(
              children: [
                const Icon(
                  Icons.auto_awesome,
                  size: 20,
                  color: StudyPalette.ink,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child:
                      models.isNotEmpty
                          ? DropdownButtonFormField<String>(
                            initialValue:
                                models.contains(_embeddingModel)
                                    ? _embeddingModel
                                    : (models.isNotEmpty ? models.first : null),
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: 'Embedding 向量模型',
                              isDense: true,
                            ),
                            items:
                                models.map((m) {
                                  return DropdownMenuItem(
                                    value: m,
                                    child: SingleChildScrollView(
                                      scrollDirection: Axis.horizontal,
                                      child: Text(
                                        m,
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                    ),
                                  );
                                }).toList(),
                            onChanged: (v) async {
                              if (v != null) {
                                setState(() => _embeddingModel = v);
                                await _settings.setEmbeddingModel(v);
                              }
                            },
                          )
                          : TextField(
                            controller: TextEditingController(
                              text: _embeddingModel,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Embedding 向量模型',
                              hintText: 'text-embedding-3-small',
                              isDense: true,
                            ),
                            onChanged: (v) async {
                              final text = v.trim();
                              setState(() => _embeddingModel = text);
                              await _settings.setEmbeddingModel(text);
                            },
                          ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // 测试 Embedding 按钮
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.play_arrow, size: 16),
                label: const Text('测试 Embedding 连接'),
                onPressed: () async {
                  final ok = await EmbeddingService.instance.isCloudReady();
                  if (!mounted) return;
                  if (ok) {
                    final result = await EmbeddingService.instance.embed('测试');
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          result != null
                              ? '✅ Embedding 连接正常（返回 ${result.length} 维向量）'
                              : '❌ Embedding 调用失败，请检查 API 配置',
                        ),
                      ),
                    );
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('⚠️ 请先配置云端 API 地址与密钥')),
                    );
                  }
                },
              ),
            ),
            const SizedBox(height: 12),
            // 索引状态（点击弹出已索引书籍列表详情）
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: _indexedBooks.isEmpty ? null : _showIndexedBooksDialog,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    const Icon(
                      Icons.storage,
                      size: 18,
                      color: StudyPalette.inkSoft,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '已索引 ${_indexedBooks.length} 本书籍',
                        style: const TextStyle(
                          fontSize: 13,
                          color: StudyPalette.inkSoft,
                        ),
                      ),
                    ),
                    if (_indexedBooks.isNotEmpty)
                      const Icon(
                        Icons.chevron_right,
                        size: 16,
                        color: StudyPalette.inkSoft,
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showIndexedBooksDialog() async {
    final db = await DatabaseProvider.database;
    final bookDao = BookDao(db);
    final allBooks = await bookDao.getAll();
    final bookMap = {for (final b in allBooks) b.id: b.title};

    if (!mounted) return;
    showDialog(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('已向量化书籍列表'),
            content: SizedBox(
              width: double.maxFinite,
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _indexedBooks.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final bookId = _indexedBooks[i];
                  final title = bookMap[bookId] ?? '未知书籍 ($bookId)';
                  return ListTile(
                    dense: true,
                    leading: const Icon(
                      Icons.auto_stories,
                      size: 20,
                      color: StudyPalette.spinePdf,
                    ),
                    title: Text(
                      title,
                      style: const TextStyle(
                        fontSize: 14,
                        color: StudyPalette.ink,
                      ),
                    ),
                    trailing: IconButton(
                      icon: const Icon(
                        Icons.delete_outline,
                        size: 18,
                        color: StudyPalette.ember,
                      ),
                      tooltip: '清理此书索引',
                      onPressed: () async {
                        await RagRetrievalService.instance.deleteIndex(bookId);
                        await _refreshRagStatus();
                        if (!ctx.mounted) return;
                        Navigator.pop(ctx);
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('已清除《$title》的向量索引')),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('关闭'),
              ),
            ],
          ),
    );
  }

  // ===== 8. 本地大模型管理（合入 AI 离线优先 + 模型弹窗选择与删除） =====

  static const _presetModels = [
    (
      'Qwen3-0.6B Q8_0 (~670MB)',
      'Qwen3-0.6B-Q8_0.gguf',
      'https://modelscope.cn/models/Qwen/Qwen3-0.6B-GGUF/resolve/master/Qwen3-0.6B-Q8_0.gguf',
    ),
    (
      'MiniCPM5-1B Q4_K_M (~650MB)',
      'MiniCPM5-1B-Q4_K_M.gguf',
      'https://modelscope.cn/models/OpenBMB/MiniCPM5-1B-GGUF/resolve/master/MiniCPM5-1B-Q4_K_M.gguf',
    ),
  ];

  Future<void> _refreshLlmEngineStatus() async {
    try {
      final available = await LlmService.instance.isAvailable();
      if (mounted) setState(() => _llmEngineAvailable = available);
    } catch (_) {
      if (mounted) setState(() => _llmEngineAvailable = false);
    }
  }

  Widget _buildLocalModelManager() {
    // 获取当前默认模型文件名
    final currentDefaultName =
        _defaultLocalModel != null && _defaultLocalModel!.isNotEmpty
            ? p.basename(_defaultLocalModel!)
            : '未配置（点击选择）';
    final hasDefault =
        _defaultLocalModel != null && _defaultLocalModel!.isNotEmpty;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 引擎状态指示
            Row(
              children: [
                Icon(
                  _llmEngineAvailable
                      ? Icons.check_circle
                      : Icons.extension_outlined,
                  size: 20,
                  color:
                      _llmEngineAvailable
                          ? StudyPalette.moss
                          : StudyPalette.ember,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _llmEngineAvailable
                        ? '本地推理引擎已就绪'
                        : '本地引擎未加载（需 Android 10+ 且支持 arm64）',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color:
                          _llmEngineAvailable
                              ? StudyPalette.moss
                              : StudyPalette.ember,
                    ),
                  ),
                ),
              ],
            ),
            const Divider(height: 16),

            // [v0.1.44] 合入优先离线开关
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text(
                '优先使用离线 AI',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
              ),
              subtitle: const Text(
                '开启后知识提取/翻译优先走本地模型，云端作兜底',
                style: TextStyle(fontSize: 12, color: StudyPalette.inkSoft),
              ),
              value: _preferOffline,
              activeThumbColor: StudyPalette.ember,
              onChanged: (v) {
                setState(() => _preferOffline = v);
                _settings.setPreferOffline(v);
              },
            ),
            const Divider(height: 8),

            // 自动加载开关
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'AI 对话时自动加载本地模型',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
              ),
              subtitle: const Text(
                '空闲 10 分钟或退出时自动卸载',
                style: TextStyle(fontSize: 12, color: StudyPalette.inkSoft),
              ),
              value: _autoLoadLocal,
              activeThumbColor: StudyPalette.ember,
              onChanged: (v) {
                setState(() => _autoLoadLocal = v);
                _settings.setAutoLoadLocalModel(v);
              },
            ),
            const Divider(height: 8),

            // 当前配置的模型卡片（点击弹出选择列表弹窗）
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                hasDefault ? Icons.check_circle : Icons.model_training,
                color: hasDefault ? StudyPalette.moss : StudyPalette.inkSoft,
                size: 24,
              ),
              title: Text(
                '当前生效模型：$currentDefaultName',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color:
                      hasDefault
                          ? StudyPalette.onSurfaceResolved(context)
                          : StudyPalette.inkSoft,
                ),
              ),
              subtitle: Text(
                '已导入 ${_localModels.length} 个模型 · 点击切换或管理模型',
                style: const TextStyle(
                  fontSize: 12,
                  color: StudyPalette.inkSoft,
                ),
              ),
              trailing: const Icon(
                Icons.chevron_right,
                size: 20,
                color: StudyPalette.inkSoft,
              ),
              onTap: _showLocalModelSelectorDialog,
            ),
            const Divider(height: 8),

            // 模型操作按钮栏：加载/卸载模型 + 测试本地推理
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: Icon(
                      LlmService.instance.isLoaded
                          ? Icons.eject_outlined
                          : Icons.play_arrow_outlined,
                      size: 16,
                      color:
                          LlmService.instance.isLoaded
                              ? StudyPalette.ember
                              : StudyPalette.moss,
                    ),
                    label: Text(
                      LlmService.instance.isLoaded ? '卸载模型' : '加载模型',
                      style: const TextStyle(fontSize: 12),
                    ),
                    onPressed:
                        !hasDefault
                            ? null
                            : () async {
                              if (LlmService.instance.isLoaded) {
                                await LlmService.instance.unload();
                                if (!mounted) return;
                                setState(() {});
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('已卸载当前本地大模型')),
                                );
                              } else {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('正在加载本地模型，请稍候…'),
                                  ),
                                );
                                final ok = await LlmService.instance.init(
                                  _defaultLocalModel!,
                                );
                                if (!mounted) return;
                                setState(() {});
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      ok ? '✅ 本地模型加载成功！' : '❌ 本地模型加载失败，请检查文件',
                                    ),
                                  ),
                                );
                              }
                            },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.bolt, size: 16),
                    label: const Text('测试推理', style: TextStyle(fontSize: 12)),
                    onPressed:
                        !hasDefault
                            ? null
                            : () async {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('正在测试本地大模型推理…')),
                              );
                              if (!LlmService.instance.isLoaded) {
                                final ok = await LlmService.instance.init(
                                  _defaultLocalModel!,
                                );
                                if (!ok) {
                                  if (!mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('❌ 模型加载失败')),
                                  );
                                  return;
                                }
                              }
                              try {
                                final ans = await LlmService.instance.chat(
                                  '请简短回复一句：本地大模型运行正常。',
                                );
                                if (!mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      ans.isNotEmpty
                                          ? '✅ 本地推理成功: $ans'
                                          : '⚠️ 推理完成但未产出有效文本',
                                    ),
                                  ),
                                );
                              } catch (e) {
                                if (!mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('❌ 测试出错: $e')),
                                );
                              }
                            },
                  ),
                ),
              ],
            ),
            const Divider(height: 12),

            // 预设模型下载
            const Text(
              '在线下载预设模型（魔塔社区）',
              style: TextStyle(fontSize: 12, color: StudyPalette.inkSoft),
            ),
            const SizedBox(height: 4),
            for (final (name, filename, url) in _presetModels) ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        name,
                        style: TextStyle(
                          fontSize: 13,
                          color: StudyPalette.onSurfaceResolved(context),
                        ),
                      ),
                    ),
                    SizedBox(
                      height: 28,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          textStyle: const TextStyle(fontSize: 11),
                        ),
                        onPressed:
                            () => _downloadPresetModel(filename, name, url),
                        child: const Text('下载'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const Divider(height: 8),

            // 从外部导入 GGUF
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.file_open, size: 16),
                label: const Text('从文件导入 GGUF 模型'),
                onPressed: () => _importGgufFromFile(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 弹出本地模型选择与管理弹窗：列出所有已导入模型，支持点击选择为默认模型，右侧设置单独删除按钮。
  void _showLocalModelSelectorDialog() {
    showModalBottomSheet(
      context: context,
      backgroundColor:
          Theme.of(context).brightness == Brightness.dark
              ? StudyPalette.darkCard
              : StudyPalette.parchment,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder:
          (ctx) => StatefulBuilder(
            builder: (ctx, setSheetState) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
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
                    Text('选择本地 GGUF 模型', style: titleStyle(fontSize: 16)),
                    const SizedBox(height: 4),
                    const Text(
                      '点击设为当前生效模型，右侧可删除文件',
                      style: TextStyle(
                        fontSize: 12,
                        color: StudyPalette.inkSoft,
                      ),
                    ),
                    const Divider(height: 16),
                    if (_localModels.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Center(
                          child: Text(
                            '暂无已导入的模型文件\n请在设置页在线下载或从文件导入',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 13,
                              color: StudyPalette.inkSoft,
                            ),
                          ),
                        ),
                      )
                    else
                      Flexible(
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: _localModels.length,
                          separatorBuilder:
                              (_, _) => const Divider(height: 1, indent: 8),
                          itemBuilder: (ctx, idx) {
                            final m = _localModels[idx];
                            final isDefault = _defaultLocalModel == m.path;
                            return ListTile(
                              dense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 4,
                              ),
                              leading: Icon(
                                isDefault
                                    ? Icons.check_circle
                                    : Icons.radio_button_unchecked,
                                color:
                                    isDefault
                                        ? StudyPalette.moss
                                        : StudyPalette.inkSoft,
                                size: 20,
                              ),
                              title: Text(
                                m.name,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight:
                                      isDefault
                                          ? FontWeight.w600
                                          : FontWeight.normal,
                                  color:
                                      isDefault
                                          ? StudyPalette.ember
                                          : StudyPalette.onSurfaceResolved(
                                            context,
                                          ),
                                ),
                              ),
                              subtitle: Text(
                                '${_formatSize(m.sizeBytes)}${isDefault ? ' · 当前默认' : ''}',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: StudyPalette.inkSoft,
                                ),
                              ),
                              trailing: IconButton(
                                icon: const Icon(
                                  Icons.delete_outline,
                                  size: 20,
                                  color: StudyPalette.ember,
                                ),
                                tooltip: '删除模型',
                                onPressed: () async {
                                  final deleted = await _confirmDeleteGgufModel(
                                    m,
                                  );
                                  if (deleted && mounted) {
                                    setSheetState(() {});
                                    setState(() {});
                                  }
                                },
                              ),
                              onTap: () async {
                                setState(() => _defaultLocalModel = m.path);
                                await _settings.setDefaultLocalModel(m.path);
                                await _settings.setLocalModelPath(m.path);
                                setSheetState(() {});
                                if (ctx.mounted) {
                                  Navigator.pop(ctx);
                                  ScaffoldMessenger.of(ctx).showSnackBar(
                                    SnackBar(
                                      content: Text('已将 ${m.name} 设为当前生效模型'),
                                    ),
                                  );
                                }
                              },
                            );
                          },
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
    );
  }

  Future<bool> _confirmDeleteGgufModel(_GgufModelInfo info) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('删除本地模型'),
            content: Text('确定要删除模型「${info.name}」吗？文件将被永久删除。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: StudyPalette.ember,
                ),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('删除'),
              ),
            ],
          ),
    );
    if (confirm != true || !mounted) return false;

    try {
      final f = File(info.path);
      if (await f.exists()) {
        await f.delete();
      }
      if (_defaultLocalModel == info.path) {
        _defaultLocalModel = null;
        await _settings.setDefaultLocalModel('');
        await _settings.setLocalModelPath('');
      }
      _localModels = await _scanLocalModels();
      if (_defaultLocalModel == null && _localModels.isNotEmpty) {
        _defaultLocalModel = _localModels.first.path;
        await _settings.setDefaultLocalModel(_defaultLocalModel!);
        await _settings.setLocalModelPath(_defaultLocalModel!);
      }
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('模型 ${info.name} 已删除')));
      }
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('删除失败: $e')));
      }
      return false;
    }
  }

  Future<void> _downloadPresetModel(
    String filename,
    String label,
    String downloadUrl,
  ) async {
    double progress = 0.0;
    int received = 0;
    int total = 0;
    String status = '正在连接魔塔社区…';
    StateSetter? dialogSetState;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder:
          (ctx) => StatefulBuilder(
            builder: (ctx, setDialogState) {
              dialogSetState = setDialogState;
              return AlertDialog(
                title: Text('下载 $label'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LinearProgressIndicator(
                      value: progress > 0 ? progress : null,
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          total > 0
                              ? '${_formatSize(received)} / ${_formatSize(total)}'
                              : _formatSize(received),
                          style: const TextStyle(
                            fontSize: 12,
                            color: StudyPalette.inkSoft,
                          ),
                        ),
                        Text(
                          progress > 0
                              ? '${(progress * 100).toStringAsFixed(1)}%'
                              : '',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      status,
                      style: const TextStyle(
                        fontSize: 11,
                        color: StudyPalette.inkSoft,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
    );

    try {
      final dir = await ModelStore.llmModelsDir();
      final savePath = '${dir.path}/$filename';
      final request = http.Request('GET', Uri.parse(downloadUrl));
      final client = http.Client();
      final response = await client.send(request);
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }
      total = response.contentLength ?? 0;
      final file = File(savePath);
      final sink = file.openWrite();

      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          progress = received / total;
        }
        dialogSetState?.call(() {
          status = '正在下载模型数据…';
        });
      }

      await sink.flush();
      await sink.close();
      client.close();

      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        _localModels = await _scanLocalModels();
        if (!mounted) return;
        setState(() => _defaultLocalModel = savePath);
        await _settings.setDefaultLocalModel(savePath);
        await _settings.setLocalModelPath(savePath);
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('$label 下载完成并已自动配置为生效模型 ✓')));
        }
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('下载失败: $e')));
      }
    }
  }

  Future<void> _importGgufFromFile() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['gguf'],
    );
    if (result == null || result.files.isEmpty || !mounted) return;
    final path = result.files.single.path;
    if (path == null) return;

    double progress = 0.0;
    int copied = 0;
    int total = 0;
    StateSetter? dialogSetState;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder:
          (ctx) => StatefulBuilder(
            builder: (ctx, setDialogState) {
              dialogSetState = setDialogState;
              return AlertDialog(
                title: const Text('正在导入 GGUF 模型'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LinearProgressIndicator(
                      value: progress > 0 ? progress : null,
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          total > 0
                              ? '${_formatSize(copied)} / ${_formatSize(total)}'
                              : _formatSize(copied),
                          style: const TextStyle(
                            fontSize: 12,
                            color: StudyPalette.inkSoft,
                          ),
                        ),
                        Text(
                          progress > 0
                              ? '${(progress * 100).toStringAsFixed(1)}%'
                              : '',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
    );

    try {
      final savedPath = await ModelStore.importGguf(
        path,
        onProgress: (p, c, t) {
          progress = p;
          copied = c;
          total = t;
          dialogSetState?.call(() {});
        },
      );
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      _localModels = await _scanLocalModels();
      if (!mounted) return;
      // 导入后自动设为生效默认模型
      setState(() => _defaultLocalModel = savedPath);
      await _settings.setDefaultLocalModel(savedPath);
      await _settings.setLocalModelPath(savedPath);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('GGUF 模型导入成功并已自动配置为生效模型 ✓')),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('导入失败: $e')));
      }
    }
  }

  Future<List<_GgufModelInfo>> _scanLocalModels() async {
    try {
      final dir = await ModelStore.modelsDir();
      if (!await dir.exists()) return const [];
      final files = <_GgufModelInfo>[];
      await for (final entity in dir.list(recursive: true)) {
        if (entity is! File) continue;
        if (!entity.path.toLowerCase().endsWith('.gguf')) continue;
        final stat = await entity.stat();
        files.add(
          _GgufModelInfo(
            name: entity.uri.pathSegments.last,
            sizeBytes: stat.size,
            path: entity.path,
          ),
        );
      }
      files.sort((a, b) => a.name.compareTo(b.name));
      return files;
    } catch (e) {
      AppLog.e('settings', '扫描 GGUF 模型失败: $e');
      return const [];
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)}GB';
  }
}

class _GgufModelInfo {
  const _GgufModelInfo({
    required this.name,
    required this.sizeBytes,
    required this.path,
  });

  final String name;
  final int sizeBytes;
  final String path;
}
