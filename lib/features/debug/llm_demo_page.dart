import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/debug/app_log.dart';
import '../../services/llm_service.dart';
import '../../services/model_store.dart';
import '../debug/log_page.dart';

/// [v0.1.0] llama.android 本地 LLM 验证页（PoC 调试用）。
///
/// 链路：导入 GGUF 模型 → 加载 → 问/答 → 基准测试。
/// 设计基调走 WiseMuse 儿童向（圆角、色彩、友好文案），
/// 避免灰调开发者风（docs/17）。
class LlmDemoPage extends StatefulWidget {
  const LlmDemoPage({super.key});

  @override
  State<LlmDemoPage> createState() => _LlmDemoPageState();
}

class _LlmDemoPageState extends State<LlmDemoPage> {
  static const _tag = 'llm_demo';

  final LlmService _llm = LlmService();
  bool _available = false;
  bool _busy = false;
  bool _ready = false;
  String _status = '检查设备…';
  String _response = '';

  final _promptController = TextEditingController(text: '用一句话介绍你自己');

  static const List<String> _samplePrompts = [
    '用一句话介绍你自己',
    '什么是光合作用？',
    '讲一个关于小动物的故事，不超过50个字',
    '帮我出个谜语',
  ];

  @override
  void initState() {
    super.initState();
    AppLog.d(_tag, '页面初始化，检查引擎可用性');
    _checkAvailable();
  }

  @override
  void dispose() {
    _promptController.dispose();
    _llm.destroy();
    super.dispose();
  }

  Future<void> _checkAvailable() async {
    try {
      final ok = await _llm.isAvailable();
      AppLog.d(_tag, '引擎可用: $ok');
      if (!mounted) return;
      setState(() {
        _available = ok;
        _status = ok ? '引擎就绪，请导入 GGUF 模型' : '本设备需 Android 11+ 使用本地 LLM';
      });
    } catch (e) {
      AppLog.e(_tag, '检查可用性失败: $e');
      if (!mounted) return;
      setState(() => _status = '检查失败: $e');
    }
  }

  Future<void> _importModel() async {
    AppLog.d(_tag, '点击「选择 GGUF 文件」');
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['gguf'],
        dialogTitle: '选择 Qwen3 GGUF 模型文件',
      );
      if (result == null ||
          result.files.isEmpty ||
          result.files.first.path == null) {
        AppLog.d(_tag, '用户取消');
        return;
      }
      final srcPath = result.files.first.path!;
      AppLog.d(_tag, '已选文件: $srcPath');
      setState(() {
        _busy = true;
        _status = '正在导入模型（约500MB，请稍候）…';
      });

      final modelPath = await ModelStore.importGguf(srcPath);
      AppLog.d(_tag, '导入完成，调用 init: $modelPath');
      setState(() => _status = '正在加载模型…');

