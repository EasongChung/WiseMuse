import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../services/ai_tutor_service.dart';
import 'knowledge_explain_sheet.dart';

/// [v0.1.28] AI 助教推荐面板：显示今日推荐复习知识点列表。
///
/// 从 [AiTutorService.getRecommendation] 加载，每条可点击展开讲解。
class TutorPanel extends StatefulWidget {
  const TutorPanel({super.key});

  @override
  State<TutorPanel> createState() => _TutorPanelState();
}

class _TutorPanelState extends State<TutorPanel> {
  List<String> _recommendations = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final result = await AiTutorService.instance.getRecommendation(count: 5);
    if (mounted) {
      setState(() {
        _recommendations = result;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(
        height: 120,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_recommendations.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Icon(
                Icons.celebration_outlined,
                size: 40,
                color: StudyPalette.moss,
              ),
              const SizedBox(height: 8),
              const Text(
                '暂无待复习知识点',
                style: TextStyle(fontSize: 14, color: StudyPalette.inkSoft),
              ),
              const SizedBox(height: 4),
              const Text(
                '继续学习，积累更多内容后自动推荐',
                style: TextStyle(fontSize: 12, color: StudyPalette.inkSoft),
              ),
            ],
          ),
        ),
      );
    }
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Row(
              children: [
                const Icon(
                  Icons.auto_awesome,
                  size: 18,
                  color: StudyPalette.ember,
                ),
                const SizedBox(width: 6),
                Text('今日推荐复习', style: titleStyle(fontSize: 15)),
                const Spacer(),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('刷新', style: TextStyle(fontSize: 12)),
                  onPressed: () {
                    setState(() => _loading = true);
                    _load();
                  },
                ),
              ],
            ),
          ),
          ...List.generate(_recommendations.length, (i) {
            final text = _recommendations[i];
            return ListTile(
              dense: true,
              leading: CircleAvatar(
                radius: 12,
                backgroundColor: StudyPalette.emberSoft,
                child: Text(
                  '${i + 1}',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: StudyPalette.ember,
                  ),
                ),
              ),
              title: Text(
                text,
                style: const TextStyle(fontSize: 14, color: StudyPalette.ink),
              ),
              trailing: IconButton(
                icon: const Icon(
                  Icons.lightbulb_outline,
                  size: 18,
                  color: StudyPalette.ember,
                ),
                tooltip: '讲解',
                onPressed: () => KnowledgeExplainSheet.show(context, text),
              ),
            );
          }),
        ],
      ),
    );
  }
}
