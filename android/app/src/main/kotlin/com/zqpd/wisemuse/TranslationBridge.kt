package com.zqpd.wisemuse

import android.util.Log
import com.google.mlkit.common.model.DownloadConditions
import com.google.mlkit.nl.languageid.LanguageIdentification
import com.google.mlkit.nl.translate.TranslateLanguage
import com.google.mlkit.nl.translate.TranslateRemoteModel
import com.google.mlkit.nl.translate.Translation
import com.google.mlkit.nl.translate.Translator
import com.google.mlkit.nl.translate.TranslatorOptions
import com.google.mlkit.common.model.RemoteModelManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * [v0.3.0] ML Kit 翻译 + 语种识别桥（MethodChannel `com.zqpd.wisemuse/translate`）。
 *
 * 用 standalone SDK（`com.google.mlkit:translate` / `language-id`）：
 * - **翻译模型走 Google CDN 直连下载**（`RemoteModelManager` / `downloadModelIfNeeded`），
 *   不经 Google Play Services —— **无 GMS 机型可用**（与 speak_reader feat/mlkit-offline 同栈）。
 * - 模型 ~30MB/语对，**按需下载**，持久化在 app 存储空间；默认仅 WiFi 下载（可配置）。
 * - 语种识别（`LanguageIdentification`）Bundled 模型随 AAR，无需下载。
 *
 * 方法：
 * - `translate(text, source, target)` → 翻译结果 String（自动下载所需模型）
 * - `isModelDownloaded(lang)` → bool
 * - `downloadModel(lang, {wifiRequired})` → bool（下载成功或已存在）
 * - `deleteModel(lang)` → bool
 * - `identifyLanguage(text)` → BCP-47 语言代码（如 `zh` / `en`），识别失败返回 `und`
 *
 * [lang] 为 BCP-47 代码（`zh`/`en`/`ja`…），经 [TranslateLanguage.fromLanguageTag] 校验。
 * 全分支 `catch(Throwable)` 兜底（ML Kit 缺模型/网络失败统一回落在线）。
 */
class TranslationBridge : FlutterPlugin, MethodChannel.MethodCallHandler {
    companion object {
        private const val CHANNEL = "com.zqpd.wisemuse/translate"
        private const val TAG = "TranslationBridge"
    }

    private var channel: MethodChannel? = null

    // 已缓存翻译器, key = "source-target"（BCP-47）。模型未下载时 getClient 不报错,
    // translate 前统一走 downloadModelIfNeeded, 避免同一语言对反复建 Translator。
    private val translators = HashMap<String, Translator>()

    private val languageIdentifier by lazy {
        LanguageIdentification.getClient()
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel?.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        for (t in translators.values) {
            try {
                t.close()
            } catch (_: Throwable) {
            }
        }
        translators.clear()
        try {
            languageIdentifier.close()
        } catch (_: Throwable) {
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "translate" -> handleTranslate(call, result)
            "isModelDownloaded" -> handleIsModelDownloaded(call, result)
            "downloadModel" -> handleDownloadModel(call, result)
            "deleteModel" -> handleDeleteModel(call, result)
            "identifyLanguage" -> handleIdentifyLanguage(call, result)
            else -> result.notImplemented()
        }
    }

    // ===== translate =====

    private fun handleTranslate(call: MethodCall, result: MethodChannel.Result) {
        val text = call.argument<String>("text")?.trim()
        val source = call.argument<String>("source")
        val target = call.argument<String>("target")
        if (text.isNullOrEmpty() || source.isNullOrEmpty() || target.isNullOrEmpty()) {
            result.error("bad_args", "text/source/target 不能为空", null)
            return
        }
        val srcLang = TranslateLanguage.fromLanguageTag(source)
        val tgtLang = TranslateLanguage.fromLanguageTag(target)
        if (srcLang == null || tgtLang == null) {
            result.error("bad_args", "不支持的语言: $source / $target", null)
            return
        }

        val translator = getOrCreateTranslator(source, target, srcLang, tgtLang)
        val conditions = DownloadConditions.Builder().requireWifi().build()

        // 先确保模型已下载（已存在则 immediately 成功），再翻译。
        translator.downloadModelIfNeeded(conditions)
            .addOnSuccessListener {
                translator.translate(text)
                    .addOnSuccessListener { translated ->
                        Log.i(TAG, "翻译完成: ${translated.length} 字")
                        result.success(translated)
                    }
                    .addOnFailureListener { e ->
                        Log.e(TAG, "翻译失败", e)
                        result.error("translate_failed", e.message ?: "翻译失败", null)
                    }
            }
            .addOnFailureListener { e ->
                Log.e(TAG, "模型下载失败", e)
                result.error("model_download_failed", e.message ?: "模型下载失败", null)
            }
    }

