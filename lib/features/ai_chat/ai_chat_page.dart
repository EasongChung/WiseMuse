import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../../core/debug/app_log.dart';
import '../../core/models/book.dart';
import '../../core/models/chat_message.dart';
import '../../core/storage/book_dao.dart';
import '../../core/storage/chat_dao.dart';
import '../../core/storage/database.dart';
import '../../core/theme/app_theme.dart';
import '../../services/ai_service.dart';
import '../../services/native_tts_service.dart';
import '../../services/rag/rag_qa_service.dart';

/// [v0.1.48] 「问AI」智能伴读会话页面。
///
/// 功能：
/// 1. 多轮自由问答 / 课文伴读。
/// 2. 支持选择已导入书籍进行 RAG 知识库问答。
/// 3. 本地与云端大模型自动回退。
/// 4. 消息持久化、一键清空、一键 TTS 朗读与复制。
class AiChatPage extends StatefulWidget {
  const AiChatPage({super.key});

  @override
  State<AiChatPage> createState() => _AiChatPageState();
}

class _AiChatPageState extends State<AiChatPage> {
  static const _tag = 'ai_chat';

  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final NativeTtsService _tts = NativeTtsService();

  List<ChatMessage> _messages = [];
  List<Book> _books = [];
  String? _selectedBookId; // null = 通用助教，非空 = 指定书籍知识库
  bool _loading = true;
  bool _generating = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      final db = await DatabaseProvider.database;
      final books = await BookDao(db).getAll();
      final msgs = await ChatDao(db).getMessages(bookId: _selectedBookId);
      if (!mounted) return;
      setState(() {
        _books = books;
        _messages = msgs;
        _loading = false;
      });
      _scrollToBottom();
    } catch (e, s) {
      AppLog.e(_tag, '初始化会话失败: $e\n$s');
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMessages() async {
    try {
      final db = await DatabaseProvider.database;
      final msgs = await ChatDao(db).getMessages(bookId: _selectedBookId);
      if (!mounted) return;
      setState(() => _messages = msgs);
      _scrollToBottom();
    } catch (_) {}
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendMessage([String? presetText]) async {
    final query = (presetText ?? _textController.text).trim();
    if (query.isEmpty || _generating) return;

    _textController.clear();
    final db = await DatabaseProvider.database;
    final chatDao = ChatDao(db);

    Book? currentBook;
    if (_selectedBookId != null) {
      currentBook = _books.where((b) => b.id == _selectedBookId).firstOrNull;
    }

    final userMsg = ChatMessage.create(
      role: 'user',
      content: query,
      bookId: _selectedBookId,
      bookTitle: currentBook?.title,
    );

    await chatDao.insert(userMsg);
    setState(() {
      _messages.add(userMsg);
      _generating = true;
    });
    _scrollToBottom();

    String answer = '';
    String? sources;

    try {
      if (_selectedBookId != null) {
        // RAG 知识库问答
        final ragAnswer = await RagQaService.instance.ask(
          _selectedBookId!,
          query,
        );
        answer = ragAnswer ?? '在知识库中未找到相关内容，建议换个问题提问。';
      } else {
        // 通用对话 Prompt
        final prompt = '''你是一个亲切耐心的少儿智能学习助手（WiseMuse 智启陪读）。
回答要求：
1. 语言亲切生动，适合中小学生阅读理解。
2. 解释概念要举通俗易懂的例子。
3. 排版清晰，层次分明。

小朋友的问题：$query''';
        final aiResult = await AiService().complete(prompt);
        answer = aiResult?.text ?? '抱歉，我现在无法回答这个问题，请检查大模型或网络设置。';
      }
    } catch (e) {
      AppLog.e(_tag, '生成回答失败: $e');
      answer = '回答出错了：$e';
    }

    final assistantMsg = ChatMessage.create(
      role: 'assistant',
      content: answer,
      bookId: _selectedBookId,
      bookTitle: currentBook?.title,
      sources: sources,
    );

    await chatDao.insert(assistantMsg);
    if (!mounted) return;

    setState(() {
      _messages.add(assistantMsg);
      _generating = false;
    });
    _scrollToBottom();
  }

  Future<void> _clearHistory() async {
    final ok = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('清空会话记录'),
            content: const Text('确定要清空当前的聊天记录吗？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text(
                  '清空',
                  style: TextStyle(color: StudyPalette.ember),
                ),
              ),
            ],
          ),
    );
    if (ok == true) {
      final db = await DatabaseProvider.database;
      await ChatDao(db).clearMessages(bookId: _selectedBookId);
      await _loadMessages();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('问AI 智能伴读'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '清空会话',
            onPressed: _messages.isEmpty ? null : _clearHistory,
          ),
        ],
      ),
      body:
          _loading
              ? const Center(child: CircularProgressIndicator())
              : Column(
                children: [
                  _buildScopeSelector(isDark),
                  const Divider(height: 1),
                  Expanded(
                    child:
                        _messages.isEmpty
                            ? _buildEmptyState()
                            : _buildMessageList(isDark),
                  ),
                  if (_generating) _buildGeneratingIndicator(),
                  _buildInputBar(isDark),
                ],
              ),
    );
  }

  Widget _buildScopeSelector(bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: isDark ? StudyPalette.darkCard : StudyPalette.parchmentDeep,
      child: Row(
        children: [
          const Icon(Icons.psychology, size: 18, color: StudyPalette.ember),
          const SizedBox(width: 8),
          const Text(
            '知识库模式：',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String?>(
                isExpanded: true,
                value: _selectedBookId,
                items: [
                  const DropdownMenuItem(
                    value: null,
                    child: Text(
                      '🌟 全能小助教 (通用问答)',
                      style: TextStyle(fontSize: 13),
                    ),
                  ),
                  ..._books.map(
                    (b) => DropdownMenuItem(
                      value: b.id,
                      child: Text(
                        '📖 课本: ${b.title}',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ),
                ],
                onChanged: (v) {
                  setState(() => _selectedBookId = v);
                  _loadMessages();
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    final presets = [
      '这篇课文讲了什么道理？',
      '帮我用生动的故事解释这个成语',
      '给我讲一首描写春天的古诗',
      '小学生如何写好一篇记叙文？',
    ];

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(
                color: StudyPalette.parchmentDeep,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.auto_awesome,
                size: 36,
                color: StudyPalette.ember,
              ),
            ),
            const SizedBox(height: 16),
            Text('想问点什么呢？', style: titleStyle(fontSize: 18)),
            const SizedBox(height: 6),
            const Text(
              '你可以随时向 AI 小助教提问或讨论课文',
              style: TextStyle(fontSize: 13, color: StudyPalette.inkSoft),
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children:
                  presets.map((p) {
                    return ActionChip(
                      label: Text(p, style: const TextStyle(fontSize: 12)),
                      onPressed: () => _sendMessage(p),
                    );
                  }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageList(bool isDark) {
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        final msg = _messages[index];
        final isUser = msg.role == 'user';
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.82,
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color:
                    isUser
                        ? StudyPalette.ember
                        : (isDark ? StudyPalette.darkCard : Colors.white),
                borderRadius: BorderRadius.circular(14),
                border:
                    isUser
                        ? null
                        : Border.all(
                          color:
                              isDark
                                  ? StudyPalette.darkBorder
                                  : StudyPalette.linen,
                        ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (isUser)
                    Text(
                      msg.content,
                      style: const TextStyle(
                        fontSize: 14,
                        height: 1.5,
                        color: Colors.white,
                      ),
                    )
                  else
                    MarkdownBody(
                      data: msg.content,
                      selectable: true,
                      styleSheet: MarkdownStyleSheet(
                        p: TextStyle(
                          fontSize: 14,
                          height: 1.5,
                          color: StudyPalette.onSurfaceResolved(context),
                        ),
                        strong: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: StudyPalette.onSurfaceResolved(context),
                        ),
                        code: TextStyle(
                          fontSize: 12,
                          backgroundColor: StudyPalette.parchmentDeep,
                          color: StudyPalette.ember,
                        ),
                        codeblockDecoration: BoxDecoration(
                          color: StudyPalette.parchmentDeep,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        blockquoteDecoration: BoxDecoration(
                          color: StudyPalette.parchmentDeep,
                          borderRadius: BorderRadius.circular(6),
                          border: const Border(
                            left: BorderSide(
                              color: StudyPalette.ember,
                              width: 3,
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (!isUser) ...[
                    const SizedBox(height: 6),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        InkWell(
                          onTap: () => _tts.speak(msg.content),
                          child: const Padding(
                            padding: EdgeInsets.all(4),
                            child: Icon(
                              Icons.volume_up_outlined,
                              size: 16,
                              color: StudyPalette.inkSoft,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        InkWell(
                          onTap: () {
                            Clipboard.setData(ClipboardData(text: msg.content));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('已复制到剪贴板')),
                            );
                          },
                          child: const Padding(
                            padding: EdgeInsets.all(4),
                            child: Icon(
                              Icons.copy_outlined,
                              size: 16,
                              color: StudyPalette.inkSoft,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildGeneratingIndicator() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      alignment: Alignment.centerLeft,
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 8),
          Text(
            'AI 正在思考中…',
            style: TextStyle(fontSize: 12, color: StudyPalette.inkSoft),
          ),
        ],
      ),
    );
  }

  Widget _buildInputBar(bool isDark) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      decoration: BoxDecoration(
        color: isDark ? StudyPalette.darkCard : StudyPalette.parchment,
        border: Border(
          top: BorderSide(
            color: isDark ? StudyPalette.darkBorder : StudyPalette.linen,
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _textController,
              decoration: InputDecoration(
                hintText: _selectedBookId != null ? '提问关于这本书的内容…' : '输入你想问的问题…',
                hintStyle: const TextStyle(
                  fontSize: 14,
                  color: StudyPalette.inkSoft,
                ),
                isDense: true,
                filled: true,
                fillColor: isDark ? StudyPalette.darkBorder : Colors.white,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide.none,
                ),
              ),
              minLines: 1,
              maxLines: 4,
              onSubmitted: (_) => _sendMessage(),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            onPressed: _generating ? null : () => _sendMessage(),
            icon: const Icon(Icons.send, size: 18),
            style: IconButton.styleFrom(
              backgroundColor: StudyPalette.ember,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}