      final ok = await _llm.init(modelPath);
      AppLog.d(_tag, 'init 返回: $ok');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _ready = ok;
        _status = ok ? '模型已加载 ✅ 可以对话了' : '模型加载失败';
      });
    } catch (e, s) {
      AppLog.e(_tag, '导入/加载异常: $e\n$s');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = '加载失败: $e';
      });
    }
  }

  Future<void> _send() async {
    final prompt = _promptController.text.trim();
    if (prompt.isEmpty) return;
    AppLog.d(_tag, '发送: "$prompt"');
    setState(() {
      _busy = true;
      _status = '思考中…';
      _response = '';
    });

    try {
      final text = await _llm.chat(prompt);
      AppLog.d(_tag, '回复: "$text"');
      if (!mounted) return;
      setState(() {
        _busy = false;
        // 剥离 thinking 后为空：模型把预算全花在思考上（Qwen3 系 hybrid reasoning
        // 常见），提示换非思考模型或再问一次。
        _response =
            text.isEmpty
                ? '⚠️ 模型仅输出了思考过程、未产出正式回答。\n'
                    '这是 Qwen3.5 等「思考模型」的特性：它把生成的 token 都花在'
                    '内部推理上了。\n建议换用非思考模型（如 gemma-2-2b / Hy-MT2）'
                    '，或加大生成长度后重试。'
                : text;
        _status = '回答完成';
      });
    } catch (e, s) {
      AppLog.e(_tag, '生成异常: $e\n$s');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = '生成失败: $e';
      });
    }
  }

  Future<void> _runBench() async {
    AppLog.d(_tag, '开始基准测试');
    setState(() {
      _busy = true;
      _status = '运行基准测试（pp=512 tg=128）…';
    });
    try {
      final result = await _llm.bench();
      AppLog.d(_tag, 'bench 结果:\n$result');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _response = result;
        _status = '基准测试完成';
      });
    } catch (e, s) {
      AppLog.e(_tag, 'bench 异常: $e\n$s');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = 'bench 失败: $e';
      });
    }
  }

  void _openLog() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const LogPage()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('本地 AI 引擎'),
        actions: [
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
          // 状态卡片
          _StatusCard(
            available: _available,
            ready: _ready,
            busy: _busy,
            status: _status,
          ),
          const SizedBox(height: 16),

          // 导入/加载模型（仅当未就绪时显示）
          if (!_ready && _available) ...[
            _ActionCard(
              icon: Icons.folder_open,
              label: '导入 GGUF 模型文件',
              subtitle: '选择已下载的 Qwen3 GGUF（约500MB）',
              onPressed: _busy ? null : _importModel,
            ),
            const SizedBox(height: 12),
          ],

          // 对话区域（仅就绪后显示）
          if (_ready) ...[
            // 输入
            _PromptInput(
              controller: _promptController,
              enabled: !_busy,
              onSend: _send,
            ),
            const SizedBox(height: 8),
            // 样例提示词
            _SampleChips(
              samples: _samplePrompts,
              enabled: !_busy,
              onTap: (s) {
                _promptController.text = s;
                setState(() {});
              },
            ),
            const SizedBox(height: 12),
            // 按钮行
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _send,
                    icon: const Icon(Icons.auto_awesome),
                    label: const Text('问一问'),
                    style: FilledButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _runBench,
                  icon: const Icon(Icons.speed),
                  label: const Text('跑分'),
                  style: OutlinedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // 回复
            _ResponseCard(text: _response),
          ],
        ],
      ),
    );
  }
}

// ---- 子组件 ----

/// 状态卡片：显示引擎可用性/加载状态。
class _StatusCard extends StatelessWidget {
  final bool available;
  final bool ready;
  final bool busy;
  final String status;

  const _StatusCard({
    required this.available,
    required this.ready,
    required this.busy,
    required this.status,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon =
        ready
            ? Icons.check_circle
            : (available ? Icons.download : Icons.info_outline);
    final color =
        ready
            ? Colors.green
            : (available ? theme.colorScheme.primary : Colors.orange);

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, color: color, size: 32),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    ready
                        ? 'AI 引擎已就绪'
                        : (available ? '本地 AI 引擎可用' : '本地 AI 引擎不可用'),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    status,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (busy)
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
      ),
    );
  }
}

/// 操作卡片：导入模型等。
class _ActionCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final VoidCallback? onPressed;

  const _ActionCard({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(icon, color: theme.colorScheme.primary, size: 28),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 提示词输入框。
class _PromptInput extends StatelessWidget {
  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onSend;

  const _PromptInput({
    required this.controller,
    required this.enabled,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled,
      maxLines: 3,
      minLines: 1,
      decoration: InputDecoration(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        labelText: '说点什么？',
        hintText: '输入你的问题…',
        suffixIcon: IconButton(
          icon: const Icon(Icons.send),
          onPressed:
              enabled && controller.text.trim().isNotEmpty ? onSend : null,
        ),
      ),
    );
  }
}

/// 样例提示词芯片。
class _SampleChips extends StatelessWidget {
  final List<String> samples;
  final bool enabled;
  final ValueChanged<String> onTap;

  const _SampleChips({
    required this.samples,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        for (final s in samples)
          ActionChip(
            avatar: Icon(
              Icons.lightbulb_outline,
              size: 16,
              color: Colors.amber[700],
            ),
            label: Text(s, style: const TextStyle(fontSize: 12)),
            onPressed: enabled ? () => onTap(s) : null,
          ),
      ],
    );
  }
}

/// 回复显示卡片。
class _ResponseCard extends StatelessWidget {
  final String text;

  const _ResponseCard({required this.text});

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.auto_awesome, size: 18, color: Colors.blue[600]),
                const SizedBox(width: 8),
                const Text(
                  'AI 回复',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              text.isEmpty ? '（点击「问一问」开始对话）' : text,
              style: const TextStyle(fontSize: 15, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}
