import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../../core/debug/app_log.dart';
import '../../core/models/book.dart';
import '../../core/models/chat_message.dart';
import '../../core/settings/settings_service.dart';
import '../../core/storage/book_dao.dart';
import '../../core/storage/chat_dao.dart';
import '../../core/storage/database.dart';
import '../../core/theme/app_theme.dart';
import '../../services/ai_service.dart';
import '../../services/asr_service.dart';
import '../../services/llm_service.dart';
import '../../services/native_tts_service.dart';
import '../../services/picker_service.dart';
import '../../services/rag/rag_qa_service.dart';
import '../../services/vosk_asr_service.dart';
import '../../widgets/import_sheet.dart';
import '../../widgets/top_toast.dart';

/// [v0.1.48] [v0.1.50] [v0.1.52] 「问AI」智能伴读会话页面。
///
/// 功能：
/// 1. 多轮自由问答 / 课文伴读。
/// 2. 支持选择已导入书籍进行 RAG 知识库问答。
/// 3. 语音识别输入（Vosk 离线 ASR）与多模态图片提问。
/// 4. 欢迎页面呈现 WiseMuse 介绍，会话中禁止 AI 重复自我介绍。
/// 5. 顶部支持新建会话与会话历史查看管理。
/// 6. 消息 Markdown 富文本渲染、图片缩略图、TTS 朗读与复制。
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
  final AsrService _asr = VoskAsrService();

  List<ChatMessage> _messages = [];
  List<Book> _books = [];
  String? _selectedBookId; // null = 通用助教，非空 = 指定书籍知识库
  bool _loading = true;
  bool _generating = false;
  bool _isListening = false;

  /// [v0.1.52] 暂存待发送的图片路径。
  List<String> _pendingImagePaths = [];

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    if (_isListening) {
      unawaited(_asr.stop());
    }
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

  /// [v0.1.53] 确保本地模型已加载。
  ///
  /// 与 [AiService] 不同，本方法**不**判断 `preferOffline`/`isApiConfigured`，
  /// 而是直接去加载本地模型。调用时机：云端 + 本地首次双失败后的回落重试。
  Future<bool> _ensureLocalModel() async {
    final modelPath = await SettingsService.instance.getLocalModelPath();
    if (modelPath == null || modelPath.isEmpty) return false;

    final llm = LlmService.instance;
    if (llm.isLoaded) return true;
    try {
      AppLog.d(_tag, '自动加载本地模型: $modelPath');
      return await llm.init(modelPath);
    } catch (e) {
      AppLog.e(_tag, '自动加载本地模型失败: $e');
      return false;
    }
  }

  Future<void> _sendMessage([String? presetText]) async {
    final query = (presetText ?? _textController.text).trim();
    final hasImages = _pendingImagePaths.isNotEmpty;
    if (query.isEmpty && !hasImages) return;
    if (_generating) return;

    if (_isListening) {
      await _toggleVoiceInput();
    }

    if (hasImages) {
      _textController.clear();
      final imagePaths = List<String>.from(_pendingImagePaths);
      setState(() => _pendingImagePaths = []);
      await _sendImageMessage(query, imagePaths);
      return;
    }

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

    try {
      if (_selectedBookId != null) {
        final ragAnswer = await RagQaService.instance.ask(
          _selectedBookId!,
          query,
        );
        answer = ragAnswer ?? '在知识库中未找到相关内容，建议换个问题提问。';
      } else {
        final preferOffline = await SettingsService.instance.getPreferOffline();
        final prompt = _buildChatPrompt(query, isLocal: preferOffline);
        final aiResult = await AiService().complete(prompt);

        if (aiResult == null) {
          // [v0.1.53] 云端+本地首次双失败 → 真正加载本地模型，直接用本地引擎重试
          final localReady = await _ensureLocalModel();
          if (localReady) {
            try {
              final localPrompt = _buildChatPrompt(query, isLocal: true);
              final localText = await LlmService.instance.chat(localPrompt);
              answer =
                  localText.isNotEmpty
                      ? localText
                      : '抱歉，本地模型这次没有产出回答，请换个问题再试试。';
            } catch (e) {
              AppLog.e(_tag, '本地模型对话失败: $e');
              answer = '抱歉，本地模型对话失败：$e';
            }
          } else {
            answer = '抱歉，我现在无法回答这个问题。云端模型不可用，且未配置或未能加载本地模型。请检查「设置」中的大模型配置。';
          }
        } else {
          answer = aiResult.text;
        }
      }
    } catch (e) {
      AppLog.e(_tag, '生成回答失败: $e');
      answer = '回答出错了：$e';
    }

    answer = _cleanSpecialTokens(answer);

    final assistantMsg = ChatMessage.create(
      role: 'assistant',
      content: answer,
      bookId: _selectedBookId,
      bookTitle: currentBook?.title,
    );

    await chatDao.insert(assistantMsg);
    if (!mounted) return;

    setState(() {
      _messages.add(assistantMsg);
      _generating = false;
    });
    _scrollToBottom();
  }

  /// [v0.1.52] 发送图片消息（多模态云端，本地引擎不支持图片）。
  Future<void> _sendImageMessage(String query, List<String> imagePaths) async {
    final db = await DatabaseProvider.database;
    final chatDao = ChatDao(db);

    Book? currentBook;
    if (_selectedBookId != null) {
      currentBook = _books.where((b) => b.id == _selectedBookId).firstOrNull;
    }

    final userMsg = ChatMessage.create(
      role: 'user',
      content: query.isEmpty ? '请描述这张图片' : query,
      imagePaths: imagePaths,
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
    try {
      final aiService = AiService();
      final visionResult = await aiService.completeVision(
        imagePaths,
        prompt: query.isNotEmpty ? query : '请详细描述这张图片里的内容',
        predictLength: 1024,
      );

      if (visionResult == '__MODEL_NOT_VISION__') {
        answer = '⚠️ 当前配置模型不支持多模态，请在「设置」中更换支持图片理解的模型。';
      } else if (visionResult != null && visionResult.isNotEmpty) {
        answer = visionResult;
      } else {
        if (query.isNotEmpty) {
          final prompt = _buildChatPrompt(query);
          final textResult = await AiService().complete(prompt);
          answer = textResult?.text ?? '抱歉，图片分析失败，请检查模型或网络设置。';
        } else {
          answer = '抱歉，图片分析失败，请检查模型或网络设置。';
        }
      }
    } catch (e) {
      AppLog.e(_tag, '图片分析失败: $e');
      answer = '图片分析失败：$e';
    }

    answer = _cleanSpecialTokens(answer);

    final assistantMsg = ChatMessage.create(
      role: 'assistant',
      content: answer,
      bookId: _selectedBookId,
      bookTitle: currentBook?.title,
    );

    await chatDao.insert(assistantMsg);
    if (!mounted) return;

    setState(() {
      _messages.add(assistantMsg);
      _generating = false;
    });
    _scrollToBottom();
  }

  /// 构建问答 Prompt。本地模型下使用更简洁直接的结构，避免触发 MiniCPM 等模型的模板混乱。
  String _buildChatPrompt(String query, {bool isLocal = false}) {
    if (isLocal) {
      return '''你是一个亲切耐心的少儿学习助手。请直接回答问题，不要做自我介绍。

问题：$query''';
    }
    return '''你是一个亲切耐心的少儿智能学习助手（WiseMuse 智启陪读）。
回答要求：
1. 请直接针对问题给出回答，严禁在回答开头做自我介绍（如"我是WiseMuse..."或"你好小朋友..."等无意义开场白）。
2. 语言亲切生动、通俗易懂，适合中小学生阅读理解，必要时举具体生动的例子。
3. 排版清晰，层次分明，使用 Markdown 格式展现重点。

小朋友的问题：$query''';
  }

  /// 清理 MiniCPM / Llama / 通用模型的特殊 token（如 `<用户>`、`<AI>`、`<s>`、`</s>`、`<reserved_*>` 等）。
  static String _cleanSpecialTokens(String text) {
    if (text.isEmpty) return text;
    return text
        .replaceAll(
          RegExp(
            r'<用户>|<AI>|<s>|<\/s>|<reserved_\d+>|<\|user\|>|<\|assistant\|>|<\|system\|>|<\|endoftext\|>|<\|im_end\|>|<\|im_start\|>',
          ),
          '',
        )
        .trim();
  }

  Future<void> _toggleVoiceInput() async {
    try {
      if (_isListening) {
        setState(() => _isListening = false);
        final text = await _asr.stop();
        if (text.isNotEmpty) {
          final current = _textController.text.trim();
          _textController.text = current.isEmpty ? text : '$current $text';
          _textController.selection = TextSelection.fromPosition(
            TextPosition(offset: _textController.text.length),
          );
        }
      } else {
        final settings = SettingsService.instance;
        final modelPath = await settings.getVoskModelPath();
        if (modelPath == null || modelPath.isEmpty) {
          if (mounted) {
            TopToast.show(context, '⚠️ 请先在「设置」中下载或配置 Vosk 语音识别模型');
          }
          return;
        }
        if (!_asr.isLoaded) {
          final ok = await _asr.init(modelPath);
          if (!ok) {
            if (mounted) {
              TopToast.show(context, '❌ Vosk 语音模型初始化失败');
            }
            return;
          }
        }
        final started = await _asr.start();
        if (mounted) setState(() => _isListening = started);
      }
    } catch (e, s) {
      AppLog.e(_tag, '语音录入异常: $e\n$s');
      if (mounted) setState(() => _isListening = false);
    }
  }

  /// [v0.1.52] 拍照/相册选图 -> 暂存路径，等待用户输入后发送。
  Future<void> _pickImage() async {
    final action = await showModalBottomSheet<ImportAction>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder:
          (ctx) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.camera_alt_outlined),
                  title: const Text('拍摄图片'),
                  onTap: () => Navigator.pop(ctx, ImportAction.camera),
                ),
                ListTile(
                  leading: const Icon(Icons.photo_library_outlined),
                  title: const Text('从相册选取'),
                  onTap: () => Navigator.pop(ctx, ImportAction.gallery),
                ),
              ],
            ),
          ),
    );
    if (action == null || !mounted) return;

    final pickedPath =
        action == ImportAction.camera
            ? await PickerService().pickFromCamera()
            : await PickerService().pickFromGallery();
    if (pickedPath == null || !mounted) return;

    setState(() {
      _pendingImagePaths.add(pickedPath);
    });

    TopToast.show(context, '📷 图片已选择，输入问题后发送即可');
  }

  Future<void> _startNewChat() async {
    if (_messages.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('开启新会话'),
            content: const Text('开启新会话将清空当前对话屏幕，过往记录可在「历史记录」中随时查看。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('开启新会话'),
              ),
            ],
          ),
    );
    if (ok == true && mounted) {
      setState(() {
        _messages = [];
        _pendingImagePaths = [];
      });
      _textController.clear();
      TopToast.show(context, '已开启全新对话');
    }
  }

  Future<void> _showHistorySheet() async {
    final db = await DatabaseProvider.database;
    final chatDao = ChatDao(db);
    final allMsgs = await chatDao.getMessages(bookId: _selectedBookId);

    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor:
          Theme.of(context).brightness == Brightness.dark
              ? StudyPalette.darkCard
              : StudyPalette.parchment,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder:
          (ctx) => StatefulBuilder(
            builder: (ctx, setSheetState) {
              return SizedBox(
                height: MediaQuery.of(context).size.height * 0.7,
                child: Column(
                  children: [
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        margin: const EdgeInsets.only(top: 12, bottom: 8),
                        decoration: BoxDecoration(
                          color: StudyPalette.linen,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.history,
                            color: StudyPalette.ember,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Text('会话历史记录', style: titleStyle(fontSize: 16)),
                          const Spacer(),
                          if (allMsgs.isNotEmpty)
                            TextButton.icon(
                              icon: const Icon(
                                Icons.delete_sweep,
                                size: 18,
                                color: StudyPalette.ember,
                              ),
                              label: const Text(
                                '清空全部',
                                style: TextStyle(
                                  color: StudyPalette.ember,
                                  fontSize: 12,
                                ),
                              ),
                              onPressed: () async {
                                final confirm = await showDialog<bool>(
                                  context: context,
                                  builder:
                                      (c) => AlertDialog(
                                        title: const Text('清空全部历史记录'),
                                        content: const Text(
                                          '确定要彻底清空该模式下的所有会话记录吗？',
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed:
                                                () => Navigator.pop(c, false),
                                            child: const Text('取消'),
                                          ),
                                          FilledButton(
                                            style: FilledButton.styleFrom(
                                              backgroundColor:
                                                  StudyPalette.ember,
                                            ),
                                            onPressed:
                                                () => Navigator.pop(c, true),
                                            child: const Text('清空'),
                                          ),
                                        ],
                                      ),
                                );
                                if (confirm == true) {
                                  await chatDao.clearMessages(
                                    bookId: _selectedBookId,
                                  );
                                  await _loadMessages();
                                  if (ctx.mounted) Navigator.pop(ctx);
                                }
                              },
                            ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child:
                          allMsgs.isEmpty
                              ? const Center(
                                child: Text(
                                  '暂无历史对话记录',
                                  style: TextStyle(color: StudyPalette.inkSoft),
                                ),
                              )
                              : ListView.separated(
                                padding: const EdgeInsets.all(12),
                                itemCount: allMsgs.length,
                                separatorBuilder:
                                    (_, _) => const Divider(height: 1),
                                itemBuilder: (c, i) {
                                  final m = allMsgs[i];
                                  final isUser = m.role == 'user';
                                  return ListTile(
                                    dense: true,
                                    leading: CircleAvatar(
                                      radius: 14,
                                      backgroundColor:
                                          isUser
                                              ? StudyPalette.ember
                                              : StudyPalette.moss,
                                      child: Icon(
                                        isUser
                                            ? Icons.person
                                            : Icons.auto_awesome,
                                        size: 14,
                                        color: Colors.white,
                                      ),
                                    ),
                                    title: Text(
                                      m.content,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                    subtitle: Text(
                                      isUser ? '提问' : '回答',
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: StudyPalette.inkSoft,
                                      ),
                                    ),
                                    onTap: () {
                                      Clipboard.setData(
                                        ClipboardData(text: m.content),
                                      );
                                      TopToast.show(context, '已复制内容到剪贴板');
                                    },
                                  );
                                },
                              ),
                    ),
                  ],
                ),
              );
            },
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('问AI 智能伴读'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_comment_outlined),
            tooltip: '开启新会话',
            onPressed: _startNewChat,
          ),
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: '会话历史',
            onPressed: _showHistorySheet,
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
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: StudyPalette.parchmentDeep,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: StudyPalette.linen),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.auto_awesome,
                        color: StudyPalette.ember,
                        size: 24,
                      ),
                      const SizedBox(width: 8),
                      Text('WiseMuse 智启陪读', style: titleStyle(fontSize: 18)),
                    ],
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    '📚 专为中小学生打造的 AI 智能伴读小助手\n'
                    '✨ 自由问答 · 课文答疑 · 知识点生动解析 · 写作指导\n'
                    '💡 支持选择已导入课本开启精准 RAG 知识库问答',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: StudyPalette.inkSoft,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Text('想问点什么呢？', style: titleStyle(fontSize: 16)),
            const SizedBox(height: 12),
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
        final hasImages = msg.imagePaths != null && msg.imagePaths!.isNotEmpty;
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
                  // [v0.1.52] 用户消息中的图片缩略图
                  if (isUser && hasImages)
                    ...msg.imagePaths!.map((path) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.file(
                            File(path),
                            width: 200,
                            height: 150,
                            fit: BoxFit.cover,
                            errorBuilder:
                                (_, __, ___) => Container(
                                  width: 200,
                                  height: 150,
                                  color: Colors.white24,
                                  child: const Icon(
                                    Icons.broken_image_outlined,
                                    color: Colors.white54,
                                  ),
                                ),
                          ),
                        ),
                      );
                    }),
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
                        code: const TextStyle(
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
                            TopToast.show(context, '已复制到剪贴板');
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
      padding: const EdgeInsets.fromLTRB(10, 8, 12, 16),
      decoration: BoxDecoration(
        color: isDark ? StudyPalette.darkCard : StudyPalette.parchment,
        border: Border(
          top: BorderSide(
            color: isDark ? StudyPalette.darkBorder : StudyPalette.linen,
          ),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_isListening)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
              margin: const EdgeInsets.only(bottom: 6),
              decoration: BoxDecoration(
                color: StudyPalette.emberSoft.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.mic, size: 16, color: StudyPalette.ember),
                  SizedBox(width: 6),
                  Text(
                    '正在聆听，请说话…（再次点击麦克风停止）',
                    style: TextStyle(
                      fontSize: 12,
                      color: StudyPalette.ember,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          // [v0.1.52] 待发送图片缩略图预览
          if (_pendingImagePaths.isNotEmpty)
            SizedBox(
              height: 56,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: _pendingImagePaths.length,
                itemBuilder: (ctx, i) {
                  return Stack(
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(right: 6, bottom: 4),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.file(
                            File(_pendingImagePaths[i]),
                            width: 48,
                            height: 48,
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                      Positioned(
                        top: -4,
                        right: 2,
                        child: GestureDetector(
                          onTap: () {
                            setState(() {
                              _pendingImagePaths.removeAt(i);
                            });
                          },
                          child: Container(
                            decoration: const BoxDecoration(
                              color: Colors.black54,
                              shape: BoxShape.circle,
                            ),
                            padding: const EdgeInsets.all(2),
                            child: const Icon(
                              Icons.close,
                              size: 12,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          Row(
            children: [
              // 图片拍摄/相册输入（不再 OCR，直接发多模态）
              IconButton(
                icon: const Icon(
                  Icons.image_outlined,
                  size: 22,
                  color: StudyPalette.inkSoft,
                ),
                tooltip: '拍照/相册图片',
                onPressed: _generating ? null : _pickImage,
              ),
              Expanded(
                child: TextField(
                  controller: _textController,
                  decoration: InputDecoration(
                    hintText:
                        _selectedBookId != null
                            ? '提问关于这本书的内容…'
                            : (_pendingImagePaths.isNotEmpty
                                ? '输入关于图片的问题（可选）…'
                                : '输入你想问的问题…'),
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
              const SizedBox(width: 6),
              // [v0.1.52] 语音输入移至右侧（输入框与发送按钮之间）
              IconButton(
                icon: Icon(
                  _isListening ? Icons.mic : Icons.mic_none_outlined,
                  size: 22,
                  color:
                      _isListening ? StudyPalette.ember : StudyPalette.inkSoft,
                ),
                tooltip: _isListening ? '停止语音录入' : '语音输入',
                onPressed: _generating ? null : _toggleVoiceInput,
              ),
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
        ],
      ),
    );
  }
}
