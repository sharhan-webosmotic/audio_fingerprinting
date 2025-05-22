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
  double _currentAmplitude = 0.0;
  bool _isAudioLevelGood = false;
  Timer? _amplitudeTimer;
  final SystemAudioRecorder _systemRecorder = SystemAudioRecorder();
  final record = AudioRecorder();

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
        if (await record.hasPermission()) {
          // await record.start(
          //   encoder: AudioEncoder.wav,
          //   samplingRate: 22050, // Match fingerprinting sample rate
          //   numChannels: 1, // Mono recording
          //   bitRate: 256000, // Higher bitrate for better quality
          // );

          // Start amplitude monitoring
          _amplitudeTimer =
              Timer.periodic(Duration(milliseconds: 200), (_) async {
            final amplitude = await _micRecorder.getAmplitude();
            setState(() {
              _currentAmplitude = amplitude.current;
              _isAudioLevelGood = amplitude.current > 0.1;
            });
          });
        }
      }

      setState(() {
        _isRecording = true;
        _matchResult = null;
        _remainingSeconds = 10; // Reset to 10 seconds
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
      _amplitudeTimer?.cancel();
      setState(() {
        _isRecording = false;
        _remainingSeconds = 10;
        _currentAmplitude = 0.0;
        _isAudioLevelGood = false;
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
        ))
        ..headers.addAll({
          'x-recording-type': 'live',
          'x-sample-rate': '22050',
          'x-channels': '1'
        });

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
    _amplitudeTimer?.cancel();
    _micRecorder.dispose();
    super.dispose();
  }

  Widget _buildVolumeIndicator() {
    return Container(
      height: 60,
      padding: EdgeInsets.all(8),
      child: Column(children: [
        LinearProgressIndicator(
          value: _currentAmplitude,
          backgroundColor: Colors.grey[300],
          valueColor: AlwaysStoppedAnimation<Color>(
            _isAudioLevelGood ? Colors.green : Colors.orange,
          ),
        ),
        SizedBox(height: 4),
        Text(
          _isAudioLevelGood ? 'Good Audio Level' : 'Speak Louder',
          style: TextStyle(
              color: _isAudioLevelGood ? Colors.green : Colors.orange),
        ),
      ]),
    );
  }

  Widget _buildQualityGuide() {
    return Padding(
      padding: EdgeInsets.all(8),
      child: Card(
        child: Padding(
          padding: EdgeInsets.all(8),
          child: Column(children: [
            Text('Tips for Better Recording:',
                style: TextStyle(fontWeight: FontWeight.bold)),
            Text('• Hold phone close to audio source'),
            Text('• Avoid noisy environments'),
            Text('• Keep phone steady while recording'),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (!_isSystemAudio) _buildVolumeIndicator(),
        if (!_isSystemAudio && !_isRecording) _buildQualityGuide(),
        SwitchListTile(
          title: Text('Record System Audio'),
          subtitle: Text(_isSystemAudio
              ? 'Recording audio playing on device'
              : 'Recording from microphone'),
          value: _isSystemAudio,
          onChanged: _isRecording
              ? null
              : (bool value) {
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
