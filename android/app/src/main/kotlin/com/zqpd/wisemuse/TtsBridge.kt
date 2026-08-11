package com.zqpd.wisemuse

import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * [v0.1.0] 系统 TextToSpeech 朗读桥（MethodChannel）。
 *
 * - `init()` 等待引擎就绪，返回是否可用（引擎实体在线即可用，语言尽力匹配）
 * - `speak(text)` 阻塞到播放完成/失败，返回是否完成
 * - `stop()` 停止当前朗读
 *
 * TTS 用系统引擎（Android 8+ 自带），中文 `setLanguage` 为 best-effort。
 * 可用性判定对齐 speak_reader（flutter_tts）：只信 onInit SUCCESS，语言匹配失败
 * 不降级为「引擎不可用」（曾有设备因此误报不可用）。
 * 阻塞播放完成通过后台线程 + CountDownLatch 实现，不卡 UI 线程。
 */
class TtsBridge : FlutterPlugin, MethodChannel.MethodCallHandler,
    TextToSpeech.OnInitListener {
    companion object {
        private const val CHANNEL = "com.zqpd.wisemuse/tts"
        private const val TAG = "TtsBridge"
        private const val TIMEOUT_MS = 30000L
    }

    private var channel: MethodChannel? = null
    private var tts: TextToSpeech? = null
    private var ready = false
    private val initLatch = CountDownLatch(1)

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel?.setMethodCallHandler(this)
        tts = TextToSpeech(binding.applicationContext, this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        tts?.stop()
        tts?.shutdown()
        tts = null
        ready = false
    }

    override fun onInit(status: Int) {
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
            })
        } else {
            Log.w(TAG, "TTS 引擎初始化失败 status=$status")
        }
        initLatch.countDown()
    }

    /**
     * 尽力将 TTS 语言设为中文（best-effort，只打日志不判成败）。
     *
     * 国产 ROM 引擎对裸 `Locale.CHINESE`（zh 无地区）常返回 LANG_NOT_SUPPORTED，
     * 故逐个尝试带地区的简体中文 locale，再兜底系统 zh voice；全部失败也不影响
     * [ready]——系统默认引擎/语言仍能按文本合成（与 speak_reader 一致）。
     */
    private fun setupChinese() {
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
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "init" -> {
                if (waitReady()) {
                    result.success(ready)
                } else {
                    result.error("tts_not_ready", "语音引擎初始化超时", null)
                }
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
                        if (!waitReady() || !ready) {
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

    private fun waitReady(): Boolean {
        try {
            initLatch.await(10, TimeUnit.SECONDS)
        } catch (_: InterruptedException) {
            return false
        }
        return true
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
