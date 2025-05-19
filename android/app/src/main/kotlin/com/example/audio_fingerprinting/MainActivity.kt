package com.example.audio_fingerprinting

import android.os.Bundle

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.Intent

class MainActivity: FlutterActivity() {
    private val CHANNEL = "system_audio_recorder"
    private var systemAudioRecorder: SystemAudioRecorder? = null
    private var methodChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        systemAudioRecorder = SystemAudioRecorder(this, methodChannel!!)

        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "startRecording" -> {
                    systemAudioRecorder?.startRecording()
                    result.success(null)
                }
                "stopRecording" -> {
                    systemAudioRecorder?.stopRecording()
                    result.success(null)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == SystemAudioRecorder.MEDIA_PROJECTION_REQUEST_CODE) {
            systemAudioRecorder?.handleActivityResult(requestCode, resultCode, data)
        }
    }
}
