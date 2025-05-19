import 'package:flutter/services.dart';

class SystemAudioRecorder {
  static const MethodChannel _channel = MethodChannel('system_audio_recorder');
  Function(String)? onRecordingComplete;
  Function(String)? onRecordingError;

  SystemAudioRecorder() {
    _channel.setMethodCallHandler(_handleMethod);
  }

  Future<void> _handleMethod(MethodCall call) async {
    switch (call.method) {
      case 'onRecordingComplete':
        onRecordingComplete?.call(call.arguments as String);
        break;
      case 'onRecordingError':
        onRecordingError?.call(call.arguments as String);
        break;
    }
  }

  Future<void> startRecording() async {
    try {
      await _channel.invokeMethod('startRecording');
    } on PlatformException catch (e) {
      print('Failed to start recording: ${e.message}');
      onRecordingError?.call(e.message ?? 'Unknown error');
    }
  }

  Future<void> stopRecording() async {
    try {
      await _channel.invokeMethod('stopRecording');
    } on PlatformException catch (e) {
      print('Failed to stop recording: ${e.message}');
      onRecordingError?.call(e.message ?? 'Unknown error');
    }
  }
}
