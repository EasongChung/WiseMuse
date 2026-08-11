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
 * - `init()` 等待引擎就绪，返回是否可用
 * - `speak(text)` 阻塞到播放完成/失败，返回是否完成
 * - `stop()` 停止当前朗读
 *
 * TTS 用系统引擎（Android 8+ 自带），中文 `setLanguage(Locale.CHINESE)`。
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
            val result = tts?.setLanguage(Locale.CHINESE)
            ready = result != TextToSpeech.LANG_MISSING_DATA &&
                result != TextToSpeech.LANG_NOT_SUPPORTED
            if (ready) {
                tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                    override fun onStart(utteranceId: String?) {}
                    override fun onDone(utteranceId: String?) {}
                    @Deprecated("Deprecated in Java")
                    override fun onError(utteranceId: String?) {}
                })
            } else {
                Log.w(TAG, "中文 TTS 语音包缺失/不支持 (setLanguage=$result)")
            }
        } else {
            Log.w(TAG, "TTS 初始化失败 status=$status")
        }
        initLatch.countDown()
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
