import 'package:flutter/material.dart';

import '../../core/debug/app_log.dart';
import '../../services/asr_service.dart';
import '../../services/vosk_asr_service.dart';
import '../../widgets/model_panel.dart';
import '../debug/log_page.dart';

/// [v0.1.0] Vosk 离线识别 PoC 验证页（调试用）。
///
/// 验证链路：模型加载 → 麦克风录音 → 离线识别 → 显示结果。
/// 模型就绪面板已抽取为共享 [ModelPanel]，本页仅保留录音/识别验证。
class AsrDemoPage extends StatefulWidget {
  const AsrDemoPage({super.key});

  @override
  State<AsrDemoPage> createState() => _AsrDemoPageState();
}

class _AsrDemoPageState extends State<AsrDemoPage> {
  static const _tag = 'asr_demo';

  final AsrService _asr = VoskAsrService();
  bool _listening = false;
  String _result = '';

  Future<void> _toggleListen() async {
    try {
      if (_listening) {
        AppLog.d(_tag, '停止录音');
        final text = await _asr.stop();
        AppLog.d(_tag, '识别结果: "$text"');
        if (!mounted) return;
        setState(() {
          _listening = false;
          _result = text;
        });
      } else {
        AppLog.d(_tag, '开始录音');
        final ok = await _asr.start();
        AppLog.d(_tag, 'start 返回: $ok');
        if (!mounted) return;
        setState(() => _listening = ok);
      }
    } catch (e, s) {
      AppLog.e(_tag, '录音/识别异常: $e\n$s');
      if (!mounted) return;
      setState(() => _listening = false);
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
        title: const Text('Vosk 离线识别 PoC'),
        actions: [
          IconButton(
            tooltip: '运行日志',
            icon: const Icon(Icons.bug_report_outlined),
            onPressed: _openLog,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ModelPanel(asr: _asr),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _asr.isLoaded && !_listening ? _toggleListen : null,
              icon: Icon(_listening ? Icons.stop : Icons.mic),
              label: Text(_listening ? '停止' : '开始录音'),
            ),
            const SizedBox(height: 16),
            const Text('识别结果：', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: Text(_result.isEmpty ? '（点击开始录音，说一句话后停止）' : _result),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
