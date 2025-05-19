import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'system_audio_recorder.dart';
import 'package:record/record.dart'; // For microphone recording

class AudioRecorderWidget extends StatefulWidget {
  @override
  _AudioRecorderWidgetState createState() => _AudioRecorderWidgetState();
}

class _AudioRecorderWidgetState extends State<AudioRecorderWidget> {
  bool _isRecording = false;
  bool _isSystemAudio = false;
  String? _matchResult;
  int _remainingSeconds = 10;
  Timer? _timer;
  final SystemAudioRecorder _systemRecorder = SystemAudioRecorder();
  final _micRecorder = Record();
  
  @override
  void initState() {
    super.initState();
    _setupRecorders();
  }

  void _setupRecorders() {
    // Setup system audio recorder
    _systemRecorder.onRecordingComplete = (String path) {
      _sendRecordingToServer(File(path));
    };

    _systemRecorder.onRecordingError = (String error) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Recording error: $error')),
      );
    };
  }

  Future<void> _toggleRecording() async {
    if (_isRecording) {
      await _stopRecording();
    } else {
      await _startRecording();
    }
  }

  Future<void> _startRecording() async {
    try {
      if (_isSystemAudio) {
        await _systemRecorder.startRecording();
      } else {
        // Start microphone recording
        if (await _micRecorder.hasPermission()) {
          await _micRecorder.start(
            encoder: AudioEncoder.wav,
            samplingRate: 44100,
            numChannels: 2,
          );
        }
      }
      
      setState(() {
        _isRecording = true;
        _matchResult = null;
        _remainingSeconds = 10;
      });
      
      // Start countdown timer
      _timer = Timer.periodic(Duration(seconds: 1), (timer) {
        setState(() {
          if (_remainingSeconds > 0) {
            _remainingSeconds--;
          } else {
            _stopRecording();
            timer.cancel();
          }
        });
      });
    } catch (e) {
      print('Failed to start recording: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to start recording')),
      );
    }
  }

  Future<void> _stopRecording() async {
    try {
      if (_isSystemAudio) {
        await _systemRecorder.stopRecording();
      } else {
        // Stop microphone recording
        final path = await _micRecorder.stop();
        if (path != null) {
          await _sendRecordingToServer(File(path));
        }
      }
      
      _timer?.cancel();
      setState(() {
        _isRecording = false;
        _remainingSeconds = 10;
      });
    } catch (e) {
      print('Failed to stop recording: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to stop recording')),
      );
    }
  }

  Future<void> _sendRecordingToServer(File recordingFile) async {
    try {
      var uri = Uri.parse('http://your-server-url/match');
      var request = http.MultipartRequest('POST', uri)
        ..files.add(await http.MultipartFile.fromPath(
          'file',
          recordingFile.path,
          contentType: MediaType('audio', 'wav'),
        ));

      var response = await request.send();
      var responseBody = await response.stream.bytesToString();

      setState(() {
        _matchResult = responseBody;
      });
    } catch (e) {
      print('Failed to send recording: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to send recording to server')),
      );
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _micRecorder.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SwitchListTile(
          title: Text('Record System Audio'),
          subtitle: Text(_isSystemAudio 
            ? 'Recording audio playing on device' 
            : 'Recording from microphone'),
          value: _isSystemAudio,
          onChanged: (bool value) {
            setState(() {
              _isSystemAudio = value;
            });
          },
        ),
        ElevatedButton(
          onPressed: _toggleRecording,
          child: Text(_isRecording 
            ? 'Recording... $_remainingSeconds s' 
            : 'Start Recording'),
          style: ElevatedButton.styleFrom(
            backgroundColor: _isRecording ? Colors.red : Colors.blue,
            padding: EdgeInsets.symmetric(horizontal: 32, vertical: 16),
          ),
        ),
        if (_matchResult != null)
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text('Match Result: $_matchResult'),
          ),
      ],
    );
  }
}
