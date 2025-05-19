import 'dart:io';
import 'dart:math';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'dart:math' as math;
import 'api_service.dart';
import 'package:fftea/fftea.dart';

class AudioFingerprintService {
  late String _tempDir;
  bool _isRecording = false;
  String? _recordedAudioPath;
  final _record = AudioRecorder();

  // Audio processing constants
  static const int _sampleRate = 44100;    // Standard audio sample rate
  static const int _chunkSize = 2048;      // Larger window for better frequency resolution
  static const int _hopSize = 512;         // 75% overlap for better time resolution
  
  // Frequency bands (critical bands approximating human hearing)
  static const List<int> _bandEdges = [
    0,    100,  200,  300,  400,  510,  630,  770,  920,  1080,
    1270, 1480, 1720, 2000, 2320, 2700, 3150, 3700, 4400, 5300,
    6400, 7700, 9500, 12000, 15500
  ];
  
  // Peak detection parameters
  static const double _peakThreshold = 0.4;   // Higher threshold for stronger peaks
  static const int _minPeakSpacing = 12;      // More spacing between peaks
  static const int _targetZoneSize = 5;       // Number of points to pair with each anchor
  static const int _minFreqBin = 10;          // Skip very low frequencies (< ~215 Hz)
  static const double _noiseFloor = 0.1;      // Higher noise floor to filter weak signals

  AudioFingerprintService() {
    _initTempDir();
  }

  Future<void> _initTempDir() async {
    final dir = await getTemporaryDirectory();
    _tempDir = dir.path;
  }

  Future<String?> recordAudio({int seconds = 10}) async {
    
    final filePath = '$_tempDir/recording_${DateTime.now().millisecondsSinceEpoch}.wav';
    
    try {
      if (await _record.hasPermission()) {
        await _record.start(
          const RecordConfig(
            encoder: AudioEncoder.wav,
            sampleRate: _sampleRate,
            numChannels: 1,
          ),
          path: filePath,
        );
        
        await Future.delayed(Duration(seconds: seconds));
        await _record.stop();
        return filePath;
      }
    } catch (e) {
      print('Error recording audio: $e');
    }
    return null;
  }

