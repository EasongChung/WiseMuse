import 'package:flutter/material.dart';

import '../../core/settings/settings_service.dart';
import '../../core/theme/app_theme.dart';
import '../../services/mlkit_translation_service.dart';

/// [v0.3.0] 设置页：翻译引擎配置 + 模型下载管理。
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

  // 当前引擎
  String _engine = 'auto';

  // 翻译语种
  String _sourceLang = 'auto';
  String _targetLang = 'en';

  // 模型下载状态（按 BCP-47 代码）
  final Map<String, bool> _modelStatus = {};
  final Map<String, bool> _modelBusy = {};

  // API 配置（云端回落）
  final _baseUrlCtrl = TextEditingController();
  final _apiKeyCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();

  // 朗读参数
  double _ttsRate = 0.9;
  int _ttsRepeatCount = 1;
  int _ttsPauseMs = 300;
  String _ttsVoice = '';

  // AI 离线优先
  bool _preferOffline = false;

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
    _modelCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    _engine = await _settings.getTranslationEngine();
    _sourceLang = await _settings.getTranslationSource();
    _targetLang = await _settings.getTranslationTarget();
    _baseUrlCtrl.text = (await _settings.getApiBaseUrl()) ?? '';
    _apiKeyCtrl.text = (await _settings.getApiKey()) ?? '';
    _modelCtrl.text = (await _settings.getApiModel()) ?? '';
    _ttsRate = await _settings.getTtsRate();
    _ttsRepeatCount = await _settings.getTtsRepeatCount();
    _ttsPauseMs = await _settings.getTtsPauseMs();
    _ttsVoice = await _settings.getTtsVoice();
    _preferOffline = await _settings.getPreferOffline();
    // 检查常用语言模型下载状态
    for (final (code, _) in _langs) {
      final ok = await _mlkit.isModelDownloaded(code);
      _modelStatus[code] = ok;
    }
    if (mounted) setState(() => _initDone = true);
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
        ).showSnackBar(SnackBar(content: Text('$_langName(code) 模型下载完成')));
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

  Future<void> _saveApi() async {
    await _settings.setApiBaseUrl(_baseUrlCtrl.text.trim());
    await _settings.setApiKey(_apiKeyCtrl.text.trim());
    await _settings.setApiModel(_modelCtrl.text.trim());
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('API 配置已保存')));
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
                  _buildSectionTitle('朗读参数'),
                  _buildTtsParams(),
                  const SizedBox(height: 24),
                  _buildSectionTitle('离线翻译模型'),
                  _buildModelList(),
                  const SizedBox(height: 24),
                  _buildSectionTitle('AI 离线优先'),
                  _buildOfflineToggle(),
                  const SizedBox(height: 24),
                  _buildSectionTitle('云端 AI 配置（知识提取/翻译/测验兜底）'),
                  _buildApiConfig(),
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

  Widget _buildEngineSelector() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'auto', label: Text('自动')),
                ButtonSegment(value: 'mlkit', label: Text('离线快')),
                ButtonSegment(value: 'llm', label: Text('本地 AI')),
                ButtonSegment(value: 'cloud', label: Text('云端')),
              ],
              selected: {_engine},
              onSelectionChanged: (v) => _saveEngine(v.first),
              style: SegmentedButton.styleFrom(
                selectedBackgroundColor: StudyPalette.emberSoft,
                selectedForegroundColor: StudyPalette.ember,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _engineDesc(_engine),
              style: const TextStyle(fontSize: 12, color: StudyPalette.inkSoft),
            ),
          ],
        ),
      ),
    );
  }

  String _engineDesc(String e) {
    switch (e) {
      case 'auto':
        return '自动：ML Kit（快）→ 本地 AI（强）→ 云端（兜底），逐级回落';
      case 'mlkit':
        return 'ML Kit 离线翻译（快，需下载语言模型）';
      case 'llm':
        return '本地大模型 AI 翻译（需加载 GGUF 模型）';
      case 'cloud':
        return '云端 OpenAI 兼容 API（需配置 API 地址与密钥）';
      default:
        return '';
    }
  }

  Widget _buildModelList() {
    return Card(
      child: Column(
        children: [
          for (var i = 0; i < _langs.length; i++)
            _buildLangRow(
              _langs[i].$1,
              _langs[i].$2,
              isLast: i == _langs.length - 1,
            ),
        ],
      ),
    );
  }

  Widget _buildLangRow(String code, String label, {bool isLast = false}) {
    final downloaded = _modelStatus[code] ?? false;
    final busy = _modelBusy[code] ?? false;
    return Column(
      children: [
        ListTile(
          dense: true,
          title: Text(label, style: const TextStyle(color: StudyPalette.ink)),
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
              onChanged: (v) => setState(() => _ttsRate = v),
              onChangeEnd: (v) => _settings.setTtsRate(v),
            ),
            const Divider(height: 8),

            // 重复遍数
            Row(
              children: [
                const Icon(Icons.repeat, size: 20, color: StudyPalette.ink),
                const SizedBox(width: 8),
                Text('重复遍数', style: titleStyle(fontSize: 14)),
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

            // 句间停顿
            Row(
              children: [
                const Icon(
                  Icons.timer_outlined,
                  size: 20,
                  color: StudyPalette.ink,
                ),
                const SizedBox(width: 8),
                Text('句间停顿', style: titleStyle(fontSize: 14)),
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

            // [v2.8.0] 音色选择
            Row(
              children: [
                const Icon(
                  Icons.record_voice_over,
                  size: 20,
                  color: StudyPalette.ink,
                ),
                const SizedBox(width: 8),
                Text('音色', style: titleStyle(fontSize: 14)),
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
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOfflineToggle() {
    return Card(
      child: SwitchListTile(
        title: const Text('优先使用离线 AI'),
        subtitle: const Text(
          '开启后 AI 知识提取/翻译/测验优先走本地模型，\n云端仅作兜底',
          style: TextStyle(fontSize: 12, color: StudyPalette.inkSoft),
        ),
        value: _preferOffline,
        activeThumbColor: StudyPalette.ember,
        onChanged: (v) {
          setState(() => _preferOffline = v);
          _settings.setPreferOffline(v);
        },
      ),
    );
  }

  Widget _buildApiConfig() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            TextField(
              controller: _baseUrlCtrl,
              decoration: const InputDecoration(
                labelText: 'API 地址',
                hintText: 'https://api.openai.com/v1',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _apiKeyCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'API Key',
                hintText: 'sk-...',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _modelCtrl,
              decoration: const InputDecoration(
                labelText: '模型名',
                hintText: 'gpt-4o-mini',
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(onPressed: _saveApi, child: const Text('保存')),
            ),
          ],
        ),
      ),
    );
  }
}
