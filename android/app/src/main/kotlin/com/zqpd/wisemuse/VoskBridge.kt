package com.zqpd.wisemuse

import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import org.vosk.Model
import org.vosk.Recognizer

/**
 * [v0.1.0] Vosk 离线语音识别桥（MethodChannel）。
 *
 * 封装 vosk-android（Apache-2.0）的模型加载与麦克风实时识别：
 * - `init(modelPath)` 加载模型（模型目录含 `am`/`conf`/`graph` 等子目录）
 * - `start()` 启动录音 + 识别线程（PCM 喂 VoskRecognizer）
 * - `stop()` 停止录音并返回最终识别文本
 * - `isLoaded()` / `dispose()` 状态与释放
 *
 * 采样率固定 16kHz 单声道 PCM16（Vosk 标准输入）。
 */
class VoskBridge : FlutterPlugin, MethodChannel.MethodCallHandler {
    companion object {
        private const val CHANNEL = "com.zqpd.wisemuse/vosk"
        private const val SAMPLE_RATE = 16000
    }

    private var channel: MethodChannel? = null
    private var model: Model? = null
    private var recognizer: Recognizer? = null
    private var audioRecord: AudioRecord? = null
    @Volatile private var recording = false
    private var recordThread: Thread? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel?.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        dispose()
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "init" -> {
                val path = call.argument<String>("modelPath")
                if (path.isNullOrEmpty()) {
                    result.error("bad_arg", "modelPath 不能为空", null)
                    return
                }
                try {
                    dispose()
                    model = Model(path)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("init_failed", "模型加载失败: ${e.message}", null)
                }
            }
            "isLoaded" -> result.success(model != null)
            "start" -> {
                if (model == null) {
                    result.error("no_model", "模型未初始化，先调用 init", null)
                    return
                }
                try {
                    startRecording()
                    result.success(true)
                } catch (e: Exception) {
                    result.error("start_failed", "启动录音失败: ${e.message}", null)
                }
            }
            "stop" -> {
                try {
                    result.success(stopRecording())
                } catch (e: Exception) {
                    result.error("stop_failed", "停止录音失败: ${e.message}", null)
                }
            }
            "dispose" -> {
                dispose()
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun startRecording() {
        val bufferSize = AudioRecord.getMinBufferSize(
            SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT
        )
        recognizer = Recognizer(model, SAMPLE_RATE.toFloat())
        audioRecord = AudioRecord(
            MediaRecorder.AudioSource.MIC,
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            bufferSize * 4
        ).apply { startRecording() }

        recording = true
        recordThread = Thread {
            val buffer = ByteArray(bufferSize)
            while (recording) {
                val read = audioRecord?.read(buffer, 0, buffer.size) ?: 0
                if (read > 0) {
                    recognizer?.acceptWaveForm(buffer, read)
                }
            }
        }.apply { start() }
    }

    private fun stopRecording(): String {
        recording = false
        recordThread?.join(1000)
        recordThread = null
        audioRecord?.stop()
        audioRecord?.release()
        audioRecord = null
        val text = recognizer?.finalResult?.let(::parseText) ?: ""
        recognizer?.close()
        recognizer = null
        return text
    }

    private fun parseText(json: String): String =
        try {
            JSONObject(json).optString("text", "").trim()
        } catch (e: Exception) {
            ""
        }

    private fun dispose() {
        recording = false
        recordThread?.join(1000)
        recordThread = null
        audioRecord?.stop()
        audioRecord?.release()
        audioRecord = null
        recognizer?.close()
        recognizer = null
        model?.close()
        model = null
    }
}
