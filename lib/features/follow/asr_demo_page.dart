import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/debug/app_log.dart';
import '../../services/asr_service.dart';
import '../../services/model_store.dart';
import '../../services/vosk_asr_service.dart';
import '../debug/log_page.dart';

/// [v0.1.0] Vosk 离线识别 PoC 验证页。
///
/// 验证链路：下载模型 → 初始化 → 麦克风录音 → 离线识别 → 显示结果。
/// 用于真机验收「离线跟读」核心链路是否可用（PoC 门禁）。
class AsrDemoPage extends StatefulWidget {
  const AsrDemoPage({super.key});

  @override
  State<AsrDemoPage> createState() => _AsrDemoPageState();
}

class _AsrDemoPageState extends State<AsrDemoPage> {
  static const _tag = 'asr_demo';

  final AsrService _asr = VoskAsrService();
  bool _busy = false;
  bool _listening = false;
  String _status = '未初始化';
  String _result = '';

  Future<void> _initModel() async {
    AppLog.d(_tag, '点击「尝试在线下载」');
    setState(() {
      _busy = true;
      _status = '请求麦克风权限…';
    });
    final perm = await Permission.microphone.request();
    AppLog.d(_tag, '麦克风权限: $perm');
    if (!perm.isGranted) {
      setState(() {
        _busy = false;
        _status = '麦克风权限被拒绝';
      });
      return;
    }
    setState(() => _status = '下载/解压模型（约42MB）…');
    try {
      final modelPath = await ModelStore.ensureVoskCnModel();
      AppLog.d(_tag, '模型就绪，调用 init: $modelPath');
      final ok = await _asr.init(modelPath);
      AppLog.d(_tag, 'init 返回: $ok');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = ok ? '模型已加载 ✓' : '模型加载失败';
      });
    } catch (e, s) {
      AppLog.e(_tag, '在线下载失败: $e\n$s');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = '网络下载失败，请改用「导入模型文件」: $e';
      });
    }
  }

  /// 通过文件选择器导入本地模型 zip（离线方式）。
  Future<void> _importModel() async {
    AppLog.d(_tag, '点击「导入模型文件」，打开文件选择器');
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip'],
        dialogTitle: '选择 Vosk 模型 zip 文件',
      );
      if (result == null ||
          result.files.isEmpty ||
          result.files.first.path == null) {
        AppLog.d(_tag, '用户取消或未取得文件路径');
        return; // 用户取消
      }
      final zipPath = result.files.first.path!;
      AppLog.d(_tag, '已选文件: $zipPath');
      setState(() {
        _busy = true;
        _status = '正在导入并解压模型…';
      });

      final modelPath = await ModelStore.importFromZip(zipPath);
      AppLog.d(_tag, '导入完成，调用 VoskBridge.init');
      final ok = await _asr.init(modelPath);
      AppLog.d(_tag, 'init 返回: $ok');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = ok ? '模型导入并加载成功 ✓' : '模型加载失败';
      });
    } catch (e, s) {
      AppLog.e(_tag, '导入失败: $e\n$s');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = '导入失败: $e';
      });
    }
  }

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
          _status = '识别完成';
        });
      } else {
        AppLog.d(_tag, '开始录音');
        final ok = await _asr.start();
        AppLog.d(_tag, 'start 返回: $ok');
        if (!mounted) return;
        setState(() {
          _listening = ok;
          _status = ok ? '录音中… 说一句话后点停止' : '启动录音失败';
        });
      }
    } catch (e, s) {
      AppLog.e(_tag, '录音/识别异常: $e\n$s');
      if (!mounted) return;
      setState(() {
        _listening = false;
        _status = '录音失败: $e';
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
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(
                          _asr.isLoaded ? Icons.check_circle : Icons.download,
                          color: _asr.isLoaded ? Colors.green : null,
                          size: 28,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Vosk 中文小模型',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                              Text(
                                _status,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (!_asr.isLoaded && !_busy) ...[
                      const SizedBox(height: 8),
                      FilledButton.icon(
                        icon: const Icon(Icons.folder_open, size: 18),
                        onPressed: _importModel,
                        label: const Text('导入模型文件'),
                      ),
                      const SizedBox(height: 4),
                      TextButton(
                        onPressed: _initModel,
                        child: const Text(
                          '尝试在线下载',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                    if (_busy)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Center(
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _asr.isLoaded && !_busy ? _toggleListen : null,
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
