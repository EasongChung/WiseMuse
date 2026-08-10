import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/debug/app_log.dart';

/// [v0.1.0] 测试期日志查看页。
///
/// 两个来源：
/// - **本次运行**：内存缓冲，实时刷新；
/// - **磁盘文件**：含上一次崩溃前落盘的记录（进程被 kill 时唯一可用证据）。
class LogPage extends StatefulWidget {
  const LogPage({super.key});

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  bool _showFile = false;
  String _fileText = '';

  Future<void> _loadFile() async {
    final text = await AppLog.readFile();
    if (!mounted) return;
    setState(() {
      _fileText = text;
      _showFile = true;
    });
  }

  Future<void> _copy() async {
    final text = _showFile ? _fileText : AppLog.toText();
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已复制 ${text.length} 字符到剪贴板')));
  }

  Future<void> _clear() async {
    await AppLog.clear();
    if (!mounted) return;
    setState(() {
      _fileText = '';
      _showFile = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('运行日志'),
        actions: [
          IconButton(
            tooltip: '复制全部',
            icon: const Icon(Icons.copy),
            onPressed: _copy,
          ),
          IconButton(
            tooltip: '清空',
            icon: const Icon(Icons.delete_outline),
            onPressed: _clear,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('本次运行')),
                      ButtonSegment(value: true, label: Text('磁盘文件')),
                    ],
                    selected: {_showFile},
                    onSelectionChanged: (s) {
                      if (s.first) {
                        _loadFile();
                      } else {
                        setState(() => _showFile = false);
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
          if (AppLog.filePath != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                AppLog.filePath!,
                style: const TextStyle(fontSize: 10, color: Colors.grey),
              ),
            ),
          const Divider(height: 12),
          Expanded(child: _showFile ? _buildFileView() : _buildLiveView()),
        ],
      ),
    );
  }

  Widget _buildFileView() => SingleChildScrollView(
    padding: const EdgeInsets.all(12),
    child: SelectableText(
      _fileText.isEmpty ? '（空）' : _fileText,
      style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
    ),
  );

  Widget _buildLiveView() => ValueListenableBuilder<List<LogEntry>>(
    valueListenable: AppLog.entries,
    builder: (context, list, _) {
      if (list.isEmpty) {
        return const Center(child: Text('（暂无日志）'));
      }
      return ListView.builder(
        reverse: true,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: list.length,
        itemBuilder: (context, i) {
          final e = list[list.length - 1 - i];
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '${e.t} ',
                    style: const TextStyle(color: Colors.grey),
                  ),
                  TextSpan(
                    text: '[${e.tag}] ',
                    style: TextStyle(
                      color: _levelColor(e.level),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  TextSpan(text: e.message),
                ],
              ),
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
            ),
          );
        },
      );
    },
  );

  Color _levelColor(String level) => switch (level) {
    'error' || 'fatal' => Colors.red,
    'warn' => Colors.orange,
    _ => Colors.blue,
  };
}