    private fun getOrCreateTranslator(key: String, src: String, tgt: String): Translator {
        val existing = translators[key]
        if (existing != null) return existing
        val options = TranslatorOptions.Builder()
            .setSourceLanguage(src)
            .setTargetLanguage(tgt)
            .build()
        val translator = Translation.getClient(options)
        translators[key] = translator
        return translator
    }

    // ===== 模型管理 =====

    private fun handleIsModelDownloaded(call: MethodCall, result: MethodChannel.Result) {
        val lang = call.argument<String>("lang")
        if (lang.isNullOrEmpty()) {
            result.error("bad_args", "lang 不能为空", null)
            return
        }
        val model = translateRemoteModel(lang)
        if (model == null) {
            result.error("bad_args", "不支持的语言: $lang", null)
            return
        }
        RemoteModelManager.getInstance().isModelDownloaded(model)
            .addOnSuccessListener { ok -> result.success(ok) }
            .addOnFailureListener { e ->
                Log.e(TAG, "isModelDownloaded 失败", e)
                result.error("query_failed", e.message ?: "查询失败", null)
            }
    }

    private fun handleDownloadModel(call: MethodCall, result: MethodChannel.Result) {
        val lang = call.argument<String>("lang")
        if (lang.isNullOrEmpty()) {
            result.error("bad_args", "lang 不能为空", null)
            return
        }
        val model = translateRemoteModel(lang)
        if (model == null) {
            result.error("bad_args", "不支持的语言: $lang", null)
            return
        }
        val wifiOnly = call.argument<Boolean>("wifiRequired") ?: true
        val conditions = DownloadConditions.Builder()
            .apply { if (wifiOnly) requireWifi() }
            .build()
        RemoteModelManager.getInstance().download(model, conditions)
            .addOnSuccessListener { result.success(true) }
            .addOnFailureListener { e ->
                Log.e(TAG, "模型下载失败", e)
                result.error("download_failed", e.message ?: "模型下载失败", null)
            }
    }

    private fun handleDeleteModel(call: MethodCall, result: MethodChannel.Result) {
        val lang = call.argument<String>("lang")
        if (lang.isNullOrEmpty()) {
            result.error("bad_args", "lang 不能为空", null)
            return
        }
        val model = translateRemoteModel(lang)
        if (model == null) {
            result.error("bad_args", "不支持的语言: $lang", null)
            return
        }
        // 清理缓存的翻译器
        translators.entries.removeAll { (k, _) -> k.startsWith("$lang-") }
        RemoteModelManager.getInstance().deleteDownloadedModel(model)
            .addOnSuccessListener { result.success(true) }
            .addOnFailureListener { e ->
                Log.e(TAG, "删除模型失败", e)
                result.error("delete_failed", e.message ?: "删除模型失败", null)
            }
    }

    // ===== 语种识别 =====

    private fun handleIdentifyLanguage(call: MethodCall, result: MethodChannel.Result) {
        val text = call.argument<String>("text")?.trim()
        if (text.isNullOrEmpty()) {
            result.error("bad_args", "text 不能为空", null)
            return
        }
        languageIdentifier.identifyLanguage(text)
            .addOnSuccessListener { lang ->
                Log.i(TAG, "语种识别: $lang")
                result.success(lang)
            }
            .addOnFailureListener { e ->
                Log.e(TAG, "语种识别失败", e)
                result.error("identify_failed", e.message ?: "语种识别失败", null)
            }
    }

    // ===== 工具 =====

    private fun translateRemoteModel(lang: String): TranslateRemoteModel? {
        val tl = TranslateLanguage.fromLanguageTag(lang) ?: return null
        return TranslateRemoteModel.Builder(tl).build()
    }
}
