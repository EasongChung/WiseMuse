package com.arm.aichat

import android.content.Context
import com.arm.aichat.internal.InferenceEngineImpl

/**
 * Main entry point for Arm's AI Chat library.
 */
object AiChat {
    /**
     * Get the inference engine single instance.
     * @param context Application context
     * @param customLibDir Optional custom directory where downloaded .so files are stored
     */
    fun getInferenceEngine(context: Context, customLibDir: String? = null) =
        InferenceEngineImpl.getInstance(context, customLibDir)

    /**
     * Reset the inference engine single instance.
     */
    fun resetInstance() {
        InferenceEngineImpl.resetInstance()
    }
}

