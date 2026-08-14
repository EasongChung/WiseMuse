import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../services/ai_tutor_service.dart';

/// [v2.8.0] 知识点讲解弹窗：调用 [AiTutorService.explain] 生成 Markdown 讲解。
///
/// 加载中显示指示器，失败显示重试入口。暖色书房风格。
class KnowledgeExplainSheet extends StatefulWidget {
  const KnowledgeExplainSheet({super.key, required this.text});

  final String text;

  /// 弹出讲解弹窗。
  static Future<void> show(BuildContext context, String text) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: StudyPalette.parchment,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => KnowledgeExplainSheet(text: text),
    );
  }

  @override
  State<KnowledgeExplainSheet> createState() => _KnowledgeExplainSheetState();
}

class _KnowledgeExplainSheetState extends State<KnowledgeExplainSheet> {
  String? _explanation;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    final result = await AiTutorService.instance.explain(widget.text);
    if (mounted) {
      setState(() {
        _loading = false;
        if (result != null) {
          _explanation = result;
        } else {
          _failed = true;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.85,
      expand: false,
      builder: (context, scrollController) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 拖拽手柄
              Center(
                child: Container(
                  width: 32,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: StudyPalette.linen,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              // 标题
              Row(
                children: [
                  const Icon(
                    Icons.lightbulb_outline,
                    size: 20,
                    color: StudyPalette.ember,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.text,
                      style: titleStyle(fontSize: 18),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.close,
                      size: 20,
                      color: StudyPalette.inkSoft,
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const Divider(height: 16),

              // 内容区
              Expanded(
                child:
                    _loading
                        ? const Center(child: CircularProgressIndicator())
                        : _failed
                        ? _buildError()
                        : _buildExplanation(scrollController),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildExplanation(ScrollController scrollController) {
    return SingleChildScrollView(
      controller: scrollController,
      child: _buildMarkdownContent(_explanation!),
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.error_outline,
            size: 40,
            color: StudyPalette.inkSoft,
          ),
          const SizedBox(height: 8),
          const Text(
            '讲解生成失败',
            style: TextStyle(fontSize: 14, color: StudyPalette.inkSoft),
          ),
          const SizedBox(height: 4),
          const Text(
            '请检查 AI 引擎配置后重试',
            style: TextStyle(fontSize: 12, color: StudyPalette.inkSoft),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('重试'),
            onPressed: _load,
          ),
        ],
      ),
    );
  }

  /// 简易 Markdown 渲染（支持 **加粗**、标题、列表）。
  Widget _buildMarkdownContent(String md) {
    final lines = md.split('\n');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children:
          lines.map((line) {
            final t = line.trim();
            if (t.isEmpty) return const SizedBox(height: 8);

            // 标题：### 或 ## 或 #
            final headerMatch = RegExp(r'^#{1,3}\s+(.*)').firstMatch(t);
            if (headerMatch != null) {
              return Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 4),
                child: Text(
                  headerMatch.group(1)!,
                  style: titleStyle(
                    fontSize:
                        t.startsWith('###')
                            ? 14
                            : t.startsWith('##')
                            ? 16
                            : 18,
                  ),
                ),
              );
            }

            // 列表：- 或 *
            if (t.startsWith('- ') || t.startsWith('* ')) {
              return Padding(
                padding: const EdgeInsets.only(left: 8, top: 2, bottom: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '•  ',
                      style: TextStyle(color: StudyPalette.ember),
                    ),
                    Expanded(child: _buildRichText(t.substring(2))),
                  ],
                ),
              );
            }

            // 普通文本（含加粗）
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: _buildRichText(t),
            );
          }).toList(),
    );
  }

  /// 支持 **加粗** 标记的内联文本。
  Widget _buildRichText(String text) {
    final spans = <TextSpan>[];
    final regex = RegExp(r'\*\*(.+?)\*\*');
    var lastEnd = 0;
    for (final match in regex.allMatches(text)) {
      if (match.start > lastEnd) {
        spans.add(TextSpan(text: text.substring(lastEnd, match.start)));
      }
      spans.add(
        TextSpan(
          text: match.group(1),
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            color: StudyPalette.ink,
          ),
        ),
      );
      lastEnd = match.end;
    }
    if (lastEnd < text.length) {
      spans.add(TextSpan(text: text.substring(lastEnd)));
    }
    return Text.rich(
      TextSpan(
        children: spans,
        style: const TextStyle(
          fontSize: 15,
          color: StudyPalette.ink,
          height: 1.6,
        ),
      ),
    );
  }
}
