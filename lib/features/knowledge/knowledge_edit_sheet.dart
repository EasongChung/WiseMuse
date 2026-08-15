import 'package:flutter/material.dart';

import '../../core/models/book.dart';
import '../../core/models/knowledge_point.dart';
import '../../core/theme/app_theme.dart';

/// [v0.3.0] 知识点新建/编辑弹窗（BottomSheet）。
///
/// 支持选择类型、教材关联、填写内容。
class KnowledgeEditSheet extends StatefulWidget {
  const KnowledgeEditSheet({super.key, this.initial, this.books});

  /// 编辑模式：传入现有知识点；新建模式为 null。
  final KnowledgePoint? initial;

  /// 可选教材列表（供关联选择）。
  final List<Book>? books;

  /// 弹出并返回新/编辑后的 KnowledgePoint，用户取消返回 null。
  static Future<KnowledgePoint?> show(
    BuildContext context, {
    KnowledgePoint? initial,
    List<Book>? books,
  }) {
    return showModalBottomSheet<KnowledgePoint>(
      context: context,
      isScrollControlled: true,
      builder:
          (_) => Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom,
            ),
            child: KnowledgeEditSheet(initial: initial, books: books),
          ),
    );
  }

  @override
  State<KnowledgeEditSheet> createState() => _KnowledgeEditSheetState();
}

class _KnowledgeEditSheetState extends State<KnowledgeEditSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _textCtrl;
  late final TextEditingController _defCtrl;
  late final TextEditingController _extraCtrl;

  KnowledgeType _type = KnowledgeType.word;
  String? _selectedBookId;
  int? _page;
  int? _chapter;

  bool get _isEditing => widget.initial != null;

  @override
  void initState() {
    super.initState();
    final init = widget.initial;
    _textCtrl = TextEditingController(text: init?.text ?? '');
    _defCtrl = TextEditingController(text: init?.definition ?? '');
    _extraCtrl = TextEditingController(text: init?.extra ?? '');
    if (init != null) {
      _type = init.type;
      _selectedBookId = init.bookId;
      _page = init.page;
      _chapter = init.chapter;
    }
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    _defCtrl.dispose();
    _extraCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final kp = KnowledgePoint.create(
      bookId: _selectedBookId,
      page: _page,
      chapter: _chapter,
      type: _type,
      text: _textCtrl.text.trim(),
      definition: _defCtrl.text.trim(),
      extra: _extraCtrl.text.trim(),
      source: 'manual',
    );
    Navigator.of(context).pop(kp);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 标题
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
              Text(
                _isEditing ? '编辑知识点' : '手动添加知识点',
                style: titleStyle(fontSize: 18),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),

              // 类型选择
              SegmentedButton<KnowledgeType>(
                segments: const [
                  ButtonSegment(value: KnowledgeType.word, label: Text('词语')),
                  ButtonSegment(value: KnowledgeType.idiom, label: Text('成语')),
                  ButtonSegment(
                    value: KnowledgeType.english,
                    label: Text('英语'),
                  ),
                  ButtonSegment(value: KnowledgeType.poem, label: Text('诗词')),
                ],
                selected: {_type},
                onSelectionChanged: (v) => setState(() => _type = v.first),
                style: SegmentedButton.styleFrom(
                  selectedBackgroundColor: StudyPalette.emberSoft,
                  selectedForegroundColor: StudyPalette.ember,
                ),
              ),
              const SizedBox(height: 12),

              // 关联教材
              if (widget.books != null && widget.books!.isNotEmpty)
                DropdownButtonFormField<String>(
                  initialValue: _selectedBookId,
                  decoration: const InputDecoration(labelText: '关联教材（可选）'),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('不关联')),
                    ...widget.books!.map(
                      (b) => DropdownMenuItem(
                        value: b.id,
                        child: Text(b.title, overflow: TextOverflow.ellipsis),
                      ),
                    ),
                  ],
                  onChanged: (v) => setState(() => _selectedBookId = v),
                ),
              if (widget.books != null && widget.books!.isNotEmpty)
                const SizedBox(height: 12),

              // 单元/课（可选）
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '单元（可选）',
                        hintText: '如 1',
                      ),
                      initialValue: _chapter?.toString() ?? '',
                      onChanged: (v) => _chapter = int.tryParse(v),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '课/页码（可选）',
                        hintText: '如 1',
                      ),
                      initialValue: _page?.toString() ?? '',
                      onChanged: (v) => _page = int.tryParse(v),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // 内容
              TextFormField(
                controller: _textCtrl,
                decoration: const InputDecoration(labelText: '内容 *'),
                validator:
                    (v) => (v == null || v.trim().isEmpty) ? '请输入内容' : null,
              ),
              const SizedBox(height: 10),

              TextFormField(
                controller: _defCtrl,
                decoration: const InputDecoration(labelText: '释义（可选）'),
                maxLines: 2,
              ),
              const SizedBox(height: 10),

              TextFormField(
                controller: _extraCtrl,
                decoration: const InputDecoration(
                  labelText: '附加信息（可选）',
                  hintText: '拼音/音标/出处',
                ),
              ),
              const SizedBox(height: 16),

              FilledButton(
                onPressed: _submit,
                child: Text(_isEditing ? '保存' : '添加'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
