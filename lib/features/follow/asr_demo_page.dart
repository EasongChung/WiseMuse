import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../services/asr_service.dart';
import '../../services/model_store.dart';
import '../../services/vosk_asr_service.dart';

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
  final AsrService _asr = VoskAsrService();
  bool _busy = false;
  bool _listening = false;
  String _status = '未初始化';
  String _result = '';

  Future<void> _initModel() async {
    setState(() {
      _busy = true;
      _status = '请求麦克风权限…';
    });
    final perm = await Permission.microphone.request();
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
      final ok = await _asr.init(modelPath);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = ok ? '模型已加载 ✓' : '模型加载失败';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = '网络下载失败，请改用「导入模型文件」: $e';
      });
    }
  }

  /// 通过文件选择器导入本地模型 zip（离线方式）。
  Future<void> _importModel() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
      dialogTitle: '选择 Vosk 模型 zip 文件',
    );
    if (result == null ||
        result.files.isEmpty ||
        result.files.first.path == null) {
      return; // 用户取消
    }
    final zipPath = result.files.first.path!;
    setState(() {
      _busy = true;
      _status = '正在导入并解压模型…';
    });
    try {
      final modelPath = await ModelStore.importFromZip(zipPath);
      final ok = await _asr.init(modelPath);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = ok ? '模型导入并加载成功 ✓' : '模型加载失败';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = '导入失败: $e';
      });
    }
  }

  Future<void> _toggleListen() async {
    if (_listening) {
      final text = await _asr.stop();
      if (!mounted) return;
      setState(() {
        _listening = false;
        _result = text;
        _status = '识别完成';
      });
    } else {
      final ok = await _asr.start();
      if (!mounted) return;
      setState(() {
        _listening = ok;
        _status = ok ? '录音中… 说一句话后点停止' : '启动录音失败';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Vosk 离线识别 PoC')),
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
