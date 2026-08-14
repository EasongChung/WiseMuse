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
import java.util.Locale

/**
 * [v0.4.1] 系统 TextToSpeech 朗读桥（MethodChannel）。
 *
 * 所有状态均在主线程串行处理，原生层是朗读取消语义的唯一权威：
 * - 每次 `speak` / `stop` 递增请求代次，旧请求永久失效；
 * - 新 `speak` 用 `QUEUE_FLUSH` 打断旧文本，并把旧 Future 完成为 false；
 * - 初始化期间只保留最新一条朗读请求，不创建并发等待线程；
 * - `speak` 直到 `onDone` 才返回 true，`onStop` / `onError` 返回 false；
 * - 引擎即时拒绝 speak 时最多受控重建一次，重试前仍校验请求代次。
 *
 * Manifest 必须声明 `android.intent.action.TTS_SERVICE` 包可见性，否则 Android
 * 11+ 上无法绑定系统 TTS。该根因已修复，不再保留旧版反射连接检查、
 * CountDownLatch 阻塞等待和多线程五次重建逻辑。
 */
class TtsBridge : FlutterPlugin, MethodChannel.MethodCallHandler {
    companion object {
        private const val CHANNEL = "com.zqpd.wisemuse/tts"
        private const val TAG = "TtsBridge"
        private const val MAX_SPEAK_RETRIES = 1
        private const val INIT_TIMEOUT_MS = 15000L
        private const val SPEAK_TIMEOUT_MS = 120000L
    }

    private enum class EngineState { IDLE, INITIALIZING, READY, FAILED, DETACHED }

    private data class SpeakRequest(
        val generation: Long,
        val text: String,
        val result: MethodChannel.Result,
        var retryCount: Int = 0,
        var utteranceId: String = "",
        var completed: Boolean = false,
    )

    private var channel: MethodChannel? = null
    private var context: Context? = null
    private var tts: TextToSpeech? = null
    private val handler = Handler(Looper.getMainLooper())

    // 引擎代次用于丢弃已 shutdown 引擎的迟到 onInit。
    private var engineGeneration = 0L
    private var engineState = EngineState.IDLE

    // 请求代次用于保证 latest-wins，并让 stop 成为真正的取消屏障。
    private var requestGeneration = 0L
    private var pendingSpeak: SpeakRequest? = null
    private var activeSpeak: SpeakRequest? = null
    private val initWaiters = mutableListOf<MethodChannel.Result>()
    private var initWatchdog: Runnable? = null
    private var speakWatchdog: Runnable? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel?.setMethodCallHandler(this)
        ensureEngine()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        requestGeneration++
        cancelCurrentPlayback(stopEngine = true)
        cancelInitWatchdog()
        completeInitWaiters(false)

