import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/debug/app_log.dart';
import '../services/asr_service.dart';
import '../services/model_store.dart';

/// [v0.1.0] 模型就绪面板（导入 / 在线下载 / 状态展示）。
///
/// 从 AsrDemoPage 抽出，供 PoC 验证页与跟读练习页共用同一套模型加载逻辑。
/// 通过 [GlobalKey<ModelPanelState>] 读取 [isReady] 或调用 [ensureReady]。
class ModelPanel extends StatefulWidget {
  const ModelPanel({super.key, required this.asr, this.title = 'Vosk 中文小模型'});

  /// 底层 ASR 服务（面板负责加载模型并 init）。
  final AsrService asr;

  /// 卡片标题。
  final String title;

  @override
  State<ModelPanel> createState() => ModelPanelState();
}

class ModelPanelState extends State<ModelPanel> {
  static const _tag = 'model_panel';

  bool _busy = false;
  String _status = '未初始化';

  /// 模型是否已加载就绪。
  bool get isReady => widget.asr.isLoaded;

  /// 触发模型就绪（在线下载 / 已存在直接返回）。返回是否成功。
  Future<bool> ensureReady() async {
    if (isReady) return true;
    await _initModel();
    return isReady;
  }

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
      final ok = await widget.asr.init(modelPath);
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
      AppLog.d(_tag, '导入完成，调用 init');
      final ok = await widget.asr.init(modelPath);
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

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  isReady ? Icons.check_circle : Icons.download,
                  color: isReady ? Colors.green : null,
                  size: 28,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      Text(_status, style: const TextStyle(fontSize: 12)),
                    ],
                  ),
                ),
              ],
            ),
            if (!isReady && !_busy) ...[
              const SizedBox(height: 8),
              FilledButton.icon(
                icon: const Icon(Icons.folder_open, size: 18),
                onPressed: _importModel,
                label: const Text('导入模型文件'),
              ),
              const SizedBox(height: 4),
              TextButton(
                onPressed: _initModel,
                child: const Text('尝试在线下载', style: TextStyle(fontSize: 12)),
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
    );
  }
}
