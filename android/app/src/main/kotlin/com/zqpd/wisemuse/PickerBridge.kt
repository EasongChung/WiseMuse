package com.zqpd.wisemuse

import android.app.Activity
import android.content.ContentResolver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.io.FileOutputStream

/**
 * [v0.2.0] 拍照/相册选取桥（MethodChannel `com.zqpd.wisemuse/picker`）。
 *
 * 不引入 image_picker（其 Android 实现是 Kotlin，属 AGP9 KGP 风险点），
 * 直接走系统 intent：
 * - 相册：`ACTION_GET_CONTENT image/ *` → contentResolver 复制到 app 私有目录；
 * - 拍照：MediaStore insert 得 content:// → `ACTION_IMAGE_CAPTURE EXTRA_OUTPUT`
 *   （系统相机 APP 代拍，**无需 CAMERA 权限**）→ 从该 URI 复制到 app 私有目录。
 *
 * 结果统一返回已复制的**文件路径**（String）；用户取消返回 success(null)。
 *
 * ⚠️ 极端 ROM 若要求 CAMERA 权限：需在此桥请求前加
 * `android.permission.CAMERA` uses-permission + Dart 侧 permission_handler 请求
 * （当前按多数机型无需，暂不加，如遇真机失败再补）。
 */
class PickerBridge : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware,
    PluginRegistry.ActivityResultListener {
    companion object {
        private const val CHANNEL = "com.zqpd.wisemuse/picker"
        private const val TAG = "PickerBridge"
        private const val REQ_PICK = 0x5001
        private const val REQ_CAMERA = 0x5002
    }

    private var channel: MethodChannel? = null
    private var context: Context? = null
    private var activity: Activity? = null
    private var pendingResult: MethodChannel.Result? = null
    private var pendingCameraUri: Uri? = null

    // ===== FlutterPlugin =====

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel?.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
        pendingResult?.let { r -> r.success(null) }
        pendingResult = null
    }

    // ===== ActivityAware =====

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    // ===== MethodChannel =====

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickFromGallery" -> {
                if (pendingResult != null) {
                    result.error("busy", "上一次选取尚未完成", null)
                    return
                }
                val act = activity
                if (act == null) {
                    result.error("not_ready", "Activity 未就绪", null)
                    return
                }
                pendingResult = result
                val intent = Intent(Intent.ACTION_GET_CONTENT).apply {
                    type = "image/*"
                    addCategory(Intent.CATEGORY_OPENABLE)
                }
                try {
                    act.startActivityForResult(intent, REQ_PICK)
                } catch (t: Throwable) {
                    Log.e(TAG, "相册启动失败", t)
                    pendingResult = null
                    result.error("intent_failed", t.message ?: "无法打开相册", null)
                }
            }
            "pickFromCamera" -> {
                if (pendingResult != null) {
                    result.error("busy", "上一次选取尚未完成", null)
                    return
                }
                val act = activity
                val ctx = context
                if (act == null || ctx == null) {
                    result.error("not_ready", "Activity 未就绪", null)
                    return
                }
                pendingResult = result
                try {
                    val uri = createCameraUri(ctx)
                    pendingCameraUri = uri
                    val intent = Intent(MediaStore.ACTION_IMAGE_CAPTURE).apply {
                        putExtra(MediaStore.EXTRA_OUTPUT, uri)
                    }
                    act.startActivityForResult(intent, REQ_CAMERA)
                } catch (t: Throwable) {
                    Log.e(TAG, "相机启动失败", t)
                    pendingResult = null
                    pendingCameraUri = null
                    result.error("intent_failed", t.message ?: "无法打开相机", null)
                }
            }
            else -> result.notImplemented()
        }
    }

    // ===== 系统 intent 结果 =====

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQ_PICK && requestCode != REQ_CAMERA) return false
        val r = pendingResult ?: return false
        pendingResult = null

        if (resultCode != Activity.RESULT_OK) {
            Log.w(TAG, "用户取消选取（code=$resultCode）")
            r.success(null)
            return true
        }

        try {
            when (requestCode) {
                REQ_PICK -> {
                    val uri = data?.data
                    if (uri == null) {
                        r.success(null)
                    } else {
                        r.success(copyToPrivate(uri))
                    }
                }
                REQ_CAMERA -> {
                    val uri = pendingCameraUri
                    if (uri == null) {
                        r.success(null)
                    } else {
                        r.success(copyToPrivate(uri))
                    }
                }
            }
        } catch (t: Throwable) {
            Log.e(TAG, "复制图片失败", t)
            r.error("copy_failed", t.message ?: "复制图片失败", null)
        } finally {
            pendingCameraUri = null
        }
        return true
    }

    // ===== 工具 =====

    /** 拍照前在 MediaStore 占位，返回系统相机写入的 content:// URI。 */
    private fun createCameraUri(ctx: Context): Uri {
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, "wm_${System.currentTimeMillis()}.jpg")
            put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
            put(
                MediaStore.Images.Media.RELATIVE_PATH,
                Environment.DIRECTORY_PICTURES + "/WiseMuse",
            )
        }
        val resolver: ContentResolver = ctx.contentResolver
        return resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("无法创建相机输出 URI")
    }

    /** 把 content:// URI 复制到 app 私有目录（{filesDir}/picker），返回文件路径。 */
    private fun copyToPrivate(uri: Uri): String {
        val ctx = context ?: throw IllegalStateException("Context 未就绪")
        val resolver = ctx.contentResolver
        val dir = File(ctx.filesDir, "picker").apply { mkdirs() }
        val ext = guessExtension(resolver, uri)
        val out = File(dir, "pick_${System.currentTimeMillis()}$ext")

        resolver.openInputStream(uri)?.use { input ->
            FileOutputStream(out).use { output ->
                input.copyTo(output)
            }
        } ?: throw IllegalStateException("无法读取所选图片: $uri")

        if (out.length() <= 0L) {
            out.delete()
            throw IllegalStateException("所选图片为空文件")
        }
        Log.i(TAG, "已复制到 ${out.absolutePath}（${out.length()} 字节）")
        return out.absolutePath
    }

    private fun guessExtension(resolver: ContentResolver, uri: Uri): String {
        return try {
            val mime = resolver.getType(uri) ?: "image/jpeg"
            when {
                mime.contains("png") -> ".png"
                mime.contains("webp") -> ".webp"
                mime.contains("heic") || mime.contains("heif") -> ".heic"
                else -> ".jpg"
            }
        } catch (_: Throwable) {
            ".jpg"
        }
    }
}