        engineGeneration++
        engineState = EngineState.DETACHED
        try {
            tts?.shutdown()
        } catch (_: Throwable) {
        }
        tts = null
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "init" -> handleInit(result)
            "speak" -> handleSpeak(call, result)
            "stop" -> handleStop(result)
            "setVoice" -> handleSetVoice(call, result)
            else -> result.notImplemented()
        }
    }

    // ===== 初始化 =====

    private fun handleInit(result: MethodChannel.Result) {
        when (engineState) {
            EngineState.READY -> result.success(true)
            EngineState.DETACHED -> result.success(false)
            EngineState.INITIALIZING -> initWaiters.add(result)
            EngineState.IDLE, EngineState.FAILED -> {
                initWaiters.add(result)
                ensureEngine()
            }
        }
    }

    /** single-flight 初始化；同一时间最多存在一台正在初始化的引擎。 */
    private fun ensureEngine(forceRestart: Boolean = false) {
        if (engineState == EngineState.DETACHED) return
        if (!forceRestart &&
            (engineState == EngineState.INITIALIZING || engineState == EngineState.READY)
        ) {
            return
        }

        val ctx = context ?: run {
            engineState = EngineState.FAILED
            completeInitWaiters(false)
            failPendingSpeak("缺少 Android Context")
            return
        }

        val generation = ++engineGeneration
        engineState = EngineState.INITIALIZING
        scheduleInitWatchdog(generation)
        val previousEngine = tts
        tts = null
        if (previousEngine != null) {
            try {
                previousEngine.stop()
            } catch (t: Throwable) {
                Log.w(TAG, "重建前 stop 异常: ${t.message}")
            }
            try {
                previousEngine.shutdown()
            } catch (t: Throwable) {
                Log.w(TAG, "重建前 shutdown 异常: ${t.message}")
            }
        }

        try {
            Log.i(TAG, "创建 TextToSpeech（engineGeneration=$generation）")
            val candidate = TextToSpeech(ctx) { status ->
                // 即使 ROM 在 Binder 线程回调，也统一回主线程修改状态。
                handler.post { handleEngineInit(generation, status) }
            }
            tts = candidate
        } catch (t: Throwable) {
            Log.e(TAG, "TextToSpeech 构造异常", t)
            handleEngineFailure(generation, "TextToSpeech 构造异常: ${t.message}")
        }
    }

    private fun handleEngineInit(generation: Long, status: Int) {
        if (generation != engineGeneration || engineState == EngineState.DETACHED) {
            Log.d(TAG, "忽略旧引擎 onInit: generation=$generation status=$status")
            return
        }
        cancelInitWatchdog()

        val engine = tts
        if (status != TextToSpeech.SUCCESS || engine == null) {
            handleEngineFailure(generation, "TTS onInit status=$status")
            return
        }

        engineState = EngineState.READY
        setupChinese(engine)
        engine.setOnUtteranceProgressListener(utteranceProgressListener)
        Log.i(TAG, "TTS onInit SUCCESS（engine=${engineName(engine)}）")
        completeInitWaiters(true)
        startPendingSpeak()
    }

    private fun handleEngineFailure(generation: Long, diagnostic: String) {
        if (generation != engineGeneration || engineState == EngineState.DETACHED) return
        cancelInitWatchdog()
        engineState = EngineState.FAILED
        Log.e(TAG, diagnostic)
        completeInitWaiters(false)
        failPendingSpeak(diagnostic)
    }

    private fun completeInitWaiters(ok: Boolean) {
        if (initWaiters.isEmpty()) return
        val waiters = initWaiters.toList()
        initWaiters.clear()
        for (waiter in waiters) {
            waiter.success(ok)
        }
    }

    // ===== 朗读 =====

    private fun handleSpeak(call: MethodCall, result: MethodChannel.Result) {
        val text = call.argument<String>("text")?.trim()
        if (text.isNullOrEmpty()) {
            result.error("bad_arg", "text 不能为空", null)
            return
        }

        val generation = ++requestGeneration
        if (!cancelCurrentPlayback(stopEngine = true)) {
            result.error("tts_stop_failed", "无法停止或销毁上一条 TTS 请求", null)
            return
        }
        pendingSpeak = SpeakRequest(generation, text, result)

        when (engineState) {
            EngineState.READY -> startPendingSpeak()
            EngineState.INITIALIZING -> Unit // onInit 后只启动最新请求
            EngineState.IDLE, EngineState.FAILED -> ensureEngine()
            EngineState.DETACHED -> failPendingSpeak("TTS 桥已释放")
        }
    }

    private fun startPendingSpeak() {
        val request = pendingSpeak ?: return
        if (request.generation != requestGeneration || engineState != EngineState.READY) {
            return
        }
        val engine = tts ?: run {
            retryOrFail(request, "引擎为空")
            return
        }

        pendingSpeak = null
        request.utteranceId = "wm_${request.generation}"
        activeSpeak = request

        val code = try {
            engine.speak(
                request.text,
                TextToSpeech.QUEUE_FLUSH,
                null,
                request.utteranceId,
            )
        } catch (t: Throwable) {
            Log.e(TAG, "engine.speak 异常", t)
            TextToSpeech.ERROR
        }

        if (code != TextToSpeech.SUCCESS) {
            activeSpeak = null
            retryOrFail(
                request,
                "speak 返回 $code（engine=${engineName(engine)}）",
            )
            return
        }
        scheduleSpeakWatchdog(request)
        Log.i(TAG, "朗读已开始入队: generation=${request.generation}")
    }

    /** 即时 speak 失败时只重建一次；被更新请求覆盖后禁止重试。 */
    private fun retryOrFail(request: SpeakRequest, diagnostic: String) {
        if (request.generation != requestGeneration || request.completed) {
            completeSpeak(request, false)
            return
        }
        if (request.retryCount >= MAX_SPEAK_RETRIES) {
            completeSpeakError(request, diagnostic)
            return
        }

        request.retryCount++
        pendingSpeak = request
        Log.w(TAG, "$diagnostic，重建引擎后重试 ${request.retryCount}/$MAX_SPEAK_RETRIES")
        ensureEngine(forceRestart = true)
    }

    private fun handleStop(result: MethodChannel.Result) {
        requestGeneration++
        if (cancelCurrentPlayback(stopEngine = true)) {
            result.success(true)
        } else {
            result.error("tts_stop_failed", "系统 TTS 停止和强制销毁均失败", null)
        }
    }

    /**
     * 取消 pending/active Future，再停止当前引擎。
     *
     * 由于不存在后台 speak 线程，方法返回后没有旧任务能再次进入 engine.speak。
     * 系统 stop 失败时立即 shutdown 并使引擎代次失效，确保取消屏障仍成立。
     */
    private fun cancelCurrentPlayback(stopEngine: Boolean): Boolean {
        cancelSpeakWatchdog()
        val hadActiveSpeak = activeSpeak != null
        pendingSpeak?.let { completeSpeak(it, false) }
        pendingSpeak = null
        activeSpeak?.let { completeSpeak(it, false) }
        activeSpeak = null

        // 初始化期间或仅有 pending 请求时尚未发声，无需 stop/shutdown 引擎。
        if (!stopEngine || !hadActiveSpeak) return true
        val engine = tts ?: return true
        val stopped = try {
            engine.stop() == TextToSpeech.SUCCESS
        } catch (t: Throwable) {
            Log.w(TAG, "TTS stop 异常: ${t.message}")
            false
        }
        if (stopped) return true

        Log.w(TAG, "TTS stop 失败，强制 shutdown 当前引擎")
        return invalidateAndShutdownEngine(engine)
    }

    /** stop 失败后的最终兜底：销毁引擎并让所有旧回调永久失效。 */
    private fun invalidateAndShutdownEngine(engine: TextToSpeech): Boolean {
        cancelInitWatchdog()
        engineGeneration++
        tts = null
        if (engineState != EngineState.DETACHED) {
            engineState = EngineState.IDLE
        }
        completeInitWaiters(false)
        return try {
            engine.shutdown()
            true
        } catch (t: Throwable) {
            Log.e(TAG, "TTS shutdown 异常", t)
            if (engineState != EngineState.DETACHED) {
                engineState = EngineState.FAILED
            }
            false
        }
    }

    private fun failPendingSpeak(diagnostic: String) {
        val request = pendingSpeak ?: return
        pendingSpeak = null
        completeSpeakError(request, diagnostic)
    }

    private fun completeSpeak(request: SpeakRequest, ok: Boolean) {
        if (request.completed) return
        request.completed = true
        request.result.success(ok)
    }

    private fun completeSpeakError(request: SpeakRequest, diagnostic: String) {
        if (request.completed) return
        request.completed = true
        Log.e(TAG, "朗读失败: $diagnostic")
        request.result.error("tts_failed", diagnostic, null)
    }

    // ===== TTS 回调 =====

    private val utteranceProgressListener = object : UtteranceProgressListener() {
        override fun onStart(utteranceId: String?) {
            Log.d(TAG, "onStart: $utteranceId")
        }

        override fun onDone(utteranceId: String?) {
            handler.post { finishUtterance(utteranceId, ok = true, diagnostic = null) }
        }

        override fun onStop(utteranceId: String?, interrupted: Boolean) {
            handler.post {
                finishUtterance(
                    utteranceId,
                    ok = false,
                    diagnostic = "朗读被停止（interrupted=$interrupted）",
                )
            }
        }

        @Deprecated("Deprecated in Java")
        override fun onError(utteranceId: String?) {
            handler.post {
                finishUtterance(utteranceId, ok = false, diagnostic = "TTS onError")
            }
        }

        override fun onError(utteranceId: String?, errorCode: Int) {
            handler.post {
                finishUtterance(
                    utteranceId,
                    ok = false,
                    diagnostic = "TTS onError(errorCode=$errorCode)",
                )
            }
        }
    }

    private fun finishUtterance(
        utteranceId: String?,
        ok: Boolean,
        diagnostic: String?,
    ) {
        val request = activeSpeak ?: return
        if (utteranceId != request.utteranceId) return
        cancelSpeakWatchdog()
        activeSpeak = null

        // 旧请求即使收到迟到 onDone，也只能返回 false，不能覆盖最新状态。
        if (request.generation != requestGeneration) {
            completeSpeak(request, false)
            return
        }
        if (ok) {
            Log.i(TAG, "朗读完成: generation=${request.generation}")
            completeSpeak(request, true)
        } else {
            Log.w(TAG, diagnostic ?: "朗读未完成")
            completeSpeak(request, false)
        }
    }

    // ===== Watchdog =====

    private fun scheduleInitWatchdog(generation: Long) {
        cancelInitWatchdog()
        val watchdog = Runnable {
            if (generation != engineGeneration || engineState != EngineState.INITIALIZING) {
                return@Runnable
            }
            Log.e(TAG, "TTS 初始化超时（${INIT_TIMEOUT_MS}ms）")
            val engine = tts
            if (engine != null) {
                invalidateAndShutdownEngine(engine)
            } else {
                engineGeneration++
                engineState = EngineState.FAILED
                completeInitWaiters(false)
            }
            failPendingSpeak("TTS 初始化超时")
        }
        initWatchdog = watchdog
        handler.postDelayed(watchdog, INIT_TIMEOUT_MS)
    }

    private fun cancelInitWatchdog() {
        initWatchdog?.let(handler::removeCallbacks)
        initWatchdog = null
    }

    private fun scheduleSpeakWatchdog(request: SpeakRequest) {
        cancelSpeakWatchdog()
        val generation = request.generation
        val utteranceId = request.utteranceId
        val watchdog = Runnable {
            val active = activeSpeak
            if (active !== request ||
                active.completed ||
                generation != requestGeneration ||
                utteranceId != active.utteranceId
            ) {
                return@Runnable
            }

            Log.e(TAG, "TTS 朗读超时（${SPEAK_TIMEOUT_MS}ms）")
            requestGeneration++
            activeSpeak = null
            completeSpeak(request, false)
            val engine = tts
            if (engine != null) {
                invalidateAndShutdownEngine(engine)
            }
        }
        speakWatchdog = watchdog
        handler.postDelayed(watchdog, SPEAK_TIMEOUT_MS)
    }

    private fun cancelSpeakWatchdog() {
        speakWatchdog?.let(handler::removeCallbacks)
        speakWatchdog = null
    }

    // ===== 工具 =====

    /** 设置 TTS 音色（按名称匹配，空串=默认）。 */
    private fun handleSetVoice(call: MethodCall, result: MethodChannel.Result) {
        val name = call.argument<String>("name") ?: ""
        val engine = tts ?: run {
            result.success(false)
            return
        }
        if (name.isEmpty()) {
            // 空串=系统默认
            setupChinese(engine)
            Log.i(TAG, "音色已重置为系统默认")
            result.success(true)
            return
        }
        try {
            val matched = engine.voices?.firstOrNull { it.name == name }
            if (matched != null) {
                engine.voice = matched
                Log.i(TAG, "音色已设为: ${matched.name} / ${matched.locale}")
                result.success(true)
            } else {
                Log.w(TAG, "未匹配到音色: $name，保留当前")
                result.success(false)
            }
        } catch (t: Throwable) {
            Log.e(TAG, "setVoice 异常", t)
            result.success(false)
        }
    }

    /** 尽力将语言设为中文；失败不阻断引擎使用。 */
    private fun setupChinese(engine: TextToSpeech) {
        try {
            val candidates = listOf(
                Locale.SIMPLIFIED_CHINESE,
                Locale.CHINA,
                Locale.CHINESE,
            )
            for (locale in candidates) {
                val code = engine.setLanguage(locale)
                Log.i(TAG, "setLanguage($locale) -> code=$code")
                if (code != TextToSpeech.LANG_MISSING_DATA &&
                    code != TextToSpeech.LANG_NOT_SUPPORTED
                ) {
                    return
                }
            }
            val zhVoice = engine.voices?.firstOrNull { it.locale.language == "zh" }
            if (zhVoice != null) {
                engine.voice = zhVoice
                Log.i(TAG, "经 voices 兜底选中中文 voice: ${zhVoice.name} / ${zhVoice.locale}")
            } else {
                Log.w(TAG, "未匹配到中文 locale/voice，语言交由系统默认处理")
            }
        } catch (t: Throwable) {
            Log.e(TAG, "setupChinese 异常（不影响可用性）", t)
        }
    }

    private fun engineName(engine: TextToSpeech): String {
        return try {
            engine.defaultEngine ?: "null"
        } catch (_: Throwable) {
            "未知"
        }
    }
}
