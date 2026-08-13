import 'package:flutter/material.dart';

import '../../core/debug/app_log.dart';
import '../../core/theme/app_theme.dart';
import '../../services/statistics_service.dart';

/// [v0.1.0] 学习统计页：掌握率 / 学习记录 / 错词分布 / 近期活动。
///
/// 「暖色书房」统一风格，数据来自 [StatisticsService]（只读聚合）。
class StatsPage extends StatefulWidget {
  const StatsPage({super.key});

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  static const _tag = 'stats';

  LearningStats? _stats;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final stats = await StatisticsService().load();
      if (!mounted) return;
      setState(() {
        _stats = stats;
        _loading = false;
      });
    } catch (e, s) {
      AppLog.e(_tag, '加载统计失败: $e\n$s');
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('学习统计')),
      body:
          _loading
              ? const Center(child: CircularProgressIndicator())
              : _stats == null
              ? const Center(child: Text('统计加载失败'))
              : _buildBody(_stats!),
    );
  }

  Widget _buildBody(LearningStats s) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
      children: [
        _buildSectionTitle('掌握概览'),
        _buildMasteryCard(s),
        const SizedBox(height: 24),
        _buildSectionTitle('学习记录'),
        _buildRecordCard(s),
        const SizedBox(height: 24),
        _buildSectionTitle('错词分布'),
        _buildWrongWordsCard(s),
        const SizedBox(height: 24),
        _buildSectionTitle('近 7 天活动'),
        _buildActivityCard(s),
      ],
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(title, style: titleStyle(fontSize: 16)),
    );
  }

  // ===== 掌握概览 =====

  Widget _buildMasteryCard(LearningStats s) {
    final rate = s.masteryRate;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // 大数字：掌握率
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${(rate * 100).round()}%',
                  style: titleStyle(fontSize: 40, color: StudyPalette.ember),
                ),
                const SizedBox(width: 8),
                const Padding(
                  padding: EdgeInsets.only(bottom: 6),
                  child: Text(
                    '已掌握',
                    style: TextStyle(fontSize: 14, color: StudyPalette.inkSoft),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // 进度条
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: rate,
                minHeight: 10,
                backgroundColor: StudyPalette.parchmentDeep,
                valueColor: AlwaysStoppedAnimation<Color>(
                  rate >= 0.8
                      ? StudyPalette.moss
                      : rate >= 0.5
                      ? StudyPalette.ember
                      : StudyPalette.ember,
                ),
              ),
            ),
            const SizedBox(height: 16),
            // 三列数字
            Row(
              children: [
                _statColumn('生词', '${s.wordCount}', StudyPalette.ink),
                _divider(),
                _statColumn('已掌握', '${s.masteredCount}', StudyPalette.moss),
                _divider(),
                _statColumn('未掌握', '${s.unmasteredCount}', StudyPalette.ember),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _statColumn(String label, String value, Color color) {
    return Expanded(
      child: Column(
        children: [
          Text(value, style: titleStyle(fontSize: 26, color: color)),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(fontSize: 12, color: StudyPalette.inkSoft),
          ),
        ],
      ),
    );
  }

  Widget _divider() {
    return Container(width: 1, height: 36, color: StudyPalette.linen);
  }

  // ===== 学习记录 =====

  Widget _buildRecordCard(LearningStats s) {
    return Card(
      child: Column(
        children: [
          _recordRow('跟读', s.followCount, s.followAvg),
          const Divider(height: 1, indent: 16),
          _recordRow('听写', s.dictationCount, s.dictationAvg),
          const Divider(height: 1, indent: 16),
          _recordRow('复习', s.reviewCount, s.reviewAvg),
        ],
      ),
    );
  }

  Widget _recordRow(String label, int count, double avg) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: StudyPalette.emberSoft,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              _recordIcon(label),
              size: 20,
              color: StudyPalette.ember,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            label,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: StudyPalette.ink,
            ),
          ),
          const Spacer(),
          Text(
            '$count 次',
            style: const TextStyle(fontSize: 15, color: StudyPalette.ink),
          ),
          const SizedBox(width: 16),
          Text(
            avg > 0 ? '均分 ${avg.round()}' : '—',
            style: const TextStyle(fontSize: 13, color: StudyPalette.inkSoft),
          ),
        ],
      ),
    );
  }

  IconData _recordIcon(String label) {
    switch (label) {
      case '跟读':
        return Icons.record_voice_over_outlined;
      case '听写':
        return Icons.edit_note_outlined;
      default:
        return Icons.autorenew_outlined;
    }
  }

  // ===== 错词分布 =====

  Widget _buildWrongWordsCard(LearningStats s) {
    if (s.topWrongWords.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            '暂无错词记录，继续加油！',
            style: const TextStyle(color: StudyPalette.inkSoft),
          ),
        ),
      );
    }
    return Card(
      child: Column(
        children: List.generate(s.topWrongWords.length, (i) {
          final w = s.topWrongWords[i];
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color:
                            i < 3
                                ? StudyPalette.emberSoft
                                : StudyPalette.parchmentDeep,
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        '${i + 1}',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color:
                              i < 3 ? StudyPalette.ember : StudyPalette.inkSoft,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        w.word,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: StudyPalette.ink,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    // 错次徽标
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: StudyPalette.emberSoft,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '错 ${w.wrongCount} 次',
                        style: const TextStyle(
                          fontSize: 12,
                          color: StudyPalette.ember,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (i != s.topWrongWords.length - 1)
                const Divider(height: 1, indent: 16),
            ],
          );
        }),
      ),
    );
  }

  // ===== 近 7 天活动 =====

  Widget _buildActivityCard(LearningStats s) {
    final entries =
        s.dailyActivity.entries.toList()
          ..sort((a, b) => a.key.compareTo(b.key));
    final maxCount = entries.fold<int>(1, (m, e) => e.value > m ? e.value : m);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.end,
          children:
              entries.map((e) {
                final h = (e.value / maxCount) * 80;
                final isToday = _isSameDay(e.key, DateTime.now());
                return Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (e.value > 0)
                        Text(
                          '${e.value}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: StudyPalette.inkSoft,
                          ),
                        )
                      else
                        const SizedBox(height: 13),
                      const SizedBox(height: 2),
                      Container(
                        height: h.clamp(4, 80),
                        margin: const EdgeInsets.symmetric(horizontal: 6),
                        decoration: BoxDecoration(
                          color:
                              isToday
                                  ? StudyPalette.ember
                                  : StudyPalette.ember.withValues(alpha: 0.4),
                          borderRadius: BorderRadius.vertical(
                            top: Radius.circular(4),
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _weekdayLabel(e.key),
                        style: TextStyle(
                          fontSize: 11,
                          color:
                              isToday
                                  ? StudyPalette.ember
                                  : StudyPalette.inkSoft,
                          fontWeight:
                              isToday ? FontWeight.w700 : FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
        ),
      ),
    );
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  String _weekdayLabel(DateTime d) {
    const labels = ['一', '二', '三', '四', '五', '六', '日'];
    return labels[d.weekday - 1];
  }
}
