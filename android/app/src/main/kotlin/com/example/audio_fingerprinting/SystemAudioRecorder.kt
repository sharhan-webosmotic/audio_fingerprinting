package com.example.audio_fingerprinting

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioPlaybackCaptureConfiguration
import android.media.MediaRecorder
import android.media.projection.MediaProjection
import android.os.Build
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException

class SystemAudioRecorder(private val context: Context, private val channel: MethodChannel) {
    companion object {
        private const val TAG = "SystemAudioRecorder"
        const val MEDIA_PROJECTION_REQUEST_CODE = 1000
    }

    private var mediaRecorder: MediaRecorder? = null
    private var isRecording = false
    private var outputFile: File? = null

    fun startRecording(mediaProjection: MediaProjection) {
        if (isRecording) {
            Log.d(TAG, "Recording already in progress")
            return
        }

        try {
            Log.d(TAG, "Starting new recording")
            outputFile = File(context.getExternalFilesDir(null), "recordings").apply { mkdirs() }
                .resolve("recording_${System.currentTimeMillis()}.m4a")
            Log.d(TAG, "Will save recording to: ${outputFile?.absolutePath}")

            val config = AudioPlaybackCaptureConfiguration.Builder(mediaProjection)
                .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                .addMatchingUsage(AudioAttributes.USAGE_GAME)
                .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
                .build()
            Log.d(TAG, "Created audio capture configuration")

            mediaRecorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                MediaRecorder(context)
            } else {
                @Suppress("DEPRECATION")
                MediaRecorder()
            }.apply {
                // Only use capture config on Android 10 (Q) and above
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    try {
                        Log.d(TAG, "Setting audio capture config for Android Q+")
                        javaClass.getMethod("setAudioPlaybackCaptureConfig", AudioPlaybackCaptureConfiguration::class.java)
                            .invoke(this, config)
                        Log.d(TAG, "Successfully set audio capture config")
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to set capture config: ${e.message}")
                        throw Exception("Failed to configure audio capture: ${e.message}")
                    }
                } else {
                    Log.d(TAG, "Android version below Q, skipping capture config")
                }
                Log.d(TAG, "Configuring MediaRecorder")
                setAudioSource(MediaRecorder.AudioSource.REMOTE_SUBMIX)
                setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                setAudioEncodingBitRate(128000)
                setAudioSamplingRate(44100)
                setOutputFile(outputFile?.absolutePath)
                Log.d(TAG, "MediaRecorder configured successfully")

                try {
                    prepare()
                } catch (e: IOException) {
                    Log.e("SystemAudioRecorder", "prepare() failed: ${e.message}")
                    throw e
                }

                start()
            }

            isRecording = true

        } catch (e: Exception) {
            (context as? Activity)?.runOnUiThread {
                channel.invokeMethod("onRecordingError", e.message ?: "Unknown error")
            }
            cleanup()
        }
    }

    fun stopRecording() {
        if (!isRecording) return

        try {
            isRecording = false
            val currentFile = outputFile // Store reference before cleanup
            
            try {
                mediaRecorder?.apply {
                    stop()
                    release()
                }
            } catch (e: Exception) {
                println("Error stopping MediaRecorder: ${e.message}")
            }
            mediaRecorder = null

            currentFile?.let { file ->
                if (file.exists() && file.length() > 0) {
                    (context as? Activity)?.runOnUiThread {
                        channel.invokeMethod("onRecordingComplete", file.absolutePath)
                    }
                } else {
                    throw Exception("Recording file is empty or does not exist")
                }
            }
        } catch (e: Exception) {
            (context as? Activity)?.runOnUiThread {
                channel.invokeMethod("onRecordingError", "Error stopping recording: ${e.message}")
            }
        } finally {
            cleanup()
        }
    }

    private fun cleanup() {
        try {
            isRecording = false
            mediaRecorder?.release()
            mediaRecorder = null
        } catch (e: Exception) {
            // Ignore cleanup errors
        }
    }

    private fun intToByteArray(value: Int): ByteArray {
        return byteArrayOf(
            value.toByte(),
            (value shr 8).toByte(),
            (value shr 16).toByte(),
            (value shr 24).toByte()
        )
    }


}
