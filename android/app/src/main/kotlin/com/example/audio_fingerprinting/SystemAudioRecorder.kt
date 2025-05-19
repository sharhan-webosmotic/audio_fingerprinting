package com.example.audio_fingerprinting

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.media.AudioRecord
import android.media.AudioFormat
import android.media.MediaRecorder
import io.flutter.plugin.common.MethodChannel
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import kotlin.concurrent.thread

class SystemAudioRecorder(private val activity: Activity, private val channel: MethodChannel?) {
    private var mediaProjectionManager: MediaProjectionManager? = null
    private var mediaProjection: MediaProjection? = null
    private var audioRecord: AudioRecord? = null
    private var isRecording = false
    private val sampleRate = 44100
    private val channelConfig = AudioFormat.CHANNEL_IN_STEREO
    private val audioFormat = AudioFormat.ENCODING_PCM_16BIT
    private val bufferSize = AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioFormat)

    init {
        mediaProjectionManager = activity.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
    }

    fun startRecording() {
        val intent = mediaProjectionManager?.createScreenCaptureIntent()
        activity.startActivityForResult(intent, MEDIA_PROJECTION_REQUEST_CODE)
    }

    fun handleActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == MEDIA_PROJECTION_REQUEST_CODE && resultCode == Activity.RESULT_OK && data != null) {
            mediaProjection = mediaProjectionManager?.getMediaProjection(resultCode, data)
            startAudioCapture()
        }
    }

    private fun startAudioCapture() {
        audioRecord = AudioRecord(
            MediaRecorder.AudioSource.REMOTE_SUBMIX,
            sampleRate,
            channelConfig,
            audioFormat,
            bufferSize
        )

        isRecording = true
        val recordingFile = File(activity.cacheDir, "system_audio.wav")
        
        // Start a timer to stop recording after 10 seconds
        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
            if (isRecording) {
                stopRecording()
            }
        }, 10000) // 10 seconds
        
        thread {
            try {
                val buffer = ByteArray(bufferSize)
                audioRecord?.startRecording()

                FileOutputStream(recordingFile).use { output ->
                    // Write WAV header
                    writeWavHeader(output, sampleRate, 2, 16)

                    while (isRecording) {
                        val read = audioRecord?.read(buffer, 0, bufferSize) ?: 0
                        if (read > 0) {
                            output.write(buffer, 0, read)
                        }
                    }

                    // Update WAV header with final size
                    updateWavHeader(recordingFile)
                }

                activity.runOnUiThread {
                    channel?.invokeMethod("onRecordingComplete", recordingFile.absolutePath)
                }
            } catch (e: Exception) {
                activity.runOnUiThread {
                    channel?.invokeMethod("onRecordingError", e.message)
                }
            }
        }
    }

    fun stopRecording() {
        isRecording = false
        audioRecord?.stop()
        audioRecord?.release()
        mediaProjection?.stop()
    }

    private fun writeWavHeader(output: FileOutputStream, sampleRate: Int, channels: Int, bitsPerSample: Int) {
        output.write("RIFF".toByteArray())
        output.write(ByteArray(4)) // Size placeholder
        output.write("WAVE".toByteArray())
        output.write("fmt ".toByteArray())
        output.write(byteArrayOf(16, 0, 0, 0)) // Subchunk1Size
        output.write(byteArrayOf(1, 0)) // AudioFormat (PCM)
        output.write(byteArrayOf(channels.toByte(), 0)) // NumChannels
        output.write(intToByteArray(sampleRate)) // SampleRate
        output.write(intToByteArray(sampleRate * channels * bitsPerSample / 8)) // ByteRate
        output.write(byteArrayOf((channels * bitsPerSample / 8).toByte(), 0)) // BlockAlign
        output.write(byteArrayOf(bitsPerSample.toByte(), 0)) // BitsPerSample
        output.write("data".toByteArray())
        output.write(ByteArray(4)) // Subchunk2Size placeholder
    }

    private fun updateWavHeader(file: File) {
        val size = file.length()
        val raf = RandomAccessFile(file, "rw")
        
        // Update RIFF chunk size
        raf.seek(4L)
        raf.write(intToByteArray((size - 8).toInt()))
        
        // Update data chunk size
        raf.seek(40L)
        raf.write(intToByteArray((size - 44).toInt()))
        
        raf.close()
    }

    private fun intToByteArray(value: Int): ByteArray {
        return byteArrayOf(
            value.toByte(),
            (value shr 8).toByte(),
            (value shr 16).toByte(),
            (value shr 24).toByte()
        )
    }

    companion object {
        const val MEDIA_PROJECTION_REQUEST_CODE = 1000
    }
}
