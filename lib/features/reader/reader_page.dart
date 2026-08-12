import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/debug/app_log.dart';
import '../../core/models/book.dart';
import '../../core/models/sentence.dart';
import '../../core/storage/database.dart';
import '../../core/storage/sentence_dao.dart';
import '../../core/theme/app_theme.dart';
import '../../services/docx_html_converter.dart';
import '../../services/native_tts_service.dart';
import '../../services/ocr_geometry_service.dart';
import '../../services/ocr_service.dart';
import '../../services/pdf_service.dart';
import '../../services/text_position_service.dart';
import '../../services/translation_engine.dart';
import '../../vendor/flutter_pdfview/flutter_pdfview.dart';
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

class _ReaderPageState extends State<ReaderPage> {
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

  // PDFView 控制器（onViewCreated 赋值，供 onTap/onPageChanged 使用）
  PDFViewController? _pdfController;

  // 图片模式
  ui.Size? _imageViewSize;
  ui.Size? _imagePixelSize; // 图片实际像素尺寸（用于点击坐标归一化）
  final TransformationController _imgTransformCtrl = TransformationController();
  List<OcrSentence> _imgSentences = const [];
  OcrSentence? _imgHighlight;

  // 文本模式（TXT / Word 文本视图 / PDF 文本模式共用）：当前朗读句索引（高亮）
  int? _textHighlightIndex;

  @override
  void initState() {
    super.initState();
    _init();
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
    if (mounted) setState(() => _sentences = list);
  }

  // ===== PDF =====

  Future<void> _initPdf() async {
    final path = widget.book.originalFilePath;
    if (path == null) throw Exception('缺少 PDF 原文件');
    await PdfService().getPageCount(path);
  }

