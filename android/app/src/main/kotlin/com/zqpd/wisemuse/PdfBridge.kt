package com.zqpd.wisemuse

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import android.util.Log
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.text.PDFTextStripper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File

/**
 * [v0.2.0] PDF 解析/渲染桥（MethodChannel `com.zqpd.wisemuse/pdf`）。
 *
 * 三条能力：
 * 1. **文本层**：`extractTexts` 整本逐页纯文本（仅导入时用）；
 * 2. **字符坐标**：`extractTextPositions` 逐页字符框（PDF 点/CropBox 左上角/y 向下，
 *    供点击句朗读的几何合成）；
 * 3. **渲染**：`getPageCount` / `renderPage`（系统 PdfRenderer 出图，扫描件逐页 OCR）。
 *
 * 坐标系与 speak_reader 同源（PDF 点 / CropBox 左上角原点 / y 向下），
 * 见 [CharBoxStripper] 类注释。
 */
class PdfBridge : FlutterPlugin, MethodChannel.MethodCallHandler {
    companion object {
        private const val CHANNEL = "com.zqpd.wisemuse/pdf"
        private const val TAG = "PdfBridge"
    }

    private var channel: MethodChannel? = null
    private var context: android.content.Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        // pdfbox-android 必先 init 字体资源，否则 PDDocument 解析报字体加载失败。
        // 本桥独立承载 PDFBox（未引入 flutter_pdf_text），故在此自行初始化。
        try {
            com.tom_roush.pdfbox.android.PDFBoxResourceLoader.init(context!!)
        } catch (t: Throwable) {
            Log.e(TAG, "PDFBoxResourceLoader.init 失败（后续 PDF 解析可能报字体错误）", t)
        }
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel?.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getPageCount" -> {
                val path = call.argument<String>("path")
                if (path.isNullOrEmpty()) {
                    result.error("bad_args", "path is required", null)
                    return
                }
                try {
                    result.success(pageCount(path))
                } catch (t: Throwable) {
                    Log.e(TAG, "getPageCount 失败", t)
                    result.error("count_failed", t.message ?: "page count failed", null)
                }
            }
            "renderPage" -> {
                val path = call.argument<String>("path")
                val pageIndex = call.argument<Int>("pageIndex") ?: 0
                val scale = call.argument<Double>("scale") ?: 2.0
                if (path.isNullOrEmpty()) {
                    result.error("bad_args", "path is required", null)
                    return
                }
                try {
                    val png = renderPage(path, pageIndex, scale.toFloat())
                    if (png == null) {
                        result.error("no_page", "page index out of range", null)
                    } else {
                        result.success(png)
                    }
                } catch (t: Throwable) {
                    Log.e(TAG, "renderPage 失败", t)
                    result.error("render_failed", t.message ?: "render failed", null)
                }
            }
            "extractTextPositions" -> {
                val path = call.argument<String>("path")
                val pageIndex = call.argument<Int>("pageIndex") ?: 0
                if (path.isNullOrEmpty()) {
                    result.error("bad_args", "path is required", null)
                    return
                }
                try {
                    val data = extractTextPositions(path, pageIndex)
                    if (data == null) {
                        result.error("no_page", "page index out of range", null)
                    } else {
                        result.success(data)
                    }
                } catch (t: Throwable) {
                    Log.e(TAG, "extractTextPositions 失败", t)
                    result.error("extract_failed", t.message ?: "extract failed", null)
                }
            }
            "extractTexts" -> {
                val path = call.argument<String>("path")
                if (path.isNullOrEmpty()) {
                    result.error("bad_args", "path is required", null)
                    return
                }
                try {
                    result.success(extractTexts(path))
                } catch (t: Throwable) {
                    Log.e(TAG, "extractTexts 失败", t)
                    result.error("extract_failed", t.message ?: "extract texts failed", null)
                }
            }
            else -> result.notImplemented()
        }
    }

    /** 系统 PdfRenderer 页数。 */
    private fun pageCount(path: String): Int {
        val file = File(path)
        if (!file.exists()) throw IllegalArgumentException("文件不存在: $path")
        val fd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
        val renderer = PdfRenderer(fd)
        try {
            return renderer.pageCount
        } finally {
            renderer.close()
            fd.close()
        }
    }

    /** 用系统 PdfRenderer 把指定页渲染成 PNG 字节流；页不存在返回 null。 */
    private fun renderPage(path: String, pageIndex: Int, scale: Float): ByteArray? {
        val file = File(path)
        if (!file.exists()) return null
        val fd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
        val renderer = PdfRenderer(fd)
        try {
            if (pageIndex < 0 || pageIndex >= renderer.pageCount) return null
            val page = renderer.openPage(pageIndex)
            try {
                val width = (page.width * scale).toInt().coerceAtLeast(1)
                val height = (page.height * scale).toInt().coerceAtLeast(1)
                val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                // 白底（扫描件/透明背景页统一白底，便于 OCR）
                bitmap.eraseColor(Color.WHITE)
                page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                val out = ByteArrayOutputStream()
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
                bitmap.recycle()
                return out.toByteArray()
            } finally {
                page.close()
            }
        } finally {
            renderer.close()
            fd.close()
        }
    }

    /**
     * 用 PDFBox 提取指定页的字符级坐标 + 页面几何元信息（页不存在返回 null）。
     *
     * 返回结构：
     * ```
     * {
     *   "pageWidth":  Double,  // CropBox 宽（PDF 点）
     *   "pageHeight": Double,  // CropBox 高（PDF 点）
     *   "cropX":      Double,  // CropBox 左下角 x（MediaBox 坐标系）
     *   "cropY":      Double,  // CropBox 左下角 y
     *   "rotation":   Int,     // 页面旋转角（0/90/180/270）
     *   "chars": [{ "c","x","y","w","h","fs","asc","desc" }, ...]
     * }
     * ```
     * 竖直范围以 em 框计（`top = y - 0.88*fs` / `bottom = y + 0.12*fs`），见 CharBox。
     */
    private fun extractTextPositions(path: String, pageIndex: Int): Map<String, Any>? {
        val file = File(path)
        if (!file.exists()) return null
        val doc = PDDocument.load(file)
        try {
            if (pageIndex < 0 || pageIndex >= doc.numberOfPages) return null
            val page = doc.getPage(pageIndex)
            val cropBox = page.cropBox

            val stripper = CharBoxStripper()
            // PDFTextStripper 页号从 1 开始
            stripper.startPage = pageIndex + 1
            stripper.endPage = pageIndex + 1
            stripper.getText(doc) // 触发 writeString 回调收集坐标

            val chars = ArrayList<Map<String, Any>>(stripper.boxes.size)
            for (b in stripper.boxes) {
                chars.add(
                    hashMapOf(
                        "c" to b.ch,
                        "x" to b.x.toDouble(),
                        "y" to b.y.toDouble(),
                        "w" to b.w.toDouble(),
                        "h" to b.h.toDouble(),
                        "fs" to b.fs.toDouble(),
                        "asc" to b.asc.toDouble(),
                        "desc" to b.desc.toDouble(),
                    )
                )
            }
            return hashMapOf(
                "pageWidth" to cropBox.width.toDouble(),
                "pageHeight" to cropBox.height.toDouble(),
                "cropX" to cropBox.lowerLeftX.toDouble(),
                "cropY" to cropBox.lowerLeftY.toDouble(),
                "rotation" to page.rotation,
                "chars" to chars,
            )
        } finally {
            doc.close()
        }
    }

    /** 整本 PDF 逐页纯文本（索引 = 页码 - 1）；单页失败记空串不阻断。 */
    private fun extractTexts(path: String): List<String> {
        val file = File(path)
        if (!file.exists()) throw IllegalArgumentException("文件不存在: $path")
        val doc = PDDocument.load(file)
        try {
            val pages = ArrayList<String>(doc.numberOfPages)
            val stripper = PDFTextStripper()
            for (i in 0 until doc.numberOfPages) {
                try {
                    stripper.startPage = i + 1
                    stripper.endPage = i + 1
                    pages.add(stripper.getText(doc).trim())
                } catch (t: Throwable) {
                    Log.w(TAG, "第 $i 页文本提取失败，记空页", t)
                    pages.add("")
                }
            }
            return pages
        } finally {
            doc.close()
        }
    }
}
