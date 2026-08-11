package com.zqpd.wisemuse

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.lang.reflect.Field
import java.util.Locale
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * [v0.3.0] 系统 TextToSpeech 朗读桥（MethodChannel）。
 *
 * 语义完整对齐 speak_reader 的 flutter_tts（用户授权直接复用其代码；本桥为
 * AGP9 Built-in Kotlin 约束下的等价移植）：
 * 1. **onInit 失败不判死**：status≠SUCCESS 只打日志，不把引擎标为不可用。
 *    可用性由「TextToSpeech service 连接是否绑定」决定（反射读
 *    mServiceConnection），而非 onInit 返回值——真机实测 onInit 可能返回
 *    非 SUCCESS 但连接实际可用，这正是旧实现误报「语音引擎不可用」的根因。
 * 2. **speak 时连接未绑定则自动重建 TextToSpeech 并等待就绪**（flutter_tts
 *    speak():627-630 同款逻辑），永不因 init 状态拒绝朗读。
 * 3. **用 applicationContext 构造引擎**（flutter_tts onAttachedToEngine 同款，
 *    非 Activity context）。
 *
 * 阻塞播放完成通过后台线程 + CountDownLatch 实现，不卡 UI 线程。
 */
class TtsBridge : FlutterPlugin, MethodChannel.MethodCallHandler,
    TextToSpeech.OnInitListener {
    companion object {
        private const val CHANNEL = "com.zqpd.wisemuse/tts"
        private const val TAG = "TtsBridge"
        private const val TIMEOUT_MS = 30000L
        private const val READY_WAIT_MS = 10000L
    }

    private var channel: MethodChannel? = null
    private var context: Context? = null
    private var tts: TextToSpeech? = null
    private val handler = Handler(Looper.getMainLooper())

    // 引擎是否已创建实例（是否至少发起过初始化）
    @Volatile
    private var engineCreated = false

    // 等待引擎 service 连接就绪（onInit 回调后打开）
    @Volatile
    private var readyLatch = CountDownLatch(1)

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel?.setMethodCallHandler(this)
        // 预初始化：进入页面即建引擎，点播放时大概率已就绪（flutter_tts 同款懒加载
        // 也在首次方法调用时创建，此处提前以加速首播）
        createEngine()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
        tts?.stop()
        tts?.shutdown()
        tts = null
    }

    /** 创建/重建 TextToSpeech 引擎（主线程调用）。 */
    private fun createEngine() {
        val ctx = context ?: return
        engineCreated = true
        readyLatch = CountDownLatch(1)
        try {
            tts?.shutdown()
        } catch (_: Throwable) {
        }
        tts = null
        try {
            Log.i(TAG, "创建 TextToSpeech（applicationContext）")
            tts = TextToSpeech(ctx, this)
        } catch (t: Throwable) {
            Log.e(TAG, "TextToSpeech 构造异常", t)
            readyLatch.countDown()
        }
    }

    override fun onInit(status: Int) {
        // flutter_tts 语义：onInit 失败不判死，只打日志。连接可用性由
        // isServiceConnectionUsable() 判定，而非 status。
        if (status == TextToSpeech.SUCCESS) {
            Log.i(TAG, "TTS onInit SUCCESS")
            setupChinese()
            tts?.setOnUtteranceProgressListener(utteranceProgressListener)
        } else {
            Log.w(TAG, "TTS onInit status=$status（不判死，连接可用即朗读）")
        }
        readyLatch.countDown()
    }

    /**
     * 尽力将 TTS 语言设为中文（best-effort，只打日志不判成败）。
     * 全部失败也不影响朗读——系统默认引擎/语言仍能按文本合成（与 speak_reader 一致）。
     */
    private fun setupChinese() {
        try {
            val candidates = listOf(
                Locale.SIMPLIFIED_CHINESE, // zh-Hans-CN（Android 8+ 推荐写法）
                Locale.CHINA,              // zh-CN
                Locale.CHINESE,            // zh（兜底）
            )
            for (loc in candidates) {
                val code = tts?.setLanguage(loc) ?: TextToSpeech.LANG_NOT_SUPPORTED
                Log.i(TAG, "setLanguage($loc) -> code=$code")
                if (code != TextToSpeech.LANG_MISSING_DATA &&
                    code != TextToSpeech.LANG_NOT_SUPPORTED
                ) {
                    return
                }
            }
            val zhVoice = tts?.voices?.firstOrNull { it.locale.language == "zh" }
            if (zhVoice != null) {
                tts?.voice = zhVoice
                Log.i(TAG, "经 voices 兜底选中中文 voice: ${zhVoice.name} / ${zhVoice.locale}")
            } else {
                Log.w(TAG, "未匹配到中文 locale/voice，语言交由系统默认处理")
            }
        } catch (t: Throwable) {
            Log.e(TAG, "setupChinese 异常（不影响可用性）", t)
        }
    }

    private val utteranceProgressListener = object : UtteranceProgressListener() {
        override fun onStart(utteranceId: String?) {}
        override fun onDone(utteranceId: String?) {}
        @Deprecated("Deprecated in Java")
        override fun onError(utteranceId: String?) {}
        override fun onError(utteranceId: String?, errorCode: Int) {}
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "init" -> {
                // 引擎实体已创建即返回可用；service 连接未就绪时不判死。
                // 若尚未创建（理论上 attach 时已创建），补建一次。
                if (!engineCreated) createEngine()
                result.success(engineCreated)
            }
            "speak" -> {
                val text = call.argument<String>("text")
                if (text.isNullOrEmpty()) {
                    result.error("bad_arg", "text 不能为空", null)
                    return
                }
                // 阻塞等待播放完成，放后台线程避免卡 UI 线程。
                Thread {
                    try {
                        if (speakBlocking(text)) {
                            result.success(true)
                        } else {
                            result.error("tts_failed", "朗读失败或超时", null)
                        }
                    } catch (t: Throwable) {
                        Log.e(TAG, "speak 异常", t)
                        result.error("tts_failed", t.message ?: "朗读异常", null)
                    }
                }.start()
            }
            "stop" -> {
                tts?.stop()
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    /**
     * 阻塞播放 [text]，返回是否完成。
     *
     * flutter_tts 语义：连接不可用时自动重建 TextToSpeech 再试；永不因
     * init 状态拒绝朗读。超时由 [TIMEOUT_MS] 兜底。
     */
    private fun speakBlocking(text: String): Boolean {
        var ttsEngine = tts
        if (!isServiceConnectionUsable(ttsEngine)) {
            Log.w(TAG, "TTS service 连接未就绪，重建引擎后重试")
            handler.post { createEngine() }
            try {
                readyLatch.await(READY_WAIT_MS, TimeUnit.MILLISECONDS)
            } catch (_: InterruptedException) {
                return false
            }
            ttsEngine = tts
        }
        if (ttsEngine == null) {
            Log.e(TAG, "TTS 引擎为空，无法朗读")
            return false
        }

        val done = CountDownLatch(1)
        var finishedOk = false
        val listener = object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) {}
            override fun onDone(utteranceId: String?) {
                finishedOk = true
                done.countDown()
            }
            @Deprecated("Deprecated in Java")
            override fun onError(utteranceId: String?) {
                done.countDown()
            }
            override fun onError(utteranceId: String?, errorCode: Int) {
                done.countDown()
            }
        }
        ttsEngine.setOnUtteranceProgressListener(listener)
        val utteranceId = "wm_${UUID.randomUUID()}"
        val code = ttsEngine.speak(text, TextToSpeech.QUEUE_FLUSH, null, utteranceId)
        if (code != TextToSpeech.SUCCESS) {
            Log.w(TAG, "tts.speak 返回 $code")
            return false
        }
        try {
            done.await(TIMEOUT_MS, TimeUnit.MILLISECONDS)
        } catch (_: InterruptedException) {
            return false
        }
        return finishedOk
    }

    /**
     * 判定 TextToSpeech service 连接是否绑定（flutter_tts
     * ismServiceConnectionUsable 同款反射）。
     *
     * 这是「引擎是否真可用」的权威判定：onInit 返回非 SUCCESS 不代表连接失败，
     * 反之连接未绑定则 speak 必然失败。反射读私有字段 mServiceConnection，
     * 类型为 android.speech.tts.TextToSpeech$Connection。
     */
    private fun isServiceConnectionUsable(tts: TextToSpeech?): Boolean {
        if (tts == null) return false
        return try {
            val fields: Array<Field> = tts.javaClass.declaredFields
            var bound = true
            for (f in fields) {
                if (f.name == "mServiceConnection" &&
                    f.type.name == "android.speech.tts.TextToSpeech\$Connection"
                ) {
                    f.isAccessible = true
                    if (f.get(tts) == null) {
                        Log.w(TAG, "TTS mServiceConnection == null（未绑定）")
                        bound = false
                    }
                }
            }
            bound
        } catch (t: Throwable) {
            // 反射失败（ROM 字段名变化）时保守放行——交给 speak 返回值判定
            Log.w(TAG, "mServiceConnection 反射失败，保守放行: ${t.message}")
            true
        }
    }
}
