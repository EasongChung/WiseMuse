package com.zqpd.wisemuse

import android.app.Activity
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * [v0.2.0] 系统 TextToSpeech 朗读桥（MethodChannel）。
 *
 * 修复（v0.2.0，真机「TTS 依旧不可用」）：
 * 1. **改用 Activity context 构造引擎**——v0.1.0 用 applicationContext，部分 ROM
 *    （国产）上 onInit 回调失败或超时，导致 `ready` 恒 false 误报不可用。
 *    对齐 speak_reader 的 flutter_tts（其 Android 端用 activity context）。
 * 2. **init 自愈重试**：onInit 未成功时销毁重建引擎（最多 [MAX_INIT_ATTEMPTS] 次），
 *    每次重新等待 onInit，解决引擎慢热/首启一次失败。
 * 3. **可用性只信 onInit SUCCESS**（引擎实体在线即可用），语言匹配 best-effort 不降级。
 *    setupChinese 全包 try/catch，异常不影响 ready 赋值。
 *
 * 阻塞播放完成通过后台线程 + CountDownLatch 实现，不卡 UI 线程。
 */
class TtsBridge : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler,
    TextToSpeech.OnInitListener {
    companion object {
        private const val CHANNEL = "com.zqpd.wisemuse/tts"
        private const val TAG = "TtsBridge"
        private const val TIMEOUT_MS = 30000L
        private const val MAX_INIT_ATTEMPTS = 3
    }

    private var channel: MethodChannel? = null
    private var activityContext: Activity? = null
    private var tts: TextToSpeech? = null

    @Volatile
    private var ready = false

    @Volatile
    private var initLatch = CountDownLatch(0)

    // ---- FlutterPlugin ----
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel?.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        shutdownTts()
    }

    // ---- ActivityAware：用 Activity context 初始化 TTS ----
    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityContext = binding.activity
        // 预初始化：进入页面即建引擎，点播放时大概率已就绪
        startInit()
    }

    override fun onDetachedFromActivity() {
        activityContext = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activityContext = binding.activity
        startInit()
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activityContext = null
    }

    /** 在调用线程（主线程）启动一次引擎初始化；onInit 异步回调后 latch 打开。 */
    private fun startInit() {
        val ctx = activityContext ?: return
        ready = false
        initLatch = CountDownLatch(1)
        try {
            tts?.shutdown()
        } catch (_: Throwable) {
        }
        tts = null
        try {
            Log.i(TAG, "创建 TextToSpeech（activity context）")
            tts = TextToSpeech(ctx, this)
        } catch (t: Throwable) {
            Log.e(TAG, "TextToSpeech 构造异常", t)
            initLatch.countDown()
        }
    }

    private fun shutdownTts() {
        try {
            tts?.stop()
        } catch (_: Throwable) {
        }
        try {
            tts?.shutdown()
        } catch (_: Throwable) {
        }
        tts = null
        ready = false
    }

    override fun onInit(status: Int) {
        try {
            if (status == TextToSpeech.SUCCESS) {
                Log.i(TAG, "TTS 引擎初始化 SUCCESS")
                // 引擎实体在线即可用——语言匹配只是「尽力而为」，不因匹配失败而降级为
                // 不可用。语义对齐 speak_reader（flutter_tts）：引擎可用性只取决于
                // onInit 是否 SUCCESS，语言交由系统引擎按文本自动处理。
                setupChinese()
                ready = true
                tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                    override fun onStart(utteranceId: String?) {}
                    override fun onDone(utteranceId: String?) {}
                    @Deprecated("Deprecated in Java")
                    override fun onError(utteranceId: String?) {}
                    override fun onError(utteranceId: String?, errorCode: Int) {}
                })
            } else {
                Log.w(TAG, "TTS 引擎初始化失败 status=$status（init 将自愈重试）")
            }
        } catch (t: Throwable) {
            Log.e(TAG, "onInit 异常", t)
        } finally {
            initLatch.countDown()
        }
    }

    /**
     * 尽力将 TTS 语言设为中文（best-effort，只打日志不判成败）。
     *
     * 国产 ROM 引擎对裸 `Locale.CHINESE`（zh 无地区）常返回 LANG_NOT_SUPPORTED，
     * 故逐个尝试带地区的简体中文 locale，再兜底系统 zh voice；全部失败也不影响
     * [ready]——系统默认引擎/语言仍能按文本合成（与 speak_reader 一致）。
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
            // 兜底：从系统 voice 列表找中文音色（部分引擎语言码不匹配但 voice 可用）
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

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "init" -> {
                // 引擎未就绪：自愈重试（引擎慢热/首启失败场景）。
                // onInit 快速失败时 3 轮重试约 1s；慢热时每轮等 onInit 最多 10s。
                var attempt = 0
                while (!ready && attempt < MAX_INIT_ATTEMPTS) {
                    attempt++
                    Log.i(TAG, "init 重试 #$attempt")
                    startInit()
                    try {
                        initLatch.await(10, TimeUnit.SECONDS)
                    } catch (_: InterruptedException) {
                        break
                    }
                }
                result.success(ready)
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
                        if (!ready) {
                            result.error("tts_not_ready", "语音引擎未就绪", null)
                            return@Thread
                        }
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

    private fun speakBlocking(text: String): Boolean {
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
        tts?.setOnUtteranceProgressListener(listener)
        val utteranceId = "wm_${System.currentTimeMillis()}"
        val code = tts?.speak(text, TextToSpeech.QUEUE_FLUSH, null, utteranceId)
        if (code != TextToSpeech.SUCCESS) {
            return false
        }
        try {
            done.await(TIMEOUT_MS, TimeUnit.MILLISECONDS)
        } catch (_: InterruptedException) {
            return false
        }
        return finishedOk
    }
}