  /// onPageChanged / onViewCreated：下发 CropBox 尺寸（G2.5 必需）
  Future<void> _syncPageSize(PDFViewController controller, int page) async {
    try {
      final path = widget.book.originalFilePath;
      if (path == null) return;
      final geom = await _getPageGeom(path, page);
      if (geom != null) {
        await controller.setPageSize(page, geom.pageWidth, geom.pageHeight);
      }
    } catch (e) {
      AppLog.e(_tag, 'syncPageSize($page) 失败: $e');
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
  ) async {
    final path = widget.book.originalFilePath;
    if (path == null) return;
    AppLog.d(_tag, 'PDF 点击 page=${details.page} (${details.x},${details.y})');
    try {
      // 1) 电子版：字符坐标几何
      final geom = await _getPageGeom(path, details.page);
      if (geom != null && geom.chars.isNotEmpty) {
        final sentences = _pdfSentenceCache.putIfAbsent(details.page, () {
          return buildSentences(geom.chars);
        });
        final point = ui.Offset(details.x, details.y);
        final hit = hitSentence(sentences, point, snapEm: 4);
        if (hit != null) {
          AppLog.d(_tag, '命中句子: ${hit.text}');
          await controller.setHighlights(details.page, hit.rects);
          await _tts.speak(hit.text);
          return;
        }
        final paras = buildParagraphs(geom.chars);
        final paraHit = hitParagraph(paras, point, snapEm: 1.5);
        if (paraHit != null) {
          AppLog.d(_tag, '未中句子，命中段落（仅高亮）');
          await controller.setHighlights(details.page, paraHit.rects);
          return;
        }
      }
      // 2) 扫描件：render 图 OCR 几何 → 归一化 × pageSize ≈ PDF 点
      var scanned = _pdfOcrSentenceCache[details.page];
      if (scanned == null) {
        scanned = await _ocrPdfPage(path, details.page);
        _pdfOcrSentenceCache[details.page] = scanned;
      }
      if (scanned.isNotEmpty) {
        // 归一化点击点 → PDF 点
        final nx = details.x / (details.pageWidth > 0 ? details.pageWidth : 1);
        final ny =
            details.y / (details.pageHeight > 0 ? details.pageHeight : 1);
        final hit = OcrGeometryService.hitSentence(
          scanned,
          ui.Offset(nx.clamp(0, 1), ny.clamp(0, 1)),
        );
        if (hit != null) {
          // 归一化 rect → PDF 点 rect
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
          await _tts.speak(hit.text);
          return;
        }
      }
      // 3) 都未中：清高亮
      await controller.clearHighlights();
    } catch (e) {
      AppLog.e(_tag, 'PDF 点击处理失败: $e');
    }
  }

  Future<List<OcrSentence>> _ocrPdfPage(String path, int page) async {
    try {
      final png = await PdfService().renderPage(path, page, scale: 2.0);
      if (png == null) return const [];
      final tmp = await _writeTempPng(png);
      try {
        final result = await OcrService().recognizeFile(tmp);
        if (result == null) return const [];
        // 图片宽高 = render 图尺寸（用块最大坐标近似）
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
      AppLog.e(_tag, '扫描件 OCR($page) 失败: $e');
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
        var w = 1.0;
        var h = 1.0;
        for (final b in result.blocks) {
          if (b.boundingBox.right > w) w = b.boundingBox.right;
          if (b.boundingBox.bottom > h) h = b.boundingBox.bottom;
        }
        _imgSentences = OcrGeometryService.buildSentences(
          result.blocks,
          imageWidth: w,
          imageHeight: h,
        );
      }
    }
  }

  // ===== 朗读 =====

  Future<void> _speak(String text) async {
    AppLog.d(_tag, '朗读: "$text"');
    final ok = await _tts.speak(text);
    if (!ok) AppLog.w(_tag, 'TTS speak 失败: "$text"');
  }

  // ===== 翻译 =====

  Future<void> _translate(String text) async {
    if (text.trim().isEmpty) return;
    AppLog.d(_tag, '翻译: "$text"');
    final result = await TranslationEngine.translate(
      text,
      source: 'zh',
      target: 'en',
    );
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
                    result,
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
                _useOriginal ? Icons.text_fields : Icons.image_outlined,
              ),
              onPressed: () => setState(() => _useOriginal = !_useOriginal),
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  bool _hasOriginal() {
    return widget.book.source == BookSource.pdf ||
        widget.book.source == BookSource.word;
  }

  Widget _buildBody() {
    final source = widget.book.source;
    if (source == BookSource.pdf && _useOriginal) {
      return _buildPdfView();
    }
    if (source == BookSource.camera || source == BookSource.gallery) {
      return _buildImageView();
    }
    if (source == BookSource.word && _useOriginal) {
      return _buildWordView();
    }
    return _buildTextView();
  }

  Widget _buildPdfView() {
    final path = widget.book.originalFilePath;
    if (path == null) return const Text('缺少 PDF 文件');
    return PDFView(
      filePath: path,
      enableSwipe: true,
      onViewCreated: (controller) async {
        _pdfController = controller;
        await _syncPageSize(controller, 0);
      },
      onPageChanged: (page, total) async {
        final c = _pdfController;
        if (c != null && page != null) {
          await _syncPageSize(c, page);
        }
      },
      onTap: (details) {
        final c = _pdfController;
        if (c != null) _onPdfTap(c, details);
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
    // 文本模式：显示全部句子（虚拟分页/页导航为后续增强，当前一次展示）
    if (_sentences.isEmpty) {
      return const Center(child: Text('暂无句子内容'));
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _sentences.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final s = _sentences[index];
        final highlighted = _textHighlightIndex == index;
        return Material(
          color:
              highlighted
                  ? StudyPalette.emberSoft
                  : Colors.white.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () {
              setState(() => _textHighlightIndex = index);
              _speak(s.text);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
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
                  IconButton(
                    icon: const Icon(
                      Icons.translate,
                      size: 20,
                      color: StudyPalette.inkSoft,
                    ),
                    tooltip: '翻译',
                    onPressed: () => _translate(s.text),
                  ),
                ],
              ),
            ),
          ),
        );
      },
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
