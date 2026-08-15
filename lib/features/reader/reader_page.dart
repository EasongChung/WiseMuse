import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/debug/app_log.dart';
import '../../core/models/book.dart';
import '../../core/models/knowledge_point.dart';
import '../../core/models/sentence.dart';
import '../../core/models/word_entry.dart';
import '../../core/settings/settings_service.dart';
import '../../core/storage/database.dart';
import '../../core/storage/knowledge_point_dao.dart';
import '../../core/storage/sentence_dao.dart';
import '../../core/storage/word_entry_dao.dart';
import '../../core/theme/app_theme.dart';
import '../../services/docx_html_converter.dart';
import '../../services/native_tts_service.dart';
import '../../services/ocr_geometry_service.dart';
import '../../services/ocr_service.dart';
import '../../services/pdf_service.dart';
import '../../services/text_position_service.dart';
import '../../services/translation_engine.dart';
import '../../services/rag/rag_qa_service.dart';
import '../../vendor/flutter_pdfview/flutter_pdfview.dart';
import '../knowledge/knowledge_detail_sheet.dart';
import '../assistant/knowledge_explain_sheet.dart';
import '../follow/follow_page.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// [v0.2.0] 阅读页：按来源类型切换四种模式。
///
/// - **PDF 原文**：PDFView 平台视图 + 点击句朗读 + 高亮。
///   电子版走 PDFBox 字符坐标；扫描件（无文本层）走 render 图 OCR 归一化坐标
///   × PdfRenderer pageWidth/Height ≈ PDF 点（crop=(0,0)/rot=0 成立）。
/// - **图片**：InteractiveViewer + 归一化坐标点击朗读（几何来自 SentenceDao，
///   空则现场重跑 OCR 缓存）。
/// - **Word**：docx→HTML WebView（可切文本模式）。
/// - **TXT/文本**：句子列表点击朗读；长文 text_chunker 虚拟分页。
class ReaderPage extends StatefulWidget {
  const ReaderPage({super.key, required this.book});

