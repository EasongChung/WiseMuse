import 'package:flutter/material.dart';

import '../../core/debug/app_log.dart';
import '../../core/models/knowledge_point.dart';
import '../../core/models/word_entry.dart';
import '../../core/storage/database.dart';
import '../../core/storage/knowledge_point_dao.dart';
import '../../core/storage/word_entry_dao.dart';
import '../../core/theme/app_theme.dart';
import 'knowledge_edit_sheet.dart';

/// [v0.3.0] 知识点详情弹窗（查看/加生词/编辑/删除）。
class KnowledgeDetailSheet extends StatefulWidget {
  const KnowledgeDetailSheet({super.key, required this.kp});

  final KnowledgePoint kp;

  /// 弹出详情弹窗，用户操作后返回：
  /// - `true`：需要刷新列表
  /// - `null`：无变更
  static Future<bool?> show(BuildContext context, KnowledgePoint kp) {
    return showModalBottomSheet<bool>(
      context: context,
      builder: (_) => KnowledgeDetailSheet(kp: kp),
    );
  }

  @override
  State<KnowledgeDetailSheet> createState() => _KnowledgeDetailSheetState();
}

class _KnowledgeDetailSheetState extends State<KnowledgeDetailSheet> {
  late final KnowledgePoint _kp;

  IconData _typeIcon(KnowledgeType type) {
    switch (type) {
      case KnowledgeType.word:
        return Icons.text_fields;
      case KnowledgeType.idiom:
        return Icons.auto_awesome;
      case KnowledgeType.english:
        return Icons.translate;
      case KnowledgeType.poem:
        return Icons.auto_stories;
    }
  }

  Color _typeColor(KnowledgeType type) {
    switch (type) {
      case KnowledgeType.word:
        return StudyPalette.ember;
      case KnowledgeType.idiom:
        return StudyPalette.spinePdf;
      case KnowledgeType.english:
        return StudyPalette.spineWord;
      case KnowledgeType.poem:
        return StudyPalette.spineTxt;
    }
  }

  @override
  void initState() {
    super.initState();
    _kp = widget.kp;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 拖拽指示器
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

          // 类型标签 + 内容
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(_typeIcon(_kp.type), color: _typeColor(_kp.type), size: 26),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _kp.text,
                  style:
                      _kp.type == KnowledgeType.poem
                          ? TextStyle(
                            fontSize: 16,
                            height: 1.6,
                            fontWeight: FontWeight.w600,
                            color: StudyPalette.onSurfaceResolved(context),
                          )
                          : titleStyle(
                            fontSize: 20,
                            color: StudyPalette.onSurfaceResolved(context),
                          ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // 掌握度
          Row(
            children: [
              const Icon(
                Icons.school_outlined,
                size: 16,
                color: StudyPalette.inkSoft,
              ),
              const SizedBox(width: 6),
              Text(
                '掌握度：${_kp.mastery}/5  |  答错：${_kp.wrongCount} 次',
                style: const TextStyle(
                  fontSize: 13,
                  color: StudyPalette.inkSoft,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // 释义
          if (_kp.definition != null && _kp.definition!.isNotEmpty) ...[
            Text(
              '释义',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 13,
                color: StudyPalette.onSurfaceResolved(context),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _kp.definition!,
              style: TextStyle(
                fontSize: 14,
                color: StudyPalette.onSurfaceResolved(context),
                height: 1.4,
              ),
            ),
            const SizedBox(height: 12),
          ],

          // 附加信息
          if (_kp.extra != null && _kp.extra!.isNotEmpty) ...[
            Text(
              '附加',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 13,
                color: StudyPalette.onSurfaceResolved(context),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _kp.extra!,
              style: const TextStyle(fontSize: 13, color: StudyPalette.inkSoft),
            ),
            const SizedBox(height: 12),
          ],

          // 来源
          Text(
            '来源：${_kp.source == 'ai' ? 'AI 提取' : '手动录入'}',
            style: const TextStyle(fontSize: 12, color: StudyPalette.inkSoft),
          ),
          const Divider(height: 20),

          // 加入生词本
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _addToWordbook,
              icon: const Icon(Icons.bookmark_add_outlined, size: 18),
              label: const Text('加入生词本'),
              style: OutlinedButton.styleFrom(
                foregroundColor: StudyPalette.ember,
                side: const BorderSide(color: StudyPalette.ember),
              ),
            ),
          ),
          const SizedBox(height: 10),

          // 操作按钮
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.edit, size: 18),
                  label: const Text('编辑'),
                  onPressed: () => _edit(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('删除'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.redAccent,
                    side: const BorderSide(color: Colors.redAccent),
                  ),
                  onPressed: () => _delete(),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _edit() async {
    Navigator.pop(context); // 关闭详情
    final result = await KnowledgeEditSheet.show(context, initial: _kp);
    if (result != null && context.mounted) {
      try {
        final db = await DatabaseProvider.database;
        final dao = KnowledgePointDao(db);
        await dao.update(result);
        AppLog.d('kp_detail', '更新知识点: ${result.text}');
        // 通知父页面刷新
        if (!mounted) return;
        Navigator.of(context).pop(true);
      } catch (e, s) {
        AppLog.e('kp_detail', '更新失败: $e\n$s');
      }
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('删除知识点'),
            content: Text('确定删除「${_kp.text}」吗？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('删除'),
              ),
            ],
          ),
    );
    if (confirmed == true) {
      try {
        final db = await DatabaseProvider.database;
        final dao = KnowledgePointDao(db);
        await dao.delete(_kp.id);
        AppLog.d('kp_detail', '删除知识点: ${_kp.text}');
        if (!mounted) return;
        Navigator.of(context).pop(true);
      } catch (e, s) {
        AppLog.e('kp_detail', '删除失败: $e\n$s');
      }
    }
  }

  Future<void> _addToWordbook() async {
    try {
      final entry = WordEntry.create(
        word: _kp.text,
        lang: _kp.type == KnowledgeType.english ? 'en' : 'zh',
        fromBookId: _kp.bookId,
      );
      final db = await DatabaseProvider.database;
      await WordEntryDao(db).upsert(entry);
      AppLog.d('kp_detail', '加入生词本: ${_kp.text}');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已加入生词本：${_kp.text}')));
    } catch (e, s) {
      AppLog.e('kp_detail', '加入生词本失败: $e\n$s');
    }
  }
}
