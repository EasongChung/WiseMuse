import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/debug/app_log.dart';
import '../../core/models/book.dart';
import '../../core/models/sentence.dart';
import '../../core/models/word_entry.dart';
import '../../core/settings/settings_service.dart';
import '../../core/storage/book_dao.dart';
import '../../core/storage/database.dart';
import '../../core/storage/seed_data.dart';
import '../../core/storage/sentence_dao.dart';
import '../../core/storage/word_entry_dao.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/pinyin_speech.dart';
import '../../services/book_import_service.dart';
import '../../services/docx_html_converter.dart';
import '../../services/native_tts_service.dart';
import '../../services/ocr_geometry_service.dart';
import '../../services/ocr_service.dart';
import '../../services/pdf_service.dart';
import '../../services/text_position_service.dart';
import '../../services/translation_engine.dart';
import '../../services/rag/rag_qa_service.dart';
import '../../vendor/flutter_pdfview/flutter_pdfview.dart';
import '../assistant/knowledge_explain_sheet.dart';
import '../../widgets/follow_sheet.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../../widgets/top_toast.dart';

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

  int _pdfCurrentPage = 0;
  // [v0.1.63] PDF 原文真实文档页数，独立于文本句子派生的 _pageTexts。
  // 避免 PDF 某页无文本句子时总页数被低估，导致翻页按钮失效。
  int _documentPageCount = 0;
  final ScrollController _sheetScrollController = ScrollController();

  // [v0.1.51] 手势滑动跟踪（基于 Listener, 绕过 SelectionArea / PDFView 手势拦截）
  double? _dragStartDX;
  double? _dragStartDY;
  bool _dragIsHorizontal = false;

  // [v0.1.39] 连续朗读激活状态：从当前句子开始连续朗读本页剩余句子，
  // 激活状态下点击其他句子会打断并从新句子继续连读；点击停止则重置为单句模式。
  bool _continuousPlaying = false;

  // 页面级朗读代次：每次点击、模式切换或 dispose 自增。耗时 PDF/OCR
  // 任务完成后必须校验代次，旧任务不得晚到发声。
  int _speechRequest = 0;
  int _workGeneration = 0;
  bool _switchingMode = false;

  // [v0.1.38] 播放状态追踪：_speakingStartedAt == _speechRequest 时表示 TTS 正在播放。
  int _speakingStartedAt = -1;
  bool get _ttsSpeaking =>
      _speakingStartedAt > 0 && _speakingStartedAt == _speechRequest;

  // [v0.1.35] 文本选区——选中文字后弹出查词栏
  String? _selectedText;

  // [v0.1.35] 当前朗读/选中句索引（用于底栏操作条）
  int? _activeSentenceIndex;
  String? _activeSentenceText;

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
      final rate = await SettingsService.instance.getTtsRate();
      await _tts.setRate(rate);
      final voice = await SettingsService.instance.getTtsVoice();
      if (voice.isNotEmpty) {
        await _tts.setVoice(voice);
      }
      await _loadSentences();
      // [v0.1.48] 恢复上次阅读位置
      final savedPage = widget.book.lastReadPage;
      if (savedPage > 0) {
        _pdfCurrentPage = savedPage;
        _textPageIndex = savedPage;
      }
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
    await BookImportService().rebuildSentencesIfNeeded(widget.book);
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

  // ===== [v0.1.28] 原文/文本分页同步 =====

  /// 当前文档的分页文本列表（多页模式用）。
  List<String> get _pageTexts {
    if (_textPages.isEmpty) return [];
    return _textPages
        .map((page) => page.map((s) => s.text).join('\n'))
        .toList();
  }

  /// 是否多页文档。
  bool get _isMultiPage => _documentPageCount > 1 || _pageTexts.length > 1;

  /// [v0.1.28] 统一翻页同步：更新共享页码、清除旧状态。
  /// 所有翻页操作（PDF onPageChanged / 文本翻页 / 目录跳页）最终调用此函数。
  void _syncPage(int page) {
    final total =
        _documentPageCount > 0 ? _documentPageCount : _pageTexts.length;
    if (total <= 1) return;
    final next = page.clamp(0, total - 1);
    if (next == _pdfCurrentPage) return;
    _speechRequest++;
    _speakingStartedAt = 0;
    unawaited(_tts.stop());
    if (!mounted) return;
    // [v0.1.57] 延迟一帧 setState：让原生 PDFView 的吸附动画完整收尾后再触发
    // Flutter 侧重绘，避免两者竞争造成掉帧（低配机尤甚）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _pdfCurrentPage = next;
        _textPageIndex = next;
        _textHighlightIndex = null;
        _activeSentenceIndex = null;
        _activeSentenceText = null;
        _selectedText = null;
        _imgHighlight = null;
        // 仅清当前页的句子高亮缓存（几何缓存按页码 key，翻回不应重提，保留）。
        _pdfSentenceCache.remove(_pdfCurrentPage);
      });
    });
    // [v0.1.48] 保存阅读进度
    DatabaseProvider.database
        .then((db) {
          BookDao(db).updateLastRead(widget.book.id, next);
          widget.book.lastReadPage = next;
        })
        .catchError((_) {});
  }

  /// [v0.1.63] 跳转到指定页：文本模式走 _syncPage，PDF 原文额外驱动原生控件。
  void _goToPage(int page) {
    final total =
        _documentPageCount > 0 ? _documentPageCount : _pageTexts.length;
    if (total <= 1) return;
    final next = page.clamp(0, total - 1);
    if (_useOriginal && _pdfController != null) {
      _pdfController!.setPage(next);
    }
    _syncPage(next);
  }

  /// 文本模式翻页（+/- 翻页）。
  void _changePage(int delta) {
    final total =
        _documentPageCount > 0 ? _documentPageCount : _pageTexts.length;
    if (total <= 1) return;
    _syncPage(_pdfCurrentPage + delta);
  }

  // [v0.1.51] 基于 Listener 的水平滑动翻页 —— 绕过 SelectionArea / PDFView 的手势拦截
  // Listener 在手势竞技场之外直接接收原始指针事件, 所以即使 SelectionArea
  // 的 SelectableRegion 拦截了水平拖动, 这里仍能收到 onPointerMove。

  /// 记录拖动起点
  void _onDragStart(PointerDownEvent e) {
    _dragStartDX = e.localPosition.dx;
    _dragStartDY = e.localPosition.dy;
    _dragIsHorizontal = false;
  }

  /// 判定拖动方向（仅水平优先才进入翻页流程）
  void _onDragMove(PointerMoveEvent e) {
    if (_dragIsHorizontal || _dragStartDX == null || _dragStartDY == null) {
      return;
    }
    final dx = (e.localPosition.dx - _dragStartDX!).abs();
    final dy = (e.localPosition.dy - _dragStartDY!).abs();
    // 水平位移需超过竖向 1.5 倍且 > 24px 才认定为水平滑
    if (dx > dy * 1.5 && dx > 24) {
      _dragIsHorizontal = true;
    }
  }

  /// 拖动结束 → 判定是否翻页
  void _onDragEnd(PointerUpEvent e) {
    _trySwipePage(e.localPosition.dx);
    _resetDragState();
  }

  void _onDragCancel(PointerCancelEvent e) {
    _resetDragState();
  }

  void _resetDragState() {
    _dragStartDX = null;
    _dragStartDY = null;
    _dragIsHorizontal = false;
  }

  /// 位移阈值 |dx| > 80px 才翻页（过滤轻微动作）
  void _trySwipePage(double endX) {
    if (!_isMultiPage || _dragStartDX == null || !_dragIsHorizontal) return;
    final delta = endX - _dragStartDX!;
    if (delta.abs() < 80) return;
    // delta < 0 → 左滑（手指向左）→ 下一页
    // delta > 0 → 右滑（手指向右）→ 上一页
    _changePage(delta < 0 ? 1 : -1);
  }

  // ===== PDF =====

  Future<void> _initPdf() async {
    final path = widget.book.originalFilePath;
    if (path == null) throw Exception('缺少 PDF 原文件');
    // [v0.1.63] 取真实文档页数，供翻页栏与目录跳页使用。
    final count = await PdfService().getPageCount(path) ?? 0;
    if (mounted) {
      setState(() => _documentPageCount = count);
    }
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
    } catch (e, s) {
      if (mounted && viewGeneration == _pdfViewGeneration) {
        AppLog.e(_tag, 'syncPageSize($page) 失败: $e\n$s');
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

  /// [v0.1.57] 异步预取当前页前后各一页的几何（仅几何，不进句子缓存）。
  ///
  /// 低配机上 PDFBox 逐字符提取坐标耗时可观；提前把相邻页的 CropBox 尺寸
  /// 填入 `_pageGeomCache`，用户翻回或连续翻页时 `setPageSize` 无需等待。
  /// 仅预取几何（不走 OCR/句子合成），避免把内存撑大。
  Future<void> _preloadAdjacentPages(String path, int page) async {
    final total = _pageTexts.length;
    for (final adj in [page - 1, page + 1]) {
      if (adj < 0 || adj >= total) continue;
      if (_pageGeomCache.containsKey(adj)) continue; // 已有则跳过
      try {
        await _getPageGeom(path, adj);
      } catch (_) {
        // 预取失败不影响主流程，静默忽略
      }
    }
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
          if (mounted) {
            setState(() {
              _activeSentenceText = hit.text;
              _activeSentenceIndex = null;
            });
          }
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
    final sw = Stopwatch()..start();
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
        final blocks = result.blocks;
        final sentences = OcrGeometryService.buildSentences(
          blocks,
          imageWidth: w,
          imageHeight: h,
        );
        sw.stop();
        AppLog.d(
          _tag,
          '扫描件 OCR($page) ${sw.elapsedMilliseconds}ms '
          '${blocks.length}blocks→${sentences.length}sentences',
        );
        return sentences;
      } finally {
        try {
          await File(tmp).delete();
        } catch (_) {}
      }
    } catch (e, s) {
      sw.stop();
      if (_isWorkCurrent(workGeneration)) {
        AppLog.e(_tag, '扫描件 OCR($page) ${sw.elapsedMilliseconds}ms 失败: $e\n$s');
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
    await _speakRequest(_preparePinyin(text), request);
  }

  /// [v0.1.63] 朗读前把句首孤立的拼音字母转为中文谐音字，TTS 走中文发音。
  /// 仅对内置书生效，句子显示不变（如「b：双唇不送气清塞音。」朗读为「玻：…」）。
  String _preparePinyin(String text) {
    final enabled = widget.book.id == SeedData.builtinBookId;
    return PinyinSpeech.transform(text, enabled: enabled);
  }

  Future<void> _speakRequest(String text, int request) async {
    if (text.trim().isEmpty || !_isSpeechRequestCurrent(request)) return;
    _speakingStartedAt = request;
    if (mounted) setState(() {});
    try {
      final repeatCount = await SettingsService.instance.getTtsRepeatCount();
      final count = repeatCount.clamp(1, 5);
      for (var i = 0; i < count; i++) {
        if (!_isSpeechRequestCurrent(request)) break;
        AppLog.d(_tag, '朗读 (${i + 1}/$count): "$text"');
        final ok = await _tts.speak(text);
        if (!ok && _isSpeechRequestCurrent(request)) {
          AppLog.w(_tag, 'TTS speak 未完成: "$text"');
          break;
        }
        if (i < count - 1 && _isSpeechRequestCurrent(request)) {
          await Future.delayed(const Duration(milliseconds: 400));
        }
      }
    } finally {
      if (_isSpeechRequestCurrent(request)) {
        _speakingStartedAt = 0;
        if (mounted) setState(() {});
      }
    }
  }

  Future<void> _switchViewMode() async {
    if (_switchingMode) return;
    _speechRequest++;
    _speakingStartedAt = 0;
    _workGeneration++;
    _pdfOcrInFlight.clear();
    setState(() => _switchingMode = true);

    final stopped = await _tts.stop();
    if (!mounted) return;
    if (!stopped) {
      setState(() => _switchingMode = false);
      TopToast.show(context, '无法停止朗读，请稍后重试');
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
      TopToast.show(context, '已加入生词本：${text.trim()}');
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
      final isDark = Theme.of(context).brightness == Brightness.dark;
      showModalBottomSheet(
        context: context,
        backgroundColor:
            isDark ? StudyPalette.darkCard : StudyPalette.parchment,
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
                    style: TextStyle(
                      fontSize: 16,
                      color: StudyPalette.onSurfaceResolved(context),
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
      TopToast.show(context, '翻译失败，请检查引擎配置');
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
          if (_hasOriginal()) ...[
            IconButton(
              tooltip: '本页文本列表',
              icon: const Icon(Icons.format_list_bulleted),
              onPressed: _showTextSheet,
            ),
            IconButton(
              tooltip: _useOriginal ? '切换文本模式' : '切换原文模式',
              icon: Icon(
                _useOriginal ? Icons.text_fields : Icons.picture_as_pdf,
              ),
              onPressed: _switchingMode ? null : _switchViewMode,
            ),
          ],
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

    // [v0.1.51] 纯文本模式下仅保留点击清空高亮；左右滑翻页由
    // _buildSwipeableSentenceList 内部的 Listener 接管（绕过 SelectionArea 手势拦截）。
    // 原文模式下不监听，避免破坏 PDFView 与双指缩放手势；左右滑翻页由 _buildPdfView
    // 内部的 Listener + PDFView 原生 enableSwipe 双重保障。
    if (!_useOriginal) {
      content = GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () {
          if (_activeSentenceText != null) {
            setState(() => _activeSentenceText = null);
          }
        },
        child: content,
      );
    }

    // [v0.1.53] 句操作栏固定底部：不再点击句子弹出，始终显示在底部，不会遮挡阅读窗口。
    final bool hasLookup = _selectedText != null && _selectedText!.isNotEmpty;

    return Column(
      children: [
        // 1. 顶部固定页码控制栏（多页文件常驻，不遮挡阅读页面）
        if (_isMultiPage)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
            child: _buildTopPageBar(),
          ),

        // 2. 主阅读内容视窗（自动撑满剩余区域）
        Expanded(child: content),

        // 3. 底部固定句操作控制栏（始终显示，缩减主视窗而不是悬浮遮挡）
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
          child: hasLookup ? _buildWordLookupBar() : _buildSentenceActionsBar(),
        ),
      ],
    );
  }

  Widget _buildPdfView() {
    final path = widget.book.originalFilePath;
    if (path == null) return const Text('缺少 PDF 文件');
    final viewGeneration = _pdfViewGeneration;
    // 原生 PDFView 自带顺畅的惯性抛掷、吸附与手势翻页动画 (enableSwipe/pageSnap/pageFling)，
    // 翻页由 Android 原生控件接管并通过 onPageChanged 回调同步页码与尺寸，避免外层手势竞争造成卡顿。
    return PDFView(
      filePath: path,
      enableSwipe: true,
      swipeHorizontal: true,
      pageSnap: true,
      pageFling: true,
      defaultPage: _isMultiPage ? _pdfCurrentPage : 0,
      onViewCreated: (controller) async {
        if (!mounted || viewGeneration != _pdfViewGeneration) return;
        _pdfController = controller;
        await _syncPageSize(controller, _pdfCurrentPage, viewGeneration);
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
          // [v0.1.57] 去掉 await：不阻塞 onPageChanged 回调，让原生吸附动画
          // 完整收尾。CropBox 尺寸异步到位即可，点击命中不依赖它立即返回。
          unawaited(_syncPageSize(c, page, viewGeneration));
          // [v0.1.57] 预取相邻页几何，降低翻回/连续翻页时 setPageSize 的首访延迟。
          unawaited(_preloadAdjacentPages(path, page));
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
      minScale: 0.8,
      maxScale: 5.0,
      panEnabled: true,
      scaleEnabled: true,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
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
      setState(() {
        _imgHighlight = hit;
        _activeSentenceText = hit.text;
        _activeSentenceIndex = null;
      });
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
                    if (text.isNotEmpty) {
                      if (mounted) {
                        setState(() => _activeSentenceText = text);
                      }
                      _speak(text);
                    }
                  },
                )
                ..loadHtmlString(snapshot.data!),
        );
      },
    );
  }

  Widget _buildTextView() {
    // 文本模式：按页分组，通过底部全宽弹窗统一查看页码与控制连读
    if (_sentences.isEmpty) {
      return const Center(child: Text('暂无句子内容'));
    }
    if (_textPages.isEmpty) {
      return const Center(child: Text('无有效页'));
    }

    final pageSentences = _textPages[_textPageIndex];
    return _buildSwipeableSentenceList(pageSentences);
  }

  /// [v0.1.28] 可左右滑翻页的句子列表。
  /// [v0.1.35] 包裹 SelectionArea 支持长按选词。
  /// [v0.1.51] 包裹 Listener 检测水平滑动翻页 —— 绕过 SelectionArea 的
  /// SelectableRegion 手势拦截, Listener 在手势竞技场之外直接收原始指针事件。
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
                if (_continuousPlaying) {
                  _startContinuousPlayFrom(index);
                } else {
                  _speak(s.text);
                }
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
                                    : StudyPalette.onSurfaceResolved(context),
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
    // [v0.1.51] 多页文件时包裹 Listener 检测水平滑动翻页
    if (_isMultiPage) {
      return Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _onDragStart,
        onPointerMove: _onDragMove,
        onPointerUp: _onDragEnd,
        onPointerCancel: _onDragCancel,
        child: content,
      );
    }
    return content;
  }

  // ===== 文本模式：自动连读 / 连续朗读 =====

  /// 从指定句子索引开始连续朗读本页剩余句子。
  Future<void> _startContinuousPlayFrom(int startIndex) async {
    _continuousPlaying = true;
    final request = ++_speechRequest;
    _speakingStartedAt = request;
    if (mounted) setState(() {});

    try {
      final sentences =
          _textPages.isNotEmpty
              ? _textPages[_textPageIndex.clamp(0, _textPages.length - 1)]
              : _sentences;
      final start = startIndex.clamp(0, sentences.length - 1);

      for (var i = start; i < sentences.length; i++) {
        if (!_isSpeechRequestCurrent(request)) break;
        if (!mounted) return;

        final currentSentence = sentences[i];

        setState(() {
          _textHighlightIndex = i;
          _activeSentenceIndex = i;
          _activeSentenceText = currentSentence.text;
        });

        // [v0.1.48] 连续朗读时同步高亮：如果是 PDF 视图下发原生高亮，如果是图片视图高亮几何
        if (_useOriginal &&
            widget.book.source == BookSource.pdf &&
            _pdfController != null) {
          final c = _pdfController!;
          final geom = await _getPageGeom(
            widget.book.originalFilePath ?? '',
            _pdfCurrentPage,
          );
          if (geom != null && geom.chars.isNotEmpty) {
            final pdfSentences = _pdfSentenceCache.putIfAbsent(
              _pdfCurrentPage,
              () {
                return buildSentences(geom.chars);
              },
            );
            final matched =
                pdfSentences
                    .where(
                      (s) =>
                          s.text.contains(currentSentence.text) ||
                          currentSentence.text.contains(s.text),
                    )
                    .firstOrNull;
            if (matched != null) {
              await c.setHighlights(_pdfCurrentPage, matched.rects);
            }
          }
        } else if (_useOriginal &&
            (widget.book.source == BookSource.camera ||
                widget.book.source == BookSource.gallery)) {
          final matched =
              _imgSentences
                  .where(
                    (s) =>
                        s.text.contains(currentSentence.text) ||
                        currentSentence.text.contains(s.text),
                  )
                  .firstOrNull;
          if (matched != null) {
            setState(() => _imgHighlight = matched);
          }
        }

        AppLog.d(
          _tag,
          '连读句子 ($i/${sentences.length}): "${currentSentence.text}"',
        );
        final ok = await _tts.speak(_preparePinyin(currentSentence.text));
        if (!ok && _isSpeechRequestCurrent(request)) {
          AppLog.w(_tag, '连读 TTS 未完成: "${currentSentence.text}"');
          break;
        }

        if (!_isSpeechRequestCurrent(request)) break;

        // 句间停顿（读取设置）
        final pauseMs = await SettingsService.instance.getTtsPauseMs();
        if (!_isSpeechRequestCurrent(request)) break;
        await Future.delayed(Duration(milliseconds: pauseMs));
      }
    } finally {
      if (_isSpeechRequestCurrent(request)) {
        _speakingStartedAt = 0;
        if (mounted) {
          setState(() {
            _continuousPlaying = false;
          });
        }
      }
    }
  }

  void _stopAutoPlay() {
    _continuousPlaying = false;
    _speechRequest++;
    _speakingStartedAt = 0;
    unawaited(_tts.stop());
    if (mounted) setState(() {});
  }

  // ===== 文本模式：本页知识点 =====

  // ===== [v0.1.28] 原文模式：底部文本面板 =====

  /// 可拖拽高度的底部文本面板（原文模式下显示当前页句子列表）。
  /// 复用 _buildTextView 的句子渲染逻辑，独立滚动与刷新。
  Future<void> _showTextSheet() async {
    if (_sheetScrollController.hasClients) _sheetScrollController.jumpTo(0);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: isDark ? StudyPalette.darkCard : StudyPalette.parchment,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder:
          (ctx) => StatefulBuilder(
            builder: (ctx, setSheet) {
              final screenH = MediaQuery.of(context).size.height;
              return SizedBox(
                height: screenH * 0.6,
                child: Column(
                  children: [
                    // 顶部拖拽手柄
                    Container(
                      height: 20,
                      alignment: Alignment.center,
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color:
                              isDark
                                  ? StudyPalette.darkBorder
                                  : StudyPalette.linen,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    // 标题行
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 12, 0),
                      child: Row(
                        children: [
                          Icon(
                            Icons.text_fields,
                            size: 18,
                            color: StudyPalette.onSurfaceResolved(context),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '第 ${_pdfCurrentPage + 1} 页文本',
                            style: titleStyle(fontSize: 15),
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
                            icon: Icon(
                              Icons.close,
                              size: 16,
                              color:
                                  isDark
                                      ? StudyPalette.darkInkSoft
                                      : StudyPalette.inkSoft,
                            ),
                            label: Text(
                              '关闭',
                              style: TextStyle(
                                fontSize: 12,
                                color:
                                    isDark
                                        ? StudyPalette.darkInkSoft
                                        : StudyPalette.inkSoft,
                              ),
                            ),
                            onPressed: () => Navigator.of(ctx).pop(),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    // 当前页句子列表
                    Expanded(child: _buildSheetSentences()),
                  ],
                ),
              );
            },
          ),
    );
  }

  /// 文本面板内当前页句子列表（复用 _buildTextView 的句子渲染）。
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
          final highlighted = _textHighlightIndex == index;
          return ListTile(
            dense: true,
            tileColor:
                highlighted
                    ? StudyPalette.emberSoft.withValues(alpha: 0.5)
                    : null,
            title: Text(
              s.text,
              style: TextStyle(
                fontSize: 15,
                color:
                    highlighted
                        ? StudyPalette.ember
                        : StudyPalette.onSurfaceResolved(context),
                fontWeight: highlighted ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
            onTap: () {
              setState(() {
                _textHighlightIndex = index;
                _activeSentenceIndex = index;
                _activeSentenceText = s.text;
              });
              if (_continuousPlaying) {
                _startContinuousPlayFrom(index);
              } else {
                _speak(s.text);
              }
            },
          );
        },
      ),
    );
  }

  // ===== [v0.1.35] 顶部独立页码控制栏 =====

  /// [v0.1.35] 顶部独立页码控制栏（多页文件显示，仅包含 上一页 / 页码选择 / 下一页，无朗读与翻译按键）。
  Widget _buildTopPageBar() {
    final total =
        _documentPageCount > 0 ? _documentPageCount : _pageTexts.length;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(14),
      color: isDark ? StudyPalette.darkCard : StudyPalette.parchment,
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isDark ? StudyPalette.darkBorder : StudyPalette.linen,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 上一页
            _compactIcon(
              Icons.chevron_left,
              '上一页',
              _pdfCurrentPage > 0 && total > 1
                  ? () => _goToPage(_pdfCurrentPage - 1)
                  : null,
            ),
            const SizedBox(width: 8),
            // 页码文字（点击弹出全宽选择器）
            TextButton(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                minimumSize: const Size(0, 0),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: total > 1 ? _showPageSelector : null,
              child: Text(
                '第 ${_pdfCurrentPage + 1} / $total 页',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: StudyPalette.onSurfaceResolved(context),
                ),
              ),
            ),
            const SizedBox(width: 8),
            // 下一页
            _compactIcon(
              Icons.chevron_right,
              '下一页',
              _pdfCurrentPage < total - 1 && total > 1
                  ? () => _goToPage(_pdfCurrentPage + 1)
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  /// [v0.1.38] 目录弹窗：顶部居中放页码输入框 + 跳转按钮，下方显示目录项。
  /// 文本模式或 PDF 原文都使用同一入口；总页数优先用真实文档页数（PDF），
  /// 否则回退到文本句子页数。
  void _showPageSelector() {
    final pages = _pageTexts;
    final total = _documentPageCount > 0 ? _documentPageCount : pages.length;
    if (total <= 1) return;
    final controller = TextEditingController(
      text: (_pdfCurrentPage + 1).toString(),
    );
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: isDark ? StudyPalette.darkCard : StudyPalette.parchment,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.6,
            child: StatefulBuilder(
              builder: (ctx, setStateSheet) {
                String? errorText;
                void jump() {
                  final raw = controller.text.trim();
                  final n = int.tryParse(raw);
                  if (n == null || n < 1 || n > total) {
                    setStateSheet(() => errorText = '请输入 1~$total 之间的页码');
                    return;
                  }
                  _goToPage(n - 1);
                  Navigator.of(ctx).pop();
                }

                final entries = _buildDirectoryEntries(pages);
                return Column(
                  children: [
                    Center(
                      child: Container(
                        width: 32,
                        height: 4,
                        margin: const EdgeInsets.only(top: 12, bottom: 8),
                        decoration: BoxDecoration(
                          color:
                              isDark
                                  ? StudyPalette.darkBorder
                                  : StudyPalette.linen,
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
                          Text('目录', style: titleStyle(fontSize: 16)),
                          const Spacer(),
                          TextButton.icon(
                            icon: Icon(
                              Icons.close,
                              size: 16,
                              color:
                                  isDark
                                      ? StudyPalette.darkInkSoft
                                      : StudyPalette.inkSoft,
                            ),
                            label: Text(
                              '关闭',
                              style: TextStyle(
                                fontSize: 12,
                                color:
                                    isDark
                                        ? StudyPalette.darkInkSoft
                                        : StudyPalette.inkSoft,
                              ),
                            ),
                            onPressed: () => Navigator.of(ctx).pop(),
                          ),
                        ],
                      ),
                    ),
                    // 顶部居中：页码输入框 + 跳转按钮
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      child: Row(
                        children: [
                          Text(
                            '第',
                            style: TextStyle(
                              fontSize: 14,
                              color: StudyPalette.onSurfaceResolved(ctx),
                            ),
                          ),
                          const SizedBox(width: 6),
                          SizedBox(
                            width: 72,
                            child: TextField(
                              controller: controller,
                              keyboardType: TextInputType.number,
                              textAlign: TextAlign.center,
                              decoration: InputDecoration(
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 8,
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                errorText: errorText,
                              ),
                              onSubmitted: (_) => jump(),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '页 / 共 $total 页',
                            style: TextStyle(
                              fontSize: 14,
                              color: StudyPalette.onSurfaceResolved(ctx),
                            ),
                          ),
                          const Spacer(),
                          FilledButton.icon(
                            icon: const Icon(Icons.swap_vert, size: 16),
                            label: const Text('跳转'),
                            onPressed: jump,
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child:
                          entries.isEmpty
                              ? GridView.builder(
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
                                        selected
                                            ? StudyPalette.ember
                                            : Colors.transparent,
                                    borderRadius: BorderRadius.circular(10),
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(10),
                                      onTap: () {
                                        _goToPage(i);
                                        Navigator.of(ctx).pop();
                                      },
                                      child: Center(
                                        child: Text(
                                          '${i + 1}',
                                          style: TextStyle(
                                            color:
                                                selected
                                                    ? Colors.white
                                                    : StudyPalette.onSurfaceResolved(
                                                      ctx,
                                                    ),
                                            fontSize: 18,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              )
                              : ListView.separated(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 8,
                                ),
                                itemCount: entries.length,
                                separatorBuilder:
                                    (_, _) =>
                                        const Divider(height: 1, indent: 16),
                                itemBuilder: (ctx, i) {
                                  final entry = entries[i];
                                  return ListTile(
                                    leading: CircleAvatar(
                                      radius: 14,
                                      backgroundColor:
                                          entry.page == _pdfCurrentPage
                                              ? StudyPalette.ember
                                              : StudyPalette.parchmentDeep,
                                      child: Text(
                                        '${entry.page + 1}',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color:
                                              entry.page == _pdfCurrentPage
                                                  ? Colors.white
                                                  : StudyPalette.inkSoft,
                                        ),
                                      ),
                                    ),
                                    title: Text(
                                      entry.title,
                                      style: TextStyle(
                                        fontSize: 14,
                                        color: StudyPalette.onSurfaceResolved(
                                          ctx,
                                        ),
                                      ),
                                    ),
                                    onTap: () {
                                      _goToPage(entry.page);
                                      Navigator.of(ctx).pop();
                                    },
                                  );
                                },
                              ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  /// 构建目录项：取每页第一条非空文本作为标题。
  List<({int page, String title})> _buildDirectoryEntries(List<String> pages) {
    final entries = <({int page, String title})>[];
    for (var i = 0; i < pages.length; i++) {
      final first = pages[i]
          .split('\n')
          .map((line) => line.trim())
          .firstWhere((line) => line.isNotEmpty, orElse: () => '');
      if (first.isEmpty) continue;
      // 跳过内置书目录页自身，避免点击跳到目录页造成循环。
      if (first == '目录。') continue;
      entries.add((page: i, title: first));
    }
    return entries;
  }

  // ===== [v0.1.35] 紧凑图标按钮 =====

  /// 紧凑图标按钮（36px 约束，用于文本面板导航）。
  Widget _compactIcon(IconData icon, String tooltip, VoidCallback? onTap) {
    return IconButton(
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      iconSize: 18,
      icon: Icon(icon, color: StudyPalette.onSurfaceResolved(context)),
      tooltip: tooltip,
      onPressed: onTap,
    );
  }

  // ===== [v0.1.35] 长按选词查词 =====

  /// 浮底查词栏：选中文字后显示 [查词] / [加入生词本] / [取消]。
  Widget _buildWordLookupBar() {
    final word = _selectedText ?? '';
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(14),
      color: isDark ? StudyPalette.darkCard : StudyPalette.parchment,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            // 选中文本预览（截断显示）
            Flexible(
              child: Text(
                word.length > 24 ? '${word.substring(0, 24)}…' : word,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: StudyPalette.onSurfaceResolved(context),
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
                foregroundColor: StudyPalette.onSurfaceResolved(context),
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

  /// [v0.1.39] 句操作栏子按钮（垂直 图标 + 文字 结构，均匀分布）。
  Widget _sentenceActionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: color,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// [v0.1.35] 浮底句操作栏：6 按钮均匀栅格（连读/停止、跟读、翻译、生词、讲解、问AI）。
  /// [v0.1.53] 底部固定句操作栏：始终显示，无需点击句子弹出。
  /// 无选中句子时显示提示文字，按钮保持可用（智启陪读色调）。
  Widget _buildSentenceActionsBar() {
    final text = _activeSentenceText ?? '';
    final hasSentence = text.isNotEmpty;
    final isPlaying = _continuousPlaying || _ttsSpeaking;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(14),
      color: isDark ? StudyPalette.darkCard : StudyPalette.parchment,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Row(
          children: [
            // 1. 连读/暂停
            _sentenceActionButton(
              icon:
                  isPlaying
                      ? Icons.pause_circle_outlined
                      : Icons.play_circle_outline,
              label: isPlaying ? '暂停' : '连读',
              color:
                  isPlaying
                      ? StudyPalette.inkSoft
                      : (hasSentence
                          ? StudyPalette.ember
                          : StudyPalette.inkSoft),
              onTap: () {
                if (isPlaying) {
                  // [v0.1.63] 暂停替代停止；暂停后再点击句子回到单句朗读。
                  _stopAutoPlay();
                  return;
                }
                // [v0.1.63] 无选中句时从第一句开始连读，无需先点句子。
                final idx = _activeSentenceIndex ?? 0;
                _startContinuousPlayFrom(idx);
              },
            ),
            // 2. 跟读
            _sentenceActionButton(
              icon: Icons.record_voice_over_outlined,
              label: '跟读',
              color: hasSentence ? StudyPalette.ember : StudyPalette.inkSoft,
              onTap: () {
                if (!hasSentence) return;
                setState(() => _activeSentenceText = null);
                _openFollow(text);
              },
            ),
            // 3. 翻译
            _sentenceActionButton(
              icon: Icons.translate,
              label: '翻译',
              color:
                  hasSentence
                      ? (isDark
                          ? StudyPalette.darkInkSoft
                          : StudyPalette.inkSoft)
                      : StudyPalette.inkSoft.withValues(alpha: 0.4),
              onTap: () {
                if (!hasSentence) return;
                setState(() => _activeSentenceText = null);
                _translate(text);
              },
            ),
            // 4. 生词
            _sentenceActionButton(
              icon: Icons.bookmark_add_outlined,
              label: '生词',
              color:
                  hasSentence
                      ? (isDark
                          ? StudyPalette.darkInkSoft
                          : StudyPalette.inkSoft)
                      : StudyPalette.inkSoft.withValues(alpha: 0.4),
              onTap: () {
                if (!hasSentence) return;
                _markWord(text);
                setState(() => _activeSentenceText = null);
              },
            ),
            // 5. 讲解
            _sentenceActionButton(
              icon: Icons.auto_awesome,
              label: '讲解',
              color: hasSentence ? StudyPalette.moss : StudyPalette.inkSoft,
              onTap: () {
                if (!hasSentence) return;
                setState(() => _activeSentenceText = null);
                KnowledgeExplainSheet.show(context, text);
              },
            ),
            // 6. 问AI
            _sentenceActionButton(
              icon: Icons.psychology,
              label: '问AI',
              color: hasSentence ? StudyPalette.spinePdf : StudyPalette.inkSoft,
              onTap: () {
                if (!hasSentence) return;
                setState(() => _activeSentenceText = null);
                _askRag(widget.book.id, text);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// [v0.1.37] RAG 问答：基于书籍内容提问。
  Future<void> _askRag(String bookId, String sentenceText) async {
    if (bookId.isEmpty || sentenceText.trim().isEmpty) return;

    // 检测 RAG 是否就绪；未就绪时引导构建
    final ready = await RagQaService.instance.isReady(bookId);
    if (!mounted) return;

    if (!ready) {
      TopToast.show(context, '该书籍尚未构建知识库，请先在书架中构建');
      return;
    }

    // 弹出问答弹窗
    if (!mounted) return;
    _showRagQaSheet(bookId, sentenceText);
  }

  /// [v0.1.37] RAG 问答弹窗：输入问题 → AI 回答。
  void _showRagQaSheet(String bookId, String sentenceText) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: isDark ? StudyPalette.darkCard : StudyPalette.parchment,
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

    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? StudyPalette.darkCard : StudyPalette.parchment,
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
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: StudyPalette.onSurfaceResolved(context),
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
                  Text(
                    '暂无释义结果',
                    style: TextStyle(
                      fontSize: 16,
                      color:
                          isDark
                              ? StudyPalette.darkInkSoft
                              : StudyPalette.inkSoft,
                    ),
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
                        TopToast.show(context, '已加入生词本：$trimmed');
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

  /// [v0.1.38] 跟读弹窗：在当前页底部弹出，包含播放→录音→评分流程。
  Future<void> _openFollow(String text) async {
    if (text.trim().isEmpty) return;
    _speechRequest++;
    unawaited(_tts.stop());
    _activeSentenceText = null;

    if (!mounted) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: isDark ? StudyPalette.darkCard : StudyPalette.parchment,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder:
          (_) => FollowSheetContent(
            sentence: text,
            bookId: widget.book.id,
            bookTitle: widget.book.title,
            pageNumber: _pdfCurrentPage,
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

/// [v0.1.37] RAG 问答弹窗内容：输入问题 → AI 基于书籍回答。
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
                        hintText: '输入关于这篇书籍的问题…',
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
          '输入你想了解的问题，AI 会结合书籍内容回答',
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
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: StudyPalette.onSurfaceResolved(context),
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
        style: TextStyle(
          fontSize: 15,
          color: StudyPalette.onSurfaceResolved(context),
          height: 1.6,
        ),
      ),
    );
  }
}