  final Book book;

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> with WidgetsBindingObserver {
  static const _tag = 'reader';

  final NativeTtsService _tts = NativeTtsService();

  // 状态
  bool _useOriginal = true; // 原文模式（有原文时）
  List<Sentence> _sentences = const [];
  bool _loading = true;
  String? _error;

  // PDF 几何缓存（电子版：字符坐标；扫描件：OCR 句子）
  final Map<int, List<SentenceBox>> _pdfSentenceCache = {};
  final Map<int, PdfPageGeometry?> _pageGeomCache = {};
  final Map<int, List<OcrSentence>> _pdfOcrSentenceCache = {};
  final Map<int, Future<List<OcrSentence>>> _pdfOcrInFlight = {};

  // PDFView 控制器（onViewCreated 赋值，供 onTap/onPageChanged 使用）
  PDFViewController? _pdfController;
  int _pdfViewGeneration = 0;

  // 图片模式
  ui.Size? _imageViewSize;
  ui.Size? _imagePixelSize; // 图片实际像素尺寸（用于点击坐标归一化）
  final TransformationController _imgTransformCtrl = TransformationController();
  List<OcrSentence> _imgSentences = const [];
  OcrSentence? _imgHighlight;

  // 文本模式（TXT / Word 文本视图 / PDF 文本模式共用）：当前朗读句索引（高亮）
  int? _textHighlightIndex;

  // 文本模式：页码导航
  int _textPageIndex = 0;
  List<List<Sentence>> _textPages = const [];

  // [v2.8.0] 底部文本面板独立刷新回调 & 可见性
  int _pdfCurrentPage = 0;

  // [v2.8.0] 底部文本面板独立刷新回调
  VoidCallback? _sheetRebuild;
  final ScrollController _sheetScrollController = ScrollController();

  // 自动连读状态
  bool _autoPlaying = false;

  // 页面级朗读代次：每次点击、模式切换或 dispose 自增。耗时 PDF/OCR
  // 任务完成后必须校验代次，旧任务不得晚到发声。
  int _speechRequest = 0;
  int _workGeneration = 0;
  bool _switchingMode = false;

  // [v2.11.0] 播放状态追踪：_speakingStartedAt == _speechRequest 时表示 TTS 正在播放。
  int _speakingStartedAt = 0;
  bool get _ttsSpeaking =>
      _speakingStartedAt > 0 && _speakingStartedAt == _speechRequest;

  // [v2.9.0] 文本选区——选中文字后弹出查词栏
  String? _selectedText;

  // [v2.9.0] 当前朗读/选中句索引（用于底栏操作条）
  int? _activeSentenceIndex;
  String? _activeSentenceText;

  // [v2.9.0] 知识点按页查询 LRU 缓存（max 20 页），翻页不重复查 DB。
  static const int _kKnowledgeCacheMax = 20;
  final LinkedHashMap<String, List<KnowledgePoint>> _knowledgePageCache =
      LinkedHashMap<String, List<KnowledgePoint>>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _speechRequest++;
      _workGeneration++;
      unawaited(_tts.stop());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _speechRequest++;
    _workGeneration++;
    _pdfViewGeneration++;
    unawaited(_tts.stop());
    _pdfController = null;
    _imgTransformCtrl.dispose();
    _sheetScrollController.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      await _tts.init();
      await _loadSentences();
      if (widget.book.source == BookSource.pdf) {
        await _initPdf();
      } else if (widget.book.source == BookSource.camera ||
          widget.book.source == BookSource.gallery) {
        await _initImage();
      }
      // 文本书（docx/txt）无需额外初始化：文本模式直接读 _sentences
    } catch (e, s) {
      AppLog.e(_tag, '阅读页初始化失败: $e\n$s');
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadSentences() async {
    final db = await DatabaseProvider.database;
    final list = await SentenceDao(db).getByBook(widget.book.id);
    if (mounted) {
      setState(() {
        _sentences = list;
        _computeTextPages(list);
      });
    }
  }

  /// 文本模式：按 page 分组，生成虚拟页。
  void _computeTextPages(List<Sentence> sentences) {
    if (sentences.isEmpty) {
      _textPages = const [];
      _textPageIndex = 0;
      return;
    }
    final grouped = <int, List<Sentence>>{};
    for (final s in sentences) {
      grouped.putIfAbsent(s.page, () => []).add(s);
    }
    final sorted =
        grouped.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    _textPages = sorted.map((e) => e.value).toList();
    _textPageIndex = _textPageIndex.clamp(0, _textPages.length - 1);
  }

  // ===== [v2.8.0] 原文/文本分页同步 =====

  /// 当前页文本（多页文档取 _pdfCurrentPage 对应页）。
  String get _displayText {
    final pages = _pageTexts;
    if (pages.isEmpty) return _sentences.map((s) => s.text).join('\n');
    final i = _pdfCurrentPage.clamp(0, pages.length - 1);
    return pages[i];
  }

  /// 当前文档的分页文本列表（多页模式用）。
  List<String> get _pageTexts {
    if (_textPages.isEmpty) return [];
    return _textPages
        .map((page) => page.map((s) => s.text).join('\n'))
        .toList();
  }

  /// 是否多页文档。
  bool get _isMultiPage => _pageTexts.length > 1;

  /// [v2.8.0] 统一翻页同步：更新共享页码、清除旧状态。
  /// 所有翻页操作（PDF onPageChanged / 文本翻页 / 目录跳页）最终调用此函数。
  void _syncPage(int page) {
    final total = _pageTexts.length;
    if (total <= 1) return;
    final next = page.clamp(0, total - 1);
    if (next == _pdfCurrentPage) return;
    _speechRequest++;
    unawaited(_tts.stop());
    if (!mounted) return;
    setState(() {
      _pdfCurrentPage = next;
      _textPageIndex = next;
      _textHighlightIndex = null;
      _imgHighlight = null;
      _pdfSentenceCache.clear();
      _pageGeomCache.clear();
    });
    _sheetRebuild?.call();
  }

  /// 文本模式翻页（+/- 翻页）。
  void _changePage(int delta) {
    final total = _pageTexts.length;
    if (total <= 1) return;
    _syncPage(_pdfCurrentPage + delta);
  }

  /// 文本模式左右滑翻页：依据横向位移方向切换当前页（多页文件）。
  void _onTextSwipePage(DragEndDetails details) {
    if (!_isMultiPage) return;
    final velocity = details.primaryVelocity;
    if (velocity == null) return;
    if (velocity < -350) {
      _changePage(1);
    } else if (velocity > 350) {
      _changePage(-1);
    }
  }

  // ===== PDF =====

  Future<void> _initPdf() async {
    final path = widget.book.originalFilePath;
    if (path == null) throw Exception('缺少 PDF 原文件');
    await PdfService().getPageCount(path);
  }

  /// onPageChanged / onViewCreated：下发 CropBox 尺寸（G2.5 必需）。
  Future<void> _syncPageSize(
    PDFViewController controller,
    int page,
    int viewGeneration,
  ) async {
    try {
      final path = widget.book.originalFilePath;
      if (path == null) return;
      final geom = await _getPageGeom(path, page);
      if (geom == null ||
          !mounted ||
          !_useOriginal ||
          _switchingMode ||
          viewGeneration != _pdfViewGeneration ||
          !identical(controller, _pdfController)) {
        return;
      }
      await controller.setPageSize(page, geom.pageWidth, geom.pageHeight);
    } catch (e) {
      if (mounted && viewGeneration == _pdfViewGeneration) {
        AppLog.e(_tag, 'syncPageSize($page) 失败: $e');
      }
    }
  }

  Future<PdfPageGeometry?> _getPageGeom(String path, int page) async {
    final cached = _pageGeomCache[page];
    if (cached != null) return cached;
    final data = await PdfService().extractTextPositions(path, page);
    final geom = data == null ? null : PdfPageGeometry.fromMap(data);
    _pageGeomCache[page] = geom;
    return geom;
  }

  /// 点击 PDF：命中句子 → 高亮 + 朗读；句子未中 → 段落兜底（仅高亮）。
  Future<void> _onPdfTap(
    PDFViewController controller,
    PdfTapDetails details,
    int viewGeneration,
  ) async {
    final path = widget.book.originalFilePath;
    if (path == null ||
        _switchingMode ||
        !_useOriginal ||
        viewGeneration != _pdfViewGeneration ||
        !identical(controller, _pdfController)) {
      return;
    }
    final request = ++_speechRequest;
    AppLog.d(_tag, 'PDF 点击 page=${details.page} (${details.x},${details.y})');
    try {
      // 点击新位置先停止旧句；后续每个耗时步骤都核对页面、视图和朗读代次。
      final stopped = await _tts.stop();
      if (!stopped ||
          !_isPdfRequestCurrent(request, controller, viewGeneration)) {
        return;
      }

      // 1) 电子版：字符坐标几何。无论原生 pageSize 是否已同步，始终
      // 按本次上报页尺寸归一到 PDFBox CropBox 点坐标。
      final geom = await _getPageGeom(path, details.page);
      if (!_isPdfRequestCurrent(request, controller, viewGeneration)) return;
      if (geom != null && geom.chars.isNotEmpty) {
        final width =
            details.pageWidth > 0 ? details.pageWidth : geom.pageWidth;
        final height =
            details.pageHeight > 0 ? details.pageHeight : geom.pageHeight;
        final point = ui.Offset(
          (details.x / width * geom.pageWidth).clamp(0.0, geom.pageWidth),
          (details.y / height * geom.pageHeight).clamp(0.0, geom.pageHeight),
        );
        final sentences = _pdfSentenceCache.putIfAbsent(details.page, () {
          return buildSentences(geom.chars);
        });
        final hit = hitSentence(sentences, point, snapEm: 4);
        if (hit != null) {
          AppLog.d(_tag, '命中句子: ${hit.text}');
          await controller.setHighlights(details.page, hit.rects);
          if (!_isPdfRequestCurrent(request, controller, viewGeneration)) {
            return;
          }
          await _speakRequest(hit.text, request);
          return;
        }
        final paraHit = hitParagraph(
          buildParagraphs(geom.chars),
          point,
          snapEm: 1.5,
        );
        if (paraHit != null) {
          AppLog.d(_tag, '未中句子，命中段落（仅高亮）');
          await controller.setHighlights(details.page, paraHit.rects);
          return;
        }
      }

      // 2) 扫描件：同一页的 render + OCR 只运行一份；结果无论哪次点击
      // 仍有效都会写入缓存，朗读代次只控制高亮和发声。
      final scanned = await _getPdfOcrSentences(path, details.page);
      if (!_isPdfRequestCurrent(request, controller, viewGeneration)) return;
      if (scanned.isNotEmpty) {
        final nx = details.x / (details.pageWidth > 0 ? details.pageWidth : 1);
        final ny =
            details.y / (details.pageHeight > 0 ? details.pageHeight : 1);
        final hit = OcrGeometryService.hitSentence(
          scanned,
          ui.Offset(nx.clamp(0, 1), ny.clamp(0, 1)),
        );
        if (hit != null) {
          final pdfRects =
              hit.rects
                  .map(
                    (r) => ui.Rect.fromLTRB(
                      r.left * details.pageWidth,
                      r.top * details.pageHeight,
                      r.right * details.pageWidth,
                      r.bottom * details.pageHeight,
                    ),
                  )
                  .toList();
          AppLog.d(_tag, '扫描件命中句子: ${hit.text}');
          await controller.setHighlights(details.page, pdfRects);
          if (!_isPdfRequestCurrent(request, controller, viewGeneration)) {
            return;
          }
          await _speakRequest(hit.text, request);
          return;
        }
      }

      if (_isPdfRequestCurrent(request, controller, viewGeneration)) {
        await controller.clearHighlights();
      }
    } catch (e) {
      if (_isPdfRequestCurrent(request, controller, viewGeneration)) {
        AppLog.e(_tag, 'PDF 点击处理失败: $e');
      }
    }
  }

  Future<List<OcrSentence>> _getPdfOcrSentences(String path, int page) async {
    final cached = _pdfOcrSentenceCache[page];
    if (cached != null) return cached;

    final workGeneration = _workGeneration;
    final future = _pdfOcrInFlight.putIfAbsent(
      page,
      () => _ocrPdfPage(path, page, workGeneration),
    );
    try {
      final result = await future;
      if (_isWorkCurrent(workGeneration)) {
        _pdfOcrSentenceCache[page] = result;
      }
      return result;
    } finally {
      if (identical(_pdfOcrInFlight[page], future)) {
        _pdfOcrInFlight.remove(page);
      }
    }
  }

  Future<List<OcrSentence>> _ocrPdfPage(
    String path,
    int page,
    int workGeneration,
  ) async {
    try {
      final png = await PdfService().renderPage(path, page, scale: 2.0);
      if (png == null || !_isWorkCurrent(workGeneration)) return const [];
      final tmp = await _writeTempPng(png);
      try {
        if (!_isWorkCurrent(workGeneration)) return const [];
        final result = await OcrService().recognizeFile(tmp);
        if (result == null) return const [];
        var w = 1.0;
        var h = 1.0;
        for (final b in result.blocks) {
          if (b.boundingBox.right > w) w = b.boundingBox.right;
          if (b.boundingBox.bottom > h) h = b.boundingBox.bottom;
        }
        return OcrGeometryService.buildSentences(
          result.blocks,
          imageWidth: w,
          imageHeight: h,
        );
      } finally {
        try {
          await File(tmp).delete();
        } catch (_) {}
      }
    } catch (e) {
      if (_isWorkCurrent(workGeneration)) {
        AppLog.e(_tag, '扫描件 OCR($page) 失败: $e');
      }
      return const [];
    }
  }

  // ===== 图片 =====

  Future<void> _initImage() async {
    final path = widget.book.originalFilePath;
    if (path == null) throw Exception('缺少图片原文件');
    // 读取图片实际像素尺寸（用于点击坐标归一化，BoxFit.contain 显示区域计算）
    try {
      final bytes = await File(path).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frameInfo = await codec.getNextFrame();
      _imagePixelSize = ui.Size(
        frameInfo.image.width.toDouble(),
        frameInfo.image.height.toDouble(),
      );
      codec.dispose();
    } catch (e) {
      AppLog.e(_tag, '读取图片尺寸失败: $e');
    }
    // 加载几何：先读 SentenceDao（导入已存），空则现场重跑 OCR
    if (_sentences.isNotEmpty) {
      final tmp = <OcrSentence>[];
      for (final s in _sentences) {
        final geo = decodeSentenceGeometry(s.geometry);
        if (geo != null && geo.isNotEmpty) {
          tmp.add(OcrSentence(text: s.text, rects: geo));
        }
      }
      _imgSentences = tmp;
    }
    if (_imgSentences.isEmpty) {
      final result = await OcrService().recognizeFile(path);
      if (result != null) {
        // 用 OcrBridge 返回的图片真实像素尺寸做归一化分母（与导入同源），
        // 不再用块外接框最大坐标近似。
        final w = result.width?.toDouble() ?? _imagePixelSize?.width ?? 1.0;
        final h = result.height?.toDouble() ?? _imagePixelSize?.height ?? 1.0;
        _imgSentences = OcrGeometryService.buildSentences(
          result.blocks,
          imageWidth: w,
          imageHeight: h,
        );
      }
    }
  }

  // ===== 朗读 =====

  bool _isSpeechRequestCurrent(int request) {
    return mounted && !_switchingMode && request == _speechRequest;
  }

  bool _isWorkCurrent(int generation) {
    return mounted && generation == _workGeneration;
  }

  bool _isPdfRequestCurrent(
    int request,
    PDFViewController controller,
    int viewGeneration,
  ) {
    return _isSpeechRequestCurrent(request) &&
        _useOriginal &&
        viewGeneration == _pdfViewGeneration &&
        identical(controller, _pdfController);
  }

  Future<void> _speak(String text) async {
    if (_switchingMode) return;
    final request = ++_speechRequest;
    await _speakRequest(text, request);
  }

  Future<void> _speakRequest(String text, int request) async {
    if (text.trim().isEmpty || !_isSpeechRequestCurrent(request)) return;
    _speakingStartedAt = request;
    AppLog.d(_tag, '朗读: "$text"');
    final ok = await _tts.speak(text);
    // 如果当前请求仍是最新，重置播放状态
    if (_isSpeechRequestCurrent(request)) {
      _speakingStartedAt = 0;
    }
    if (!ok && _isSpeechRequestCurrent(request)) {
      AppLog.w(_tag, 'TTS speak 未完成: "$text"');
    }
  }

  Future<void> _switchViewMode() async {
    if (_switchingMode) return;
    _speechRequest++;
    _workGeneration++;
    _pdfOcrInFlight.clear();
    setState(() => _switchingMode = true);

    final stopped = await _tts.stop();
    if (!mounted) return;
    if (!stopped) {
      setState(() => _switchingMode = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法停止朗读，请稍后重试')));
      return;
    }

    setState(() {
      _pdfViewGeneration++;
      _pdfController = null;
      _useOriginal = !_useOriginal;
      _textHighlightIndex = null;
      _imgHighlight = null;
      _switchingMode = false;
    });
  }

  // ===== 翻译 =====

  String _langDisplayName(String code) {
    switch (code) {
      case 'zh':
        return '中';
      case 'en':
        return '英';
      case 'ja':
        return '日';
      case 'ko':
        return '韩';
      case 'fr':
        return '法';
      case 'de':
        return '德';
      case 'es':
        return '西';
      case 'ru':
        return '俄';
      default:
        return code;
    }
  }

  Future<void> _markWord(String text) async {
    if (text.trim().isEmpty) return;
    AppLog.d(_tag, '标记生词: "$text"');
    try {
      final db = await DatabaseProvider.database;
      final entry = WordEntry.create(
        word: text.trim(),
        lang: widget.book.source == BookSource.txt ? 'zh' : 'zh',
        fromBookId: widget.book.id,
      );
      await WordEntryDao(db).upsert(entry);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已加入生词本：${text.trim()}'),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      AppLog.e(_tag, '标记生词失败: $e');
    }
  }

  Future<void> _translate(String text) async {
    if (text.trim().isEmpty) return;
    AppLog.d(_tag, '翻译: "$text"');
    final result = await TranslationEngine.translateWithSettings(text);
    if (!mounted) return;
    if (result != null) {
      showModalBottomSheet(
        context: context,
        backgroundColor: StudyPalette.parchment,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        builder:
            (context) => Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: StudyPalette.emberSoft,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '${_langDisplayName(result.source)} → '
                          '${_langDisplayName(result.target)}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: StudyPalette.ember,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    text,
                    style: const TextStyle(
                      fontSize: 16,
                      color: StudyPalette.ink,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(height: 1, color: StudyPalette.linen),
                  const SizedBox(height: 12),
                  Text(
                    result.text,
                    style: const TextStyle(
                      fontSize: 16,
                      color: StudyPalette.ember,
                      fontWeight: FontWeight.w600,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
      );
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('翻译失败，请检查引擎配置')));
    }
  }

  // ===== 工具 =====

  Future<String> _writeTempPng(List<int> bytes) async {
    final dir = await Directory.systemTemp.createTemp('wm_reader_');
    final f = File('${dir.path}${Platform.pathSeparator}page.png');
    await f.writeAsBytes(bytes, flush: true);
    return f.path;
  }

  // ===== build =====

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.book.title)),
        body: Center(child: Text('加载失败：$_error')),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.book.title),
        actions: [
          if (_hasOriginal())
            IconButton(
              tooltip: _useOriginal ? '切换文本模式' : '切换原文模式',
              icon: Icon(
                _useOriginal ? Icons.text_fields : Icons.picture_as_pdf,
              ),
              onPressed: _switchingMode ? null : _switchViewMode,
            ),
          if (!_useOriginal)
            IconButton(
              tooltip: '本页知识点',
              icon: const Icon(Icons.lightbulb_outline),
              onPressed: _showPageKnowledge,
            ),
        ],
      ),
      body: IgnorePointer(ignoring: _switchingMode, child: _buildBody()),
    );
  }

  bool _hasOriginal() {
    return widget.book.source == BookSource.pdf ||
        widget.book.source == BookSource.word;
  }

  Widget _buildBody() {
    final source = widget.book.source;
    Widget content;
    if (source == BookSource.pdf && _useOriginal) {
      content = _buildPdfView();
    } else if (source == BookSource.camera || source == BookSource.gallery) {
      content = _buildImageView();
    } else if (source == BookSource.word && _useOriginal) {
      content = _buildWordView();
    } else {
      content = _buildTextView();
    }

    // [v2.11.0] 原文模式：上滑唤出文本弹窗
    if (_useOriginal && _hasOriginal()) {
      content = GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragEnd: (d) {
          if (d.primaryVelocity != null && d.primaryVelocity! < -350) {
            _showTextSheet();
          }
        },
        child: content,
      );
    }
    return content;
  }

  Widget _buildPdfView() {
    final path = widget.book.originalFilePath;
    if (path == null) return const Text('缺少 PDF 文件');
    final viewGeneration = _pdfViewGeneration;
    return PDFView(
      filePath: path,
      enableSwipe: true,
      defaultPage: _isMultiPage ? _pdfCurrentPage : 0,
      onViewCreated: (controller) async {
        if (!mounted || viewGeneration != _pdfViewGeneration) return;
        _pdfController = controller;
        await _syncPageSize(controller, 0, viewGeneration);
      },
      onPageChanged: (page, total) async {
        if (!mounted ||
            viewGeneration != _pdfViewGeneration ||
            !_useOriginal ||
            _switchingMode) {
          return;
        }
        if (page == null) return;
        // 同步共享页码（文本模式/底部面板联动）
        _syncPage(page);
        final c = _pdfController;
        if (c != null) {
          await _syncPageSize(c, page, viewGeneration);
        }
      },
      onTap: (details) {
        final c = _pdfController;
        if (c != null) {
          _onPdfTap(c, details, viewGeneration);
        }
      },
      onError: (e) => AppLog.e(_tag, 'PDFView 错误: $e'),
    );
  }

  Widget _buildImageView() {
    final path = widget.book.originalFilePath;
    if (path == null) return const Text('缺少图片文件');
    return InteractiveViewer(
      transformationController: _imgTransformCtrl,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) => _onImageTap(d),
        child: LayoutBuilder(
          builder: (context, constraints) {
            _imageViewSize = constraints.biggest;
            return Stack(
              children: [
                Positioned.fill(
                  child: Image.file(File(path), fit: BoxFit.contain),
                ),
                // 高亮层（BoxFit.contain 映射，与点击命中同源）
                if (_imgHighlight != null)
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _HighlightPainter(
                        _imgHighlight!.rects,
                        _imageViewSize ?? constraints.biggest,
                        _imagePixelSize,
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  void _onImageTap(TapUpDetails d) {
    if (_imgSentences.isEmpty) return;
    final local = d.localPosition;
    final viewSize = _imageViewSize;
    final imgSize = _imagePixelSize;
    // 用 BoxFit.contain 将点击坐标映射到图片像素坐标再归一化
    if (viewSize == null || imgSize == null || imgSize.isEmpty) {
      // 无图片尺寸信息时直接归一化（回退旧行为，允许不同 widget 尺寸）
      if (viewSize != null) {
        final nx = (local.dx / viewSize.width).clamp(0.0, 1.0);
        final ny = (local.dy / viewSize.height).clamp(0.0, 1.0);
        _hitImage(nx, ny);
      }
      return;
    }
    final scale = math.min(
      viewSize.width / imgSize.width,
      viewSize.height / imgSize.height,
    );
    final dispW = imgSize.width * scale;
    final dispH = imgSize.height * scale;
    final offsetX = (viewSize.width - dispW) / 2;
    final offsetY = (viewSize.height - dispH) / 2;
    // 点击点 → 图片显示区域归一化 [0,1]
    final nx = ((local.dx - offsetX) / dispW).clamp(0.0, 1.0);
    final ny = ((local.dy - offsetY) / dispH).clamp(0.0, 1.0);
    _hitImage(nx, ny);
  }

  void _hitImage(double nx, double ny) {
    final hit = OcrGeometryService.hitSentence(
      _imgSentences,
      ui.Offset(nx, ny),
    );
    if (hit != null) {
      AppLog.d(_tag, '图片命中: ${hit.text}');
      setState(() => _imgHighlight = hit);
      _speak(hit.text);
    } else {
      setState(() => _imgHighlight = null);
    }
  }

  Widget _buildWordView() {
    final path = widget.book.originalFilePath;
    if (path == null) return const Text('缺少 Word 文件');
    final workGeneration = _workGeneration;
    return FutureBuilder<String>(
      future: DocxHtmlConverter.convert(path),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(child: Text('Word 转换失败：${snapshot.error}'));
        }
        // 原文模式点读：converter 注入的脚本点击段落 → 高亮 + postMessage 文本，
        // 经 WiseMuseTap channel 回调朗读（需启用 JS）。
        return WebViewWidget(
          controller:
              WebViewController()
                ..setJavaScriptMode(JavaScriptMode.unrestricted)
                ..addJavaScriptChannel(
                  'WiseMuseTap',
                  onMessageReceived: (m) {
                    if (!_isWorkCurrent(workGeneration) ||
                        !_useOriginal ||
                        _switchingMode) {
                      return;
                    }
                    final text = m.message.trim();
                    if (text.isNotEmpty) _speak(text);
                  },
                )
                ..loadHtmlString(snapshot.data!),
        );
      },
    );
  }

  Widget _buildTextView() {
    // 文本模式：按页分组 + 左右滑翻页 + 句底操作条
    if (_sentences.isEmpty) {
      return const Center(child: Text('暂无句子内容'));
    }
    if (_textPages.isEmpty) {
      return const Center(child: Text('无有效页'));
    }

    final pageSentences = _textPages[_textPageIndex];
    final totalPages = _textPages.length;

    Widget pageContent = Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(children: [const Spacer(), _buildPageBar(totalPages)]),
        ),
        Expanded(child: _buildSwipeableSentenceList(pageSentences)),
      ],
    );

    // [v2.9.0] 多页 → 左右滑翻页，translucent 不拦截子手势
    if (_isMultiPage) {
      pageContent = GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragEnd: _onTextSwipePage,
        child: pageContent,
      );
    }

    return Stack(
      children: [
        pageContent,
        // 浮底查词栏或句操作栏（二者互斥）
        if (_selectedText != null && _selectedText!.isNotEmpty)
          Positioned(left: 8, right: 8, bottom: 8, child: _buildWordLookupBar())
        else if (_activeSentenceText != null && _activeSentenceText!.isNotEmpty)
          Positioned(
            left: 8,
            right: 8,
            bottom: 8,
            child: _buildSentenceActionsBar(),
          ),
      ],
    );
  }

  /// [v2.8.0] 可左右滑翻页的句子列表（多页文件包裹 GestureDetector）。
  /// [v2.9.0] 包裹 SelectionArea 支持长按选词。
  Widget _buildSwipeableSentenceList(List<Sentence> sentences) {
    final content = SelectionArea(
      onSelectionChanged: (selected) {
        final text = selected?.plainText.trim();
        setState(
          () => _selectedText = (text != null && text.isNotEmpty) ? text : null,
        );
      },
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        itemCount: sentences.length,
        separatorBuilder: (_, _) => const SizedBox(height: 6),
        itemBuilder: (context, index) {
          final s = sentences[index];
          final highlighted = _textHighlightIndex == index;
          return Material(
            color:
                highlighted
                    ? StudyPalette.emberSoft
                    : (Theme.of(context).brightness == Brightness.dark
                            ? StudyPalette.darkCard
                            : Colors.white)
                        .withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () {
                setState(() {
                  _textHighlightIndex = index;
                  _activeSentenceIndex = index;
                  _activeSentenceText = s.text;
                });
                _speak(s.text);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                child: Row(
                  children: [
                    // 序号
                    SizedBox(
                      width: 24,
                      child: Text(
                        '${index + 1}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: StudyPalette.inkSoft,
                        ),
                      ),
                    ),
                    // 句子文本
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        child: Text(
                          s.text,
                          style: TextStyle(
                            fontSize: 18,
                            height: 1.6,
                            color:
                                highlighted
                                    ? StudyPalette.ember
                                    : StudyPalette.ink,
                            fontWeight:
                                highlighted ? FontWeight.w600 : FontWeight.w400,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
    return content;
  }

  /// 页导航控件（上一页/页码/下一页）。
  Widget _buildPageBar(int totalPages) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: StudyPalette.parchmentDeep.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left, size: 20),
            onPressed:
                _textPageIndex > 0 ? () => _syncPage(_textPageIndex - 1) : null,
            tooltip: '上一页',
          ),
          Text(
            '${_textPageIndex + 1}/$totalPages',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: StudyPalette.ink,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right, size: 20),
            onPressed:
                _textPageIndex < totalPages - 1
                    ? () => _syncPage(_textPageIndex + 1)
                    : null,
            tooltip: '下一页',
          ),
        ],
      ),
    );
  }

  // ===== 文本模式：自动连读 =====

  Future<void> _startAutoPlay() async {
    if (_autoPlaying) return;
    setState(() => _autoPlaying = true);
    final request = ++_speechRequest;
    try {
      final sentences = _textPages[_textPageIndex];
      for (var i = 0; i < sentences.length && request == _speechRequest; i++) {
        if (!mounted) return;
        setState(() => _textHighlightIndex = i);
        await _tts.speak(sentences[i].text);
        if (request != _speechRequest) return;
        // 句间停顿（读取设置）
        final pauseMs = await SettingsService.instance.getTtsPauseMs();
        if (request != _speechRequest) return;
        await Future.delayed(Duration(milliseconds: pauseMs));
      }
    } finally {
      if (mounted) setState(() => _autoPlaying = false);
    }
  }

  void _stopAutoPlay() {
    _speechRequest++;
    unawaited(_tts.stop());
    if (mounted) setState(() => _autoPlaying = false);
  }

  // ===== 文本模式：本页知识点 =====

  /// [v2.9.0] LRU 缓存 key。
  String _knowledgeCacheKey(String bookId, int page) => '$bookId:$page';

  Future<void> _showPageKnowledge() async {
    final currentPage = _textPages[_textPageIndex];
    if (currentPage.isEmpty) return;
    final page = currentPage.first.page;
    final key = _knowledgeCacheKey(widget.book.id, page);

    // LRU 命中 → 刷新顺序
    if (_knowledgePageCache.containsKey(key)) {
      final cached = _knowledgePageCache.remove(key)!;
      _knowledgePageCache[key] = cached; // 放到末尾（最近使用）
      if (!mounted) return;
      _showKnowledgeSheet(page, cached);
      return;
    }

    final db = await DatabaseProvider.database;
    final dao = KnowledgePointDao(db);
    final points = await dao.getByPage(widget.book.id, page);
    if (!mounted) return;

    // 写入 LRU 缓存，超限淘汰最久未用（队首）
    _knowledgePageCache[key] = points;
    if (_knowledgePageCache.length > _kKnowledgeCacheMax) {
      _knowledgePageCache.remove(_knowledgePageCache.keys.first);
    }

    _showKnowledgeSheet(page, points);
  }

  /// [v2.9.0] 提取的对话框渲染逻辑，被 _showPageKnowledge 与 LRU 缓存共用。
  void _showKnowledgeSheet(int page, List<KnowledgePoint> points) {
    showModalBottomSheet(
      context: context,
      backgroundColor: StudyPalette.parchment,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder:
          (context) => Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
                Text('第 ${page + 1} 页知识点', style: titleStyle(fontSize: 16)),
                const SizedBox(height: 12),
                if (points.isEmpty)
                  const Text(
                    '本页暂无知识点',
                    style: TextStyle(color: StudyPalette.inkSoft),
                  ),
                ...points.map(
                  (p) => ListTile(
                    dense: true,
                    leading: Icon(
                      p.type == KnowledgeType.word
                          ? Icons.text_fields
                          : p.type == KnowledgeType.idiom
                          ? Icons.auto_awesome
                          : p.type == KnowledgeType.english
                          ? Icons.translate
                          : Icons.auto_stories,
                      size: 20,
                      color: StudyPalette.ember,
                    ),
                    title: Text(p.text),
                    subtitle: p.definition != null ? Text(p.definition!) : null,
                    onTap: () => KnowledgeDetailSheet.show(context, p),
                  ),
                ),
              ],
            ),
          ),
    );
  }

  // ===== [v2.8.0] 原文模式：底部文本面板 =====

  /// 可拖拽高度的底部文本面板（原文模式下显示当前页句子列表）。
  /// 复用 _buildTextView 的句子渲染逻辑，独立滚动与刷新。
  Future<void> _showTextSheet() async {
    _sheetRebuild = null;
    if (_sheetScrollController.hasClients) _sheetScrollController.jumpTo(0);
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: StudyPalette.parchment,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder:
          (ctx) => StatefulBuilder(
            builder: (ctx, setSheet) {
              _sheetRebuild = () {
                if (mounted) setSheet(() {});
              };
              final screenH = MediaQuery.of(context).size.height;
              return SizedBox(
                height: screenH * 0.55,
                child: Column(
                  children: [
                    // 顶部拖拽手柄
                    GestureDetector(
                      onVerticalDragUpdate: (d) {
                        setSheet(() {
                          // 高度可调 0.25~0.85
                        });
                      },
                      child: Container(
                        height: 20,
                        alignment: Alignment.center,
                        child: Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: StudyPalette.linen,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                    // 标题行
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.text_fields,
                            size: 16,
                            color: StudyPalette.ink,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '第 ${_pdfCurrentPage + 1} 页',
                            style: titleStyle(fontSize: 14),
                          ),
                          const Spacer(),
                          TextButton.icon(
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 0,
                              ),
                              minimumSize: const Size(0, 0),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            icon: const Icon(
                              Icons.close,
                              size: 16,
                              color: StudyPalette.inkSoft,
                            ),
                            label: const Text(
                              '关闭',
                              style: TextStyle(
                                fontSize: 12,
                                color: StudyPalette.inkSoft,
                              ),
                            ),
                            onPressed: () {
                              _sheetRebuild = null;
                              Navigator.of(ctx).pop();
                            },
                          ),
                        ],
                      ),
                    ),
                    // 页导航栏（原文模式显示播放控制，文本模式显示翻页控制）
                    _buildSheetPageNav(),
                    const Divider(height: 1),
                    // 当前页句子列表
                    Expanded(child: _buildSheetSentences()),
                    // [v2.9.0] 浮底句操作栏（与文本模式一致）
                    if (_activeSentenceText != null &&
                        _activeSentenceText!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                        child: _buildSentenceActionsBar(),
                      ),
                  ],
                ),
              );
            },
          ),
    ).then((_) {
      _sheetRebuild = null;
    });
  }

  /// 文本面板内页导航栏（统一：翻页 + 连读 + 翻译 + 页码选择器）。
  Widget _buildSheetPageNav() {
    final total = _pageTexts.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // 上翻页
          _compactIcon(
            Icons.chevron_left,
            '上一页',
            _pdfCurrentPage > 0 && total > 1
                ? () => _syncPage(_pdfCurrentPage - 1)
                : null,
          ),
          // 页码选择器（弹出全宽页码列表）
          if (total > 1)
            TextButton(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                minimumSize: const Size(0, 0),
                padding: const EdgeInsets.symmetric(horizontal: 6),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: _showPageSelector,
              child: const Icon(
                Icons.grid_view,
                size: 16,
                color: StudyPalette.ink,
              ),
            ),
          Text(
            '${_pdfCurrentPage + 1} / $total',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: StudyPalette.ink,
            ),
          ),
          if (total > 1)
            TextButton(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                minimumSize: const Size(0, 0),
                padding: const EdgeInsets.symmetric(horizontal: 6),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: _showPageSelector,
              child: const Icon(
                Icons.grid_view,
                size: 16,
                color: StudyPalette.ink,
              ),
            ),
          // 下翻页
          _compactIcon(
            Icons.chevron_right,
            '下一页',
            _pdfCurrentPage < total - 1 && total > 1
                ? () => _syncPage(_pdfCurrentPage + 1)
                : null,
          ),
          // [v2.11.0] 连读/停止（替代 AppBar 中的全屏连读按钮）
          if (_isMultiPage)
            _compactIcon(
              _autoPlaying
                  ? Icons.stop_circle_outlined
                  : Icons.play_circle_outline,
              _autoPlaying ? '停止连读' : '连读本页',
              _autoPlaying ? _stopAutoPlay : _startAutoPlay,
            ),
          _compactIcon(
            Icons.translate,
            '翻译当前页',
            () => _translate(_displayText),
          ),
        ],
      ),
    );
  }

  /// [v2.11.0] 全宽页码选择器弹窗：列出所有页码，点击跳转。
  void _showPageSelector() {
    final pages = _pageTexts;
    if (pages.length <= 1) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: false,
      backgroundColor: StudyPalette.parchment,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder:
          (_) => SizedBox(
            height: MediaQuery.of(context).size.height * 0.55,
            child: Column(
              children: [
                Center(
                  child: Container(
                    width: 32,
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
                      Text('选择页码', style: titleStyle(fontSize: 16)),
                      const Spacer(),
                      TextButton.icon(
                        icon: const Icon(Icons.close, size: 16),
                        label: const Text('关闭', style: TextStyle(fontSize: 12)),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: GridView.builder(
                    padding: const EdgeInsets.all(12),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 5,
                          mainAxisSpacing: 8,
                          crossAxisSpacing: 8,
                          childAspectRatio: 1.0,
                        ),
                    itemCount: pages.length,
                    itemBuilder: (ctx, i) {
                      final selected = i == _pdfCurrentPage;
                      return Material(
                        color:
                            selected ? StudyPalette.ember : Colors.transparent,
                        borderRadius: BorderRadius.circular(10),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: () {
                            _syncPage(i);
                            if (_useOriginal && _pdfController != null) {
                              _pdfController!.setPage(i);
                            }
                            Navigator.of(context).pop();
                          },
                          child: Center(
                            child: Text(
                              '${i + 1}',
                              style: TextStyle(
                                color:
                                    selected ? Colors.white : StudyPalette.ink,
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
    );
  }

  /// 文本面板内当前页句子列表（复用 _buildTextView 的句子渲染）。
  /// [v2.9.0] 包裹 SelectionArea 支持长按选词。
  Widget _buildSheetSentences() {
    final pages = _pageTexts;
    if (pages.isEmpty) return const SizedBox();
    final i = _pdfCurrentPage.clamp(0, pages.length - 1);
    if (i >= _textPages.length) return const SizedBox();
    final sentences = _textPages[i];
    return SelectionArea(
      onSelectionChanged: (selected) {
        final text = selected?.plainText.trim();
        setState(
          () => _selectedText = (text != null && text.isNotEmpty) ? text : null,
        );
      },
      child: ListView.separated(
        controller: _sheetScrollController,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: sentences.length,
        separatorBuilder: (_, _) => const Divider(height: 1, indent: 16),
        itemBuilder: (context, index) {
          final s = sentences[index];
          return ListTile(
            dense: true,
            title: Text(
              s.text,
              style: const TextStyle(fontSize: 15, color: StudyPalette.ink),
            ),
            onTap: () {
              _textHighlightIndex = index;
              _activeSentenceIndex = index;
              _activeSentenceText = s.text;
              _sheetRebuild?.call();
              _speak(s.text);
            },
          );
        },
      ), // ListView.separated
    ); // SelectionArea
  }

  /// 紧凑图标按钮（36px 约束，用于文本面板导航）。
  Widget _compactIcon(IconData icon, String tooltip, VoidCallback? onTap) {
    return IconButton(
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      iconSize: 18,
      icon: Icon(icon, color: StudyPalette.ink),
      tooltip: tooltip,
      onPressed: onTap,
    );
  }

  // ===== [v2.9.0] 长按选词查词 =====

  /// 浮底查词栏：选中文字后显示 [查词] / [加入生词本] / [取消]。
  Widget _buildWordLookupBar() {
    final word = _selectedText ?? '';
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(14),
      color: StudyPalette.parchment,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            // 选中文本预览（截断显示）
            Flexible(
              child: Text(
                word.length > 24 ? '${word.substring(0, 24)}…' : word,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: StudyPalette.ink,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            // 查词
            TextButton.icon(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                foregroundColor: StudyPalette.ember,
              ),
              icon: const Icon(Icons.search, size: 18),
              label: const Text('查词', style: TextStyle(fontSize: 13)),
              onPressed: () => _lookupWord(word),
            ),
            // 加入生词本
            TextButton.icon(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                foregroundColor: StudyPalette.ink,
              ),
              icon: const Icon(Icons.bookmark_add_outlined, size: 18),
              label: const Text('加入生词本', style: TextStyle(fontSize: 13)),
              onPressed: () {
                _markWord(word);
                setState(() => _selectedText = null);
              },
            ),
            // 取消
            TextButton(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                foregroundColor: StudyPalette.inkSoft,
                padding: const EdgeInsets.symmetric(horizontal: 6),
              ),
              child: const Text('取消', style: TextStyle(fontSize: 13)),
              onPressed: () => setState(() => _selectedText = null),
            ),
          ],
        ),
      ),
    );
  }

  /// [v2.9.0] 浮底句操作栏：朗读当前句 + 跟读/翻译/标记/AI 讲解。
  Widget _buildSentenceActionsBar() {
    final text = _activeSentenceText ?? '';
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(14),
      color: StudyPalette.parchment,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          children: [
            // [v2.11.0] 朗读/停止合一：播放时显示停止图标，不播放时显示播放图标
            IconButton(
              icon: Icon(
                _ttsSpeaking ? Icons.stop : Icons.play_arrow,
                size: 20,
              ),
              tooltip: _ttsSpeaking ? '停止' : '朗读',
              color: _ttsSpeaking ? StudyPalette.inkSoft : StudyPalette.ember,
              onPressed: () {
                if (_ttsSpeaking) {
                  _speechRequest++;
                  unawaited(_tts.stop());
                } else {
                  if (_activeSentenceIndex != null) {
                    setState(() => _textHighlightIndex = _activeSentenceIndex);
                  }
                  _speak(text);
                }
              },
            ),
            // 跟读
            IconButton(
              icon: const Icon(Icons.record_voice_over_outlined, size: 20),
              tooltip: '跟读此句',
              color: StudyPalette.ember,
              onPressed: () {
                setState(() => _activeSentenceText = null);
                _openFollow(text);
              },
            ),
            // 翻译
            IconButton(
              icon: const Icon(Icons.translate, size: 20),
              tooltip: '翻译',
              color: StudyPalette.inkSoft,
              onPressed: () {
                setState(() => _activeSentenceText = null);
                _translate(text);
              },
            ),
            // 标记生词
            IconButton(
              icon: const Icon(Icons.bookmark_add_outlined, size: 20),
              tooltip: '标记生词',
              color: StudyPalette.inkSoft,
              onPressed: () {
                _markWord(text);
                setState(() => _activeSentenceText = null);
              },
            ),
            // AI 讲解
            IconButton(
              icon: const Icon(Icons.auto_awesome, size: 20),
              tooltip: 'AI 讲解',
              color: StudyPalette.moss,
              onPressed: () {
                setState(() => _activeSentenceText = null);
                KnowledgeExplainSheet.show(context, text);
              },
            ),
            // [v2.10.0] 问AI（RAG 问答）
            IconButton(
              icon: const Icon(Icons.psychology, size: 20),
              tooltip: '问AI',
              color: StudyPalette.spinePdf,
              onPressed: () {
                setState(() => _activeSentenceText = null);
                _askRag(widget.book.id, text);
              },
            ),
            const Spacer(),
            // 关闭
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              tooltip: '关闭',
              color: StudyPalette.inkSoft,
              onPressed: () {
                setState(() => _activeSentenceText = null);
                _sheetRebuild?.call();
              },
            ),
          ],
        ),
      ),
    );
  }

  /// [v2.10.0] RAG 问答：基于教材内容提问。
  Future<void> _askRag(String bookId, String sentenceText) async {
    if (bookId.isEmpty || sentenceText.trim().isEmpty) return;

    // 检测 RAG 是否就绪；未就绪时引导构建
    final ready = await RagQaService.instance.isReady(bookId);
    if (!mounted) return;

    if (!ready) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('该教材尚未构建知识库，请先在书架中构建')));
      return;
    }

    // 弹出问答弹窗
    if (!mounted) return;
    _showRagQaSheet(bookId, sentenceText);
  }

  /// [v2.10.0] RAG 问答弹窗：输入问题 → AI 回答。
  void _showRagQaSheet(String bookId, String sentenceText) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: StudyPalette.parchment,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder:
          (_) =>
              _RagQaSheetContent(bookId: bookId, initialQuestion: sentenceText),
    );
  }

  /// 查词：调翻译引擎获取释义，以 BottomSheet 展示并支持加入生词本。
  Future<void> _lookupWord(String word) async {
    final trimmed = word.trim();
    if (trimmed.isEmpty) return;
    // 收起浮动查词栏
    setState(() => _selectedText = null);

    AppLog.d(_tag, '查词: "$trimmed"');
    // 判断语言方向：含中文字符 zh→en，否则 en→zh
    final hasCjk = RegExp(r'[一-鿿]').hasMatch(trimmed);
    final sourceLang = hasCjk ? 'zh' : 'en';
    final targetLang = hasCjk ? 'en' : 'zh';

    String? trans;
    try {
      trans = await TranslationEngine.translate(
        trimmed,
        source: sourceLang,
        target: targetLang,
      );
    } catch (e) {
      AppLog.e(_tag, '查词翻译失败: $e');
    }

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: StudyPalette.parchment,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder:
          (ctx) => Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 标题行：单词 + 语言方向标签
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        trimmed,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: StudyPalette.ink,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: StudyPalette.emberSoft,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '$sourceLang → $targetLang',
                        style: const TextStyle(
                          fontSize: 11,
                          color: StudyPalette.ember,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // 释义
                if (trans != null && trans.isNotEmpty)
                  Text(
                    trans,
                    style: const TextStyle(
                      fontSize: 18,
                      color: StudyPalette.ember,
                      fontWeight: FontWeight.w600,
                      height: 1.5,
                    ),
                  )
                else
                  const Text(
                    '暂无释义结果',
                    style: TextStyle(fontSize: 16, color: StudyPalette.inkSoft),
                  ),
                const SizedBox(height: 16),
                // 加入生词本
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: StudyPalette.ember,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.bookmark_add, size: 20),
                    label: const Text('加入生词本', style: TextStyle(fontSize: 15)),
                    onPressed: () {
                      _markWord(trimmed);
                      Navigator.of(ctx).pop();
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('已加入生词本：$trimmed'),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
    );
  }

  // ===== 文本模式：跟读入口 =====

  void _openFollow(String text) {
    _speechRequest++;
    unawaited(_tts.stop());
    Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (_) => FollowPage(
              initialSentence: text,
              bookId: widget.book.id,
              bookTitle: widget.book.title,
              pageNumber: _pdfCurrentPage,
            ),
      ),
    );
  }
}

