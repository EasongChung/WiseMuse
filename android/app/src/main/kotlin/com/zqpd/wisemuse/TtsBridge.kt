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
 * [v0.4.0] 系统 TextToSpeech 朗读桥（MethodChannel）。
 *
 * 语义完整对齐开源 flutter_tts 插件（用户授权直接复用其语义；本桥为
 * AGP9 Built-in Kotlin 约束下的等价移植）：
 * 1. **onInit 失败不判死**：status≠SUCCESS 只打日志，不把引擎标为不可用。
 *    可用性由「TextToSpeech service 连接是否绑定」决定（反射读
 *    mServiceConnection），而非 onInit 返回值。
 * 2. **speak 失败自动重建引擎并重试**（flutter_tts speak():627-630 同款：
 *    连接未绑定 / speak 返回非 0 → 销毁重建 TextToSpeech 再试），最多
 *    [MAX_SPEAK_ATTEMPTS] 次，永不因一次失败立即放弃。真机实测 onInit 可能
 *    返回非 SUCCESS 但重建后连接可用，这是「语音引擎不可用」误报的根因。
 * 3. **诊断回传**：speak 失败时把 onInit status / speak 返回码 / 引擎名塞进
 *    error message，Dart 层 AppLog 直接可见，便于下次日志确诊。
 * 4. 用 applicationContext 构造引擎（flutter_tts onAttachedToEngine 同款）。
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
        private const val MAX_SPEAK_ATTEMPTS = 5
    }

    private var channel: MethodChannel? = null
    private var context: Context? = null
    private var tts: TextToSpeech? = null
    private val handler = Handler(Looper.getMainLooper())

    // 引擎是否已创建实例（是否至少发起过初始化）
    @Volatile
    private var engineCreated = false

    // 最近一次 onInit 的 status（诊断用，非判死依据）
    @Volatile
    private var lastOnInitStatus = Int.MIN_VALUE

    // 等待引擎 service 连接就绪（onInit 回调后打开）
    @Volatile
    private var readyLatch = CountDownLatch(1)

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel?.setMethodCallHandler(this)
        // 预初始化：进入页面即建引擎，点播放时大概率已就绪
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
        lastOnInitStatus = status
        // flutter_tts 语义：onInit 失败不判死，只打日志。连接可用性由
        // isServiceConnectionUsable() 判定，而非 status。
        if (status == TextToSpeech.SUCCESS) {
            Log.i(TAG, "TTS onInit SUCCESS")
            setupChinese()
            tts?.setOnUtteranceProgressListener(utteranceProgressListener)
        } else {
            Log.w(TAG, "TTS onInit status=$status（不判死，speak 时重建重试）")
        }
        readyLatch.countDown()
    }

    /**
     * 尽力将 TTS 语言设为中文（best-effort，只打日志不判成败）。
     * 全部失败也不影响朗读——系统默认引擎/语言仍能按文本合成。
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
                        val (ok, diag) = speakBlocking(text)
                        if (ok) {
                            result.success(true)
                        } else {
                            result.error("tts_failed", diag, null)
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
     * 阻塞播放 [text]，返回是否完成及失败诊断信息。
     *
     * flutter_tts 语义：speak 失败（连接不可用 / 返回非 0 / 超时 / onError）时
     * 销毁重建 TextToSpeech 并重试，最多 [MAX_SPEAK_ATTEMPTS] 次。诊断信息
     * 附带 onInit status / speak 返回码 / 引擎名，供 Dart 层 AppLog 记录。
     */
    private fun speakBlocking(text: String): Pair<Boolean, String> {
        var attempt = 0
        var lastDiag = "未知失败"
        while (attempt < MAX_SPEAK_ATTEMPTS) {
            attempt++
            val engine = tts
            if (engine == null) {
                lastDiag = "引擎为空（onInit=$lastOnInitStatus）"
                rebuildAndWait()
                continue
            }
            if (!isServiceConnectionUsable(engine)) {
                lastDiag = "service 连接未绑定（onInit=$lastOnInitStatus）"
                rebuildAndWait()
                continue
            }

            // 连接可用，尝试 speak
            val done = CountDownLatch(1)
            var finishedOk = false
            var errorCode = -1
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
                override fun onError(utteranceId: String?, code: Int) {
                    errorCode = code
                    done.countDown()
                }
            }
            engine.setOnUtteranceProgressListener(listener)
            val uid = "wm_${UUID.randomUUID()}"
            val code = engine.speak(text, TextToSpeech.QUEUE_FLUSH, null, uid)
            if (code != TextToSpeech.SUCCESS) {
                lastDiag = "speak 返回 $code（onInit=$lastOnInitStatus, engine=${engineName(engine)}）"
                Log.w(TAG, "speak 返回 $code（尝试 $attempt/$MAX_SPEAK_ATTEMPTS）")
                rebuildAndWait()
                continue
            }
            val finished = try {
                done.await(TIMEOUT_MS, TimeUnit.MILLISECONDS)
            } catch (_: InterruptedException) {
                false
            }
            if (finished && finishedOk) {
                return true to ""
            }
            lastDiag = if (finishedOk) {
                "onError(errorCode=$errorCode, onInit=$lastOnInitStatus)"
            } else {
                "speak 超时（${TIMEOUT_MS}ms, onInit=$lastOnInitStatus）"
            }
            Log.w(TAG, "speak 未完成（尝试 $attempt/$MAX_SPEAK_ATTEMPTS）: $lastDiag")
            rebuildAndWait()
        }
        return false to lastDiag
    }

    /** 主线程重建引擎并等待 onInit（后台线程阻塞）。 */
    private fun rebuildAndWait() {
        handler.post { createEngine() }
        try {
            readyLatch.await(READY_WAIT_MS, TimeUnit.MILLISECONDS)
        } catch (_: InterruptedException) {
            // 忽略
        }
    }

    private fun engineName(engine: TextToSpeech): String {
        return try {
            engine.defaultEngine ?: "null"
        } catch (_: Throwable) {
            "未知"
        }
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
