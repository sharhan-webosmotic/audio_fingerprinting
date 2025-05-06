import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:fftea/fftea.dart';

class Complex {
  final double x;
  final double y;
  Complex(this.x, this.y);
}

class AudioFingerprintService {
  final _record = AudioRecorder();
  late final String _tempDir;
  bool _isRecording = false;
  String? _recordedAudioPath;
  
  // Optimized audio settings
  static const int _sampleRate = 44100;  // Standard audio sample rate
  static const int _chunkSize = 2048;    // Good balance for FFT
  static const int _hopSize = 512;       // 75% overlap
  static const double _peakThreshold = 0.3;  // Adjusted threshold
  static const int _fanout = 15;
  static const int _minPeaks = 3;  // Minimum peaks needed to generate fingerprints
  static const int _targetZoneSize = 5; // Number of points to pair with each anchor
  
  AudioFingerprintService() {
    _initTempDir();
  }

  Future<void> _initTempDir() async {
    final dir = await getTemporaryDirectory();
    _tempDir = dir.path;
  }

  Future<String> recordAudio({int seconds = 10}) async {
    final filePath = '$_tempDir/recording_${DateTime.now().millisecondsSinceEpoch}.wav';
    
    if (await _record.hasPermission()) {
      try {
        // Configure higher quality recording
        await _record.start(
          RecordConfig(
            encoder: AudioEncoder.wav,
            sampleRate: _sampleRate,
            numChannels: 1,
            bitRate: 256000, // Higher bitrate
            autoGain: true, // Enable auto gain
          ),
          path: filePath,
        );
        
        await Future.delayed(Duration(seconds: seconds));
        await _record.stop();
        
        // Verify the recorded file
        final file = File(filePath);
        if (await file.exists()) {
          final size = await file.length();
          print('Recording saved: $filePath (${size ~/ 1024} KB)');
          return filePath;
        } else {
          throw Exception('Recording file not created');
        }
      } catch (e) {
        print('Recording error: $e');
        rethrow;
      }
    }
    throw Exception('Microphone permission not granted');
  }

  Future<String> startRecording() async {
    _isRecording = true;
    final tempDir = await getTemporaryDirectory();
    _recordedAudioPath = '${tempDir.path}/recorded_audio.wav';
    
    try {
      await _record.start(
        RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: _sampleRate,
          numChannels: 1,
          bitRate: 256000, // Higher bitrate
          autoGain: true, // Enable auto gain
        ),
        path: _recordedAudioPath!,
      );
      return _recordedAudioPath!;
    } catch (e) {
      print('Error starting recording: $e');
      rethrow;
    }
  }

  Future<String?> stopRecording() async {
    if (!_isRecording) return null;
    
    try {
      await _record.stop();
      _isRecording = false;
      return _recordedAudioPath;
    } catch (e) {
      print('Error stopping recording: $e');
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> generateFingerprint(String audioPath) async {
    final file = File(audioPath);
    final bytes = await file.readAsBytes();
    
    print('File size: ${bytes.length} bytes');
    
    // Convert to mono 16-bit PCM
    List<double> samples = [];
    double maxSample = 0.0;
    
    // Skip WAV header
    for (int i = 44; i < bytes.length - 1; i += 2) {
      final int sample = bytes[i] | (bytes[i + 1] << 8);
      final double signedSample = (sample > 32767 ? sample - 65536 : sample).toDouble();
      maxSample = max(maxSample, signedSample.abs());
      samples.add(signedSample);
    }
    
    print('Max sample value: $maxSample');
    
    // Normalize samples
    if (maxSample > 0) {
      for (int i = 0; i < samples.length; i++) {
        samples[i] = samples[i] / maxSample;
      }
    }

    final fingerprints = <Map<String, dynamic>>[];
    final fft = FFT(_chunkSize);
    final window = List<double>.generate(_chunkSize, 
      (i) => 0.54 - 0.46 * cos(2 * pi * i / (_chunkSize - 1)));

    int totalPeaks = 0;
    int processedChunks = 0;
    
    // Store all peaks first
    final allPeaks = <Point<int>>[];

    // Process chunks
    for (var i = 0; i < samples.length - _chunkSize; i += _hopSize) {
      processedChunks++;
      
      // Apply window and prepare samples
      final chunk = List<double>.filled(_chunkSize, 0.0);
      double maxChunkValue = 0.0;
      
      for (var j = 0; j < _chunkSize; j++) {
        if (i + j < samples.length) {
          chunk[j] = samples[i + j] * window[j];
          maxChunkValue = max(maxChunkValue, chunk[j].abs());
        }
      }
      
      // Skip silent chunks
      if (maxChunkValue < 0.001) continue;

      // Compute FFT
      final spectrum = fft.realFft(chunk);
      final magnitudes = List<double>.filled(_chunkSize ~/ 2, 0.0);
      
      // Convert to magnitudes
      double maxMagnitude = 0.0;
      for (var j = 1; j < _chunkSize ~/ 2; j++) {
        final real = spectrum[j * 2].x;
        final imag = spectrum[j * 2 + 1].x;
        magnitudes[j] = sqrt(real * real + imag * imag);
        maxMagnitude = max(maxMagnitude, magnitudes[j]);
      }

      // Skip if no significant frequencies
      if (maxMagnitude < 0.001) continue;

      // Normalize magnitudes
      for (var j = 0; j < magnitudes.length; j++) {
        magnitudes[j] /= maxMagnitude;
      }

      // Find peaks
      final peaks = <Point<int>>[];
      for (var j = 2; j < magnitudes.length - 2; j++) {
        if (magnitudes[j] > _peakThreshold &&
            magnitudes[j] > magnitudes[j - 1] * 1.1 &&
            magnitudes[j] > magnitudes[j - 2] * 1.1 &&
            magnitudes[j] > magnitudes[j + 1] * 1.1 &&
            magnitudes[j] > magnitudes[j + 2] * 1.1) {
          final timePoint = i ~/ _hopSize;
          peaks.add(Point(j, timePoint));
          allPeaks.add(Point(j, timePoint));
        }
      }

      totalPeaks += peaks.length;

      // Print progress every 10 chunks
      if (processedChunks % 10 == 0) {
        print('Processing chunk $processedChunks of ${(samples.length - _chunkSize) ~/ _hopSize} (${peaks.length} peaks)');
      }
    }

    print('Total peaks found: $totalPeaks');

    // Generate fingerprints from all peaks
    if (allPeaks.length >= _minPeaks) {
      // Sort peaks by time for efficient pairing
      allPeaks.sort((a, b) => a.y.compareTo(b.y));
      
      // Use each peak as an anchor and pair with subsequent peaks
      for (var i = 0; i < allPeaks.length; i++) {
        final anchor = allPeaks[i];
        final anchorTime = anchor.y;
        
        // Look ahead for target zone
        for (var j = i + 1; j < min(i + _targetZoneSize + 1, allPeaks.length); j++) {
          final point = allPeaks[j];
          final timeDelta = point.y - anchorTime;
          
          // Only create hash if points are close enough in time
          if (timeDelta > 0 && timeDelta < 200) {
            final hash = ((anchor.x & 0x7FF) << 20) | 
                       ((point.x & 0x7FF) << 9) | 
                       (timeDelta & 0x1FF);
            
            fingerprints.add({
              'hash': hash,
              'offset': anchorTime
            });
          }
        }
      }
    }

    print('Generated ${fingerprints.length} fingerprints');
    return fingerprints;
  }
}