/// 图片模式高亮画笔（归一化坐标 → 像素）。
class _HighlightPainter extends CustomPainter {
  /// [rects] 为归一化 [0,1] 矩形（相对图片像素）；
  /// [viewSize] 为 widget 尺寸，[imgSize] 为图片像素尺寸。
  /// 绘制时按 BoxFit.contain 把归一化矩形映射到图片实际显示区域（与点击命中同源）。
  _HighlightPainter(this.rects, this.viewSize, this.imgSize);

  final List<ui.Rect> rects;
  final ui.Size viewSize;
  final ui.Size? imgSize;

  @override
  void paint(ui.Canvas canvas, ui.Size size) {
    final paint =
        ui.Paint()
          ..color = const ui.Color(0x50FFC800)
          ..style = ui.PaintingStyle.fill;
    // 计算图片显示区域（BoxFit.contain）
    double left = 0, top = 0, dispW = size.width, dispH = size.height;
    if (imgSize != null && !imgSize!.isEmpty && size.isEmpty == false) {
      final scale = math.min(
        size.width / imgSize!.width,
        size.height / imgSize!.height,
      );
      dispW = imgSize!.width * scale;
      dispH = imgSize!.height * scale;
      left = (size.width - dispW) / 2;
      top = (size.height - dispH) / 2;
    }
    for (final r in rects) {
      canvas.drawRect(
        ui.Rect.fromLTRB(
          left + r.left * dispW,
          top + r.top * dispH,
          left + r.right * dispW,
          top + r.bottom * dispH,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_HighlightPainter oldDelegate) =>
      oldDelegate.rects != rects;
}

/// [v2.10.0] RAG 问答弹窗内容：输入问题 → AI 基于教材回答。
///
/// 初始问题默认为当前句子，可修改。Markdown 渲染回答。
class _RagQaSheetContent extends StatefulWidget {
  const _RagQaSheetContent({required this.bookId, this.initialQuestion});

  final String bookId;
  final String? initialQuestion;

  @override
  State<_RagQaSheetContent> createState() => _RagQaSheetContentState();
}

class _RagQaSheetContentState extends State<_RagQaSheetContent> {
  late final TextEditingController _controller;
  String? _answer;
  bool _loading = false;
  bool _asked = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialQuestion ?? '');
    // 有初始问题时自动提问
    if (widget.initialQuestion != null &&
        widget.initialQuestion!.trim().isNotEmpty) {
      _ask();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _ask() async {
    final question = _controller.text.trim();
    if (question.isEmpty) return;

    setState(() {
      _loading = true;
      _answer = null;
      _asked = true;
    });

    final answer = await RagQaService.instance.ask(widget.bookId, question);
    if (mounted) {
      setState(() {
        _answer = answer;
        _loading = false;
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
                    Icons.psychology,
                    size: 20,
                    color: StudyPalette.spinePdf,
                  ),
                  const SizedBox(width: 8),
                  Text('问AI', style: titleStyle(fontSize: 18)),
                  const Spacer(),
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

              // 输入区
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      decoration: const InputDecoration(
                        hintText: '输入关于这篇教材的问题…',
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        border: OutlineInputBorder(),
                      ),
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _ask(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    icon:
                        _loading
                            ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                            : const Icon(Icons.send, size: 18),
                    style: IconButton.styleFrom(
                      backgroundColor: StudyPalette.ember,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: _loading ? null : _ask,
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // 回答区
              Expanded(child: _buildAnswer(scrollController)),
            ],
          ),
        );
      },
    );
  }

  Widget _buildAnswer(ScrollController scrollController) {
    if (_loading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('正在思考…', style: TextStyle(color: StudyPalette.inkSoft)),
          ],
        ),
      );
    }

    if (!_asked) {
      return Center(
        child: Text(
          '输入你想了解的问题，AI 会结合教材内容回答',
          style: TextStyle(color: StudyPalette.inkSoft, fontSize: 14),
          textAlign: TextAlign.center,
        ),
      );
    }

    if (_answer == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.info_outline, size: 40, color: StudyPalette.inkSoft),
            SizedBox(height: 8),
            Text(
              '未能生成回答\n请检查 AI 引擎配置或重试',
              style: TextStyle(color: StudyPalette.inkSoft, fontSize: 14),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      controller: scrollController,
      child: _buildMarkdownContent(_answer!),
    );
  }

  /// 简易 Markdown 渲染（同 KnowledgeExplainSheet）。
  Widget _buildMarkdownContent(String md) {
    final lines = md.split('\n');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children:
          lines.map((line) {
            final t = line.trim();
            if (t.isEmpty) return const SizedBox(height: 8);

            // 标题
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

            // 列表
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
