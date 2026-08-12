package com.zqpd.wisemuse

import android.net.Uri
import android.util.Log
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.Text
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * [v0.2.0] ML Kit 中文 OCR 桥（MethodChannel `com.zqpd.wisemuse/ocr`）。
 *
 * 用 `com.google.mlkit:text-recognition-chinese` 的 **Bundled** 模型（中文/英文
 * 混排），随 AAR 打包、无 GMS 依赖、离线可用。识别在后台线程执行，不占主线程。
 *
 * 返回结构保留 **block 层**（`block.boundingBox` 作 Dart 侧 `canMergeLines` 的
 * `blockLeft/blockRight`，与 speak_reader OcrGeometryService 同源）：
 * ```
 * {
 *   "text": String,
 *   "blocks": [
 *     { "text": String, "bbox": [l,t,r,b],
 *       "lines": [ { "text": String, "bbox": [l,t,r,b] }, ... ] },
 *     ...
 *   ]
 * }
 * ```
 * bbox 单位为**原图像素**（ML Kit boundingBox 定义）。
 */
class OcrBridge : FlutterPlugin, MethodChannel.MethodCallHandler {
    companion object {
        private const val CHANNEL = "com.zqpd.wisemuse/ocr"
        private const val TAG = "OcrBridge"
    }

    private var channel: MethodChannel? = null
    private var context: android.content.Context? = null
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()

    // Bundled 中文模型懒加载（首调约 1s）
    private val recognizer by lazy {
        TextRecognition.getClient(ChineseTextRecognizerOptions.Builder().build())
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel?.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
        try {
            recognizer.close()
        } catch (_: Throwable) {
        }
        executor.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "recognizeFile" -> {
                val path = call.argument<String>("path")
                if (path.isNullOrEmpty()) {
                    result.error("bad_args", "path 不能为空", null)
                    return
                }
                val ctx = context
                if (ctx == null) {
                    result.error("not_ready", "引擎未附着", null)
                    return
                }
                executor.execute {
                    try {
                        val image = InputImage.fromFilePath(ctx, Uri.fromFile(File(path)))
                        recognizer.process(image)
                            .addOnSuccessListener { r ->
                                Log.i(TAG, "OCR 完成: ${r.text.length} 字")
                                result.success(toMap(r, image))
                            }
                            .addOnFailureListener { e ->
                                Log.e(TAG, "OCR 失败", e)
                                result.error("ocr_failed", e.message ?: "OCR 失败", null)
                            }
                    } catch (t: Throwable) {
                        Log.e(TAG, "OCR 异常", t)
                        result.error("ocr_failed", t.message ?: "OCR 异常", null)
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun toMap(r: Text, image: InputImage): Map<String, Any> {
        val blocks = ArrayList<Map<String, Any>>(r.textBlocks.size)
        for (b in r.textBlocks) {
            val lines = ArrayList<Map<String, Any>>(b.lines.size)
            for (l in b.lines) {
                lines.add(
                    hashMapOf(
                        "text" to l.text,
                        "bbox" to listOf(
                            l.boundingBox?.left ?: 0,
                            l.boundingBox?.top ?: 0,
                            l.boundingBox?.right ?: 0,
                            l.boundingBox?.bottom ?: 0,
                        ),
                    )
                )
            }
            blocks.add(
                hashMapOf(
                    "text" to b.text,
                    "bbox" to listOf(
                        b.boundingBox?.left ?: 0,
                        b.boundingBox?.top ?: 0,
                        b.boundingBox?.right ?: 0,
                        b.boundingBox?.bottom ?: 0,
                    ),
                    "lines" to lines,
                )
            )
        }
        return hashMapOf(
            "text" to r.text,
            "width" to image.width,
            "height" to image.height,
            "blocks" to blocks,
        )
    }
}
