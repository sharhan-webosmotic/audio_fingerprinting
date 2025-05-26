package com.example.audio_fingerprinting

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    companion object {
        private const val TAG = "MainActivity"
    }

    private lateinit var methodChannel: MethodChannel
    private lateinit var systemAudioRecorder: SystemAudioRecorder
    private val CHANNEL = "system_audio_recorder"
    private val PERMISSION_REQUEST_CODE = 123
    private val MEDIA_PROJECTION_REQUEST_CODE = 456
    private var pendingResult: MethodChannel.Result? = null
    private lateinit var mediaProjectionManager: MediaProjectionManager
    private var recordingService: RecordingService? = null
    private val serviceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
            val binder = service as RecordingService.LocalBinder
            recordingService = binder.getService()
            Log.d(TAG, "Service connected")
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            recordingService = null
            Log.d(TAG, "Service disconnected")
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        mediaProjectionManager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        systemAudioRecorder = SystemAudioRecorder(this, methodChannel)

        // Start and bind to the recording service
        Intent(this, RecordingService::class.java).also { intent ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
            bindService(intent, serviceConnection, Context.BIND_AUTO_CREATE)
        }

        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "startRecording" -> {
                    pendingResult = result
                    startRecordingWithPermissions()
                }
                "stopRecording" -> {
                    recordingService?.stopRecording()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun startRecordingWithPermissions() {
        if (checkAndRequestPermissions()) {
            if (recordingService == null) {
                Log.e(TAG, "Recording service not bound yet")
                pendingResult?.error("SERVICE_ERROR", "Recording service not ready", null)
                return
            }
            startActivityForResult(
                mediaProjectionManager.createScreenCaptureIntent(),
                MEDIA_PROJECTION_REQUEST_CODE
            )
        }
    }

    private fun checkAndRequestPermissions(): Boolean {
        val permissions = mutableListOf(
            Manifest.permission.RECORD_AUDIO,
            Manifest.permission.MODIFY_AUDIO_SETTINGS,
            Manifest.permission.READ_EXTERNAL_STORAGE,
            Manifest.permission.WRITE_EXTERNAL_STORAGE
        )

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            permissions.add(Manifest.permission.FOREGROUND_SERVICE)
        }

        val notGrantedPermissions = permissions.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }

        return if (notGrantedPermissions.isNotEmpty()) {
            ActivityCompat.requestPermissions(
                this,
                notGrantedPermissions.toTypedArray(),
                PERMISSION_REQUEST_CODE
            )
            false
        } else {
            true
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == PERMISSION_REQUEST_CODE) {
            if (grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }) {
                startActivityForResult(
                    mediaProjectionManager.createScreenCaptureIntent(),
                    MEDIA_PROJECTION_REQUEST_CODE
                )
            } else {
                pendingResult?.error("PERMISSION_DENIED", "Audio recording permission denied", null)
                pendingResult = null
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        unbindService(serviceConnection)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == MEDIA_PROJECTION_REQUEST_CODE) {
            try {
                if (resultCode == RESULT_OK && data != null) {
                    Log.d(TAG, "Media projection permission granted")
                    val mediaProjection = mediaProjectionManager.getMediaProjection(resultCode, data)
                    if (mediaProjection != null) {
                        recordingService?.startRecording(mediaProjection, systemAudioRecorder)
                        pendingResult?.success(null)
                    } else {
                        throw Exception("Failed to create media projection")
                    }
                } else {
                    Log.e(TAG, "Media projection permission denied or cancelled")
                    pendingResult?.error("PERMISSION_DENIED", "Media projection permission denied", null)
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error starting recording: ${e.message}")
                pendingResult?.error("RECORDING_ERROR", "Failed to start recording: ${e.message}", null)
            } finally {
                pendingResult = null
            }
        }
    }
}