  Future<String?> startRecording() async {
    if (_isRecording) return null;
    
    final tempDir = await getTemporaryDirectory();
    _isRecording = true;
    _recordedAudioPath = '${tempDir.path}/recorded_audio.wav';
    
    try {
      await _record.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: _sampleRate,
          numChannels: 1,
        ),
        path: _recordedAudioPath!,
      );
      return _recordedAudioPath!;
    } catch (e) {
      _isRecording = false;
      _recordedAudioPath = null;
      print('Error starting recording: $e');
      return null;
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

  final ApiService _apiService = ApiService();

  Future<List<Map<String, dynamic>>> generateFingerprint(String? audioPath) async {
    if (audioPath == null) {
      throw Exception('Audio path cannot be null');
    }

    try {
      final result = await _apiService.matchAudio(audioPath);
      
      // Convert backend response to our format
      return [{
        'match': result['match'],
        'song': result['song'],
        'confidence': result['confidence'],
      }];
    } catch (e) {
      print('Error matching audio: $e');
      rethrow;
    }
    final file = File(audioPath);
    if (!await file.exists()) {
      throw Exception('Audio file not found');
    }

    final bytes = await file.readAsBytes();
    final samples = List<double>.filled(bytes.length ~/ 2, 0);
    
    // Convert bytes to samples
    for (var i = 0; i < bytes.length - 1; i += 2) {
      final sample = bytes[i] | (bytes[i + 1] << 8);
      samples[i ~/ 2] = (sample < 32768 ? sample : sample - 65536) / 32768.0;
    }

    print('File size: ${bytes.length} bytes');
    print('Max sample value: ${samples.reduce(max).abs()}');

    final fft = FFT(_chunkSize);
    final window = List<double>.generate(_chunkSize, 
      (i) => 0.54 - 0.46 * cos(2 * pi * i / (_chunkSize - 1)));

    final fingerprints = <Map<String, dynamic>>[];
    final allPeaks = <Point<int>>[];
    var processedChunks = 0;
    
    // Process audio in overlapping chunks with adaptive window size
    var i = 0;
    while (i < samples.length - _chunkSize) {
      processedChunks++;
      
      // Check signal energy in current window
      var windowEnergy = 0.0;
      for (var j = 0; j < _chunkSize; j++) {
        windowEnergy += samples[i + j] * samples[i + j];
      }
      windowEnergy /= _chunkSize;
      
      // Skip low energy regions
      if (windowEnergy < 0.001) {
        i += _chunkSize;
        continue;
      }
      
      // Apply window function
      final chunk = List<double>.filled(_chunkSize, 0.0);
      
      // Copy samples and apply window
      for (var j = 0; j < _chunkSize; j++) {
        chunk[j] = samples[i + j] * window[j];
      }
      
      // Compute FFT
      final spectrum = fft.realFft(chunk);
      
      // Calculate magnitude spectrum with frequency weighting
      final magnitudes = List<double>.filled(_chunkSize ~/ 2, 0.0);
      var maxMagnitude = 0.0;
      
      for (var j = 1; j < _chunkSize ~/ 2; j++) {
        final re = spectrum[j * 2].x;
        final im = spectrum[j * 2 + 1].x;
        final freq = j * _sampleRate / _chunkSize;
        
        // Apply A-weighting to emphasize important frequencies
        final weight = _getFrequencyWeight(freq);
        magnitudes[j] = sqrt(re * re + im * im) * weight;
        maxMagnitude = max(maxMagnitude, magnitudes[j]);
      }
      
      // Normalize magnitudes
      if (maxMagnitude > 0) {
        for (var j = 0; j < magnitudes.length; j++) {
          magnitudes[j] /= maxMagnitude;
        }
      }
      
      // Find peaks in this chunk
      final peaks = _findPeaks(magnitudes, i ~/ _hopSize);
      
      // Only add strong peaks
      if (peaks.length >= 3) {
        allPeaks.addAll(peaks);
      }
      
      // Adaptive hop size based on signal characteristics
      final hopSize = peaks.isEmpty ? _chunkSize ~/ 2 : _hopSize;
      i += hopSize;
      
      if (processedChunks % 10 == 0) {
        print('Processing chunk $processedChunks of ${(samples.length - _chunkSize) ~/ _hopSize} (${peaks.length} peaks)');
      }
    }

    print('Total peaks found: ${allPeaks.length}');

    // Generate fingerprints from peak pairs
    for (var i = 0; i < allPeaks.length; i++) {
      final anchor = allPeaks[i];
      
      // Pair with nearby peaks
      for (var j = i + 1; j < min(i + _targetZoneSize + 1, allPeaks.length); j++) {
        final point = allPeaks[j];
        
        // Calculate time delta between peaks
        final timeDelta = point.y - anchor.y;
        
        // Only create fingerprints for peaks close enough in time
        if (timeDelta > 0 && timeDelta < 200) {
          final hash = _generateHash(anchor, point);
          
          fingerprints.add({
            'hash': hash,
            'offset': anchor.y
          });
        }
      }
    }

    print('Generated ${fingerprints.length} fingerprints');
    return fingerprints;
  }

  List<Point<int>> _findPeaks(List<double> magnitudes, int timeIndex) {
    final peaks = <Point<int>>[];
    final numBins = magnitudes.length ~/ 2;
    
    // Find the average magnitude for noise floor
    var avgMagnitude = 0.0;
    for (var i = _minFreqBin; i < numBins; i++) {
      avgMagnitude += magnitudes[i];
    }
    avgMagnitude /= (numBins - _minFreqBin);
    
    // Only process if signal is strong enough
    if (avgMagnitude < _noiseFloor) return peaks;
    
    // Find peaks in each critical band
    for (var bandIndex = 0; bandIndex < _bandEdges.length - 1; bandIndex++) {
      final lowFreq = _bandEdges[bandIndex];
      final highFreq = _bandEdges[bandIndex + 1];
      
      // Convert frequencies to FFT bins
      final lowBin = max<int>(_minFreqBin, (lowFreq * _chunkSize / _sampleRate).round());
      final highBin = min<int>(numBins - 1, (highFreq * _chunkSize / _sampleRate).round());
      
      // Find local maxima in this band
      for (var bin = lowBin + 2; bin < highBin - 2; bin++) {
        final magnitude = magnitudes[bin];
        
        // Must be above noise floor and threshold
        if (magnitude < avgMagnitude * 2 || magnitude < _peakThreshold) continue;
        
        // Must be local maximum
        if (magnitude <= magnitudes[bin - 2] || 
            magnitude <= magnitudes[bin - 1] ||
            magnitude <= magnitudes[bin + 1] ||
            magnitude <= magnitudes[bin + 2]) continue;
        
        // Check minimum spacing from other peaks
        var isFarEnough = true;
        for (final peak in peaks) {
          if ((bin - peak.x).abs() < _minPeakSpacing) {
            isFarEnough = false;
            break;
          }
        }
        
        if (isFarEnough) {
          peaks.add(Point(bin, timeIndex));
        }
      }
    }
    
    return peaks;
  }

  int _generateHash(Point<int> anchor, Point<int> point) {
    final anchorFreq = anchor.x;
    final pointFreq = point.x;
    final timeDelta = point.y - anchor.y;
    
    // Convert frequencies to bark scale (better matches human perception)
    final anchorBark = _freqToBark(anchorFreq * _sampleRate / _chunkSize);
    final pointBark = _freqToBark(pointFreq * _sampleRate / _chunkSize);
    
    // Calculate frequency ratio in bark scale
    final barkDiff = (pointBark - anchorBark).round();
    
    // Create hash combining:
    // - 12 bits: Anchor frequency (bark scale)
    // - 8 bits: Frequency difference (bark scale)
    // - 12 bits: Time delta (quantized)
    final hash = ((anchorBark.round() & 0xFFF) << 20) |
                ((barkDiff + 24 & 0xFF) << 12) |
                (timeDelta & 0xFFF);
    
    return hash;
  }

  double _freqToBark(double freq) {
    return 13 * atan(0.00076 * freq) + 3.5 * atan(pow(freq / 7500, 2));
  }

  double _getFrequencyWeight(double freq) {
    // Simplified A-weighting curve
    final f2 = freq * freq;
    final f4 = f2 * f2;
    return (12200 * 12200 * f4) / ((f2 + 20.6 * 20.6) * 
           sqrt((f2 + 107.7 * 107.7) * (f2 + 737.9 * 737.9)) * 
           (f2 + 12200 * 12200));
  }
}
