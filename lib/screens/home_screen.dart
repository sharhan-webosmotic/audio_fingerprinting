import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:loading_animation_widget/loading_animation_widget.dart';
import 'package:path_provider/path_provider.dart';
import '../services/storage_service.dart';
import 'package:record/record.dart';
import '../models/song.dart';
import 'package:file_picker/file_picker.dart';
import '../system_audio_recorder.dart';
import 'package:just_audio/just_audio.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({Key? key}) : super(key: key);

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  AudioPlayer? player;
  late StorageService _storageService;
  bool _isProcessing = false;
  List<Song> _storedSongs = [];
  String _processingStatus = '';
  String? _lastOriginalAudioUrl;
  String? _lastProcessedAudioUrl;
  String? _lastRecordedPath; // Store the path of recorded audio
  final record = AudioRecorder();
  final systemRecorder = SystemAudioRecorder();
  bool _isRecording = false;
  bool _isSystemAudio = false;

  Future<void> _playOriginalAudio() async {
    if (_lastOriginalAudioUrl == null) {
      print('No original audio available');
      return;
    }

    try {
      print('Playing original audio from: $_lastOriginalAudioUrl');
      await player?.stop();

      final audioPlayer = AudioPlayer();
      player = audioPlayer;

      await audioPlayer.setUrl(_lastOriginalAudioUrl!);
      await audioPlayer.play();
    } catch (e) {
      print('Error playing original audio: $e');
    }
  }

  Future<void> _playProcessedAudio() async {
    if (_lastProcessedAudioUrl == null) {
      print('No processed audio available');
      return;
    }

    try {
      print('Playing processed audio from: $_lastProcessedAudioUrl');
      await player?.stop();

      final audioPlayer = AudioPlayer();
      player = audioPlayer;

      await audioPlayer.setUrl(_lastProcessedAudioUrl!);
      await audioPlayer.play();
    } catch (e) {
      print('Error playing processed audio: $e');
    }
  }

  Future<void> _playRecordedAudio() async {
    if (_lastRecordedPath == null) {
      print('No recorded audio available');
      return;
    }

    try {
      print('Playing recorded audio from: $_lastRecordedPath');
      // Stop any existing playback
      await player?.stop();

      // Create new player instance
      final audioPlayer = AudioPlayer();
      player = audioPlayer;

      await audioPlayer.setFilePath(_lastRecordedPath!);
      await audioPlayer.play();
    } catch (e) {
      print('Error playing audio: $e');
    }
  }

  Future<void> _uploadAndMatchFile() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['wav', 'mp3', 'm4a', 'ogg'],
      );

      if (result != null && result.files.single.path != null) {
        setState(() {
          _isProcessing = true;
          _processingStatus = 'Uploading and matching...';
        });

        final filePath = result.files.single.path!;
        final matchResult = await _storageService.matchAudio(filePath);
        print(matchResult);
        setState(() {
          _processingStatus = matchResult['matched']
              ? 'Match found! ${matchResult['songName']} (${matchResult['confidence']}% confidence)'
              : 'No match found';
        });

        // Show alert with match result
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(matchResult['matched'] ? 'Match Found!' : 'No Match'),
            content: Text(matchResult['matched']
                ? 'Song: ${matchResult['songName']}\nConfidence: ${matchResult['confidence']}%'
                : 'No matching song found in the database.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      print('Error uploading file: $e');
      setState(() {
        _processingStatus = 'Error: $e';
      });
    } finally {
      setState(() {
        _isProcessing = false;
      });
    }
  }

  Future<void> _startSystemAudioRecording() async {
    // Start recording
    setState(() {
      _isProcessing = true;
      _processingStatus = 'Recording system audio...';
      _isRecording = true;
    });

    try {
      // Setup system audio recorder callbacks
      systemRecorder.onRecordingComplete = (String path) {
        print('System audio recording complete: $path');
        setState(() {
          _isRecording = false;
          _isProcessing = false;
          _lastRecordedPath = path;
          _processingStatus = 'Recording saved to: $path';
        });
        _processRecordedAudio(path);
      };

      systemRecorder.onRecordingError = (String error) {
        print('System audio recording error: $error');
        setState(() {
          _isProcessing = false;
          _isRecording = false;
          _processingStatus = 'Recording error: $error';
        });
      };

      // Start recording
      await systemRecorder.startRecording();

      // Stop recording after 12 seconds
      await Future.delayed(const Duration(seconds: 12));
      if (_isRecording) {
        setState(() {
          _processingStatus = 'Stopping recording...';
        });
        await systemRecorder.stopRecording();
      }
    } catch (e) {
      print('Error with system audio recording: $e');
      setState(() {
        _isProcessing = false;
        _isRecording = false;
        _processingStatus = 'Error: $e';
      });
    }
  }

  Future<void> _processRecordedAudio(String path) async {
    try {
      final matchResult = await _storageService.matchAudio(path);
      print(matchResult);
      setState(() {
        _processingStatus = matchResult['matched']
            ? 'Match found! ${matchResult['songName']} (${matchResult['confidence']}% confidence)'
            : 'No match found';
      });

      // Show alert with match result
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(matchResult['matched'] ? 'Match Found!' : 'No Match'),
          content: Text(matchResult['matched']
              ? 'Song: ${matchResult['songName']}\nConfidence: ${matchResult['confidence']}%'
              : 'No matching song found in the database.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } catch (e) {
      print('Error processing recording: $e');
      setState(() {
        _processingStatus = 'Error: $e';
      });
    } finally {
      setState(() {
        _isProcessing = false;
        _isRecording = false;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _initializeServices();
  }

  Future<void> _initializeServices() async {
    _storageService = await StorageService.create();
    await _loadSongs();
  }

  Future<void> _loadSongs() async {
    final songs = await _storageService.getSongs();
    setState(() {
      _storedSongs = songs;
    });
    print('Loaded ${songs.length} songs');
  }

  Future<void> _startMatching() async {
    try {
      if (_isSystemAudio) {
        await _startSystemAudioRecording();
        return;
      }

      print('Checking microphone permission...');
      if (await record.hasPermission()) {
        print('Permission granted');
        setState(() {
          _isProcessing = true;
          _processingStatus = 'Recording...';
        });

        final tempDir = await getTemporaryDirectory();
        final path = '${tempDir.path}/recorded_audio.wav';
        print('Will save recording to: $path');

        setState(() {
          _isRecording = true;
          _processingStatus = 'Recording... Please play music';
        });

        print('Configuring recorder...');
        // Use high-quality WAV format for better fingerprinting
        const config = RecordConfig(
          encoder: AudioEncoder.wav,
          bitRate: 256000,
          sampleRate: 22050, // Match server's sample rate
          numChannels: 1, // Mono for fingerprinting
        );

        print('Starting recording...');
        await record.start(config, path: path);
        print('Recording started');

        print('Waiting for 8 seconds...');
        // Record for 12 seconds to get better fingerprint
        await Future.delayed(const Duration(seconds: 15));
        print('Stopping recording...');
        final recordedPath = await record.stop();
        print('Recording stopped');
        print('Recorded file path: $recordedPath');

        // Save the recorded path to play later
        setState(() {
          _lastRecordedPath = recordedPath;
        });

        // Set the audio URLs
        // setState(() {
        //   _lastOriginalAudioUrl = 'http://10.0.1.46:3000/original-audio';
        //   _lastProcessedAudioUrl = 'http://10.0.1.46:3000/processed-audio';
        // });
        if (recordedPath != null) {
          final file = File(recordedPath);
          final exists = await file.exists();
          final size = exists ? await file.length() : 0;
          print('File exists: $exists, size: $size bytes');

          if (!exists || size == 0) {
            print('Error: Recording file is empty or does not exist');
            setState(() {
              _processingStatus = 'Error: Recording failed';
            });
            return;
          }
          setState(() {
            _processingStatus = 'Processing audio...';
          });

          print('Sending file for matching...');
          final matchResult =
              await _storageService.matchAudio(recordedPath, isLive: true);
          print('Match result: $matchResult');

          setState(() {
            _processingStatus = matchResult['matched']
                ? 'Match found! ${matchResult['song']} (${matchResult['confidence']}% confidence)'
                : matchResult['error'] != null
                    ? 'Error: ${matchResult['error']}'
                    : 'No match found';
          });

          // Show alert dialog with match result
          showDialog(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(matchResult['matched'] ? 'Match Found!' : 'No Match'),
              content: Text(matchResult['matched']
                  ? 'Song: ${matchResult['songName']}\nConfidence: ${matchResult['confidence']}%'
                  : 'No matching song found in the database.'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('OK'),
                ),
              ],
            ),
          );

          if (matchResult['matched']) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Matched: ${matchResult['songName']}')),
            );
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('No match found')),
            );
          }
        }
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error matching audio: $e')),
      );
    } finally {
      setState(() {
        _isProcessing = false;
      });
    }
  }

  Future<void> _addNewSong() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['mp3', 'wav', 'm4a', 'ogg'],
        allowMultiple: false,
      );

      if (result != null && result.files.isNotEmpty) {
        final file = result.files.first;
        if (file.path != null) {
          setState(() {
            _isProcessing = true;
            _processingStatus = 'Adding song...';
          });

          String? songName;
          await showDialog<void>(
            context: context,
            builder: (context) {
              final controller = TextEditingController();
              return AlertDialog(
                title: const Text('Enter Song Name'),
                content: TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: const InputDecoration(
                      hintText: 'Enter the name of the song'),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  TextButton(
                    onPressed: () {
                      songName = controller.text;
                      Navigator.pop(context);
                    },
                    child: const Text('Add'),
                  ),
                ],
              );
            },
          );

          if (songName?.isNotEmpty == true) {
            final addedSong = await _storageService.addSong(
              file.path!,
              songName!,
            );

            if (addedSong != null) {
              await _loadSongs();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Song added successfully')),
              );
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Failed to add song')),
              );
            }
          }
        }
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error adding song: $e')),
      );
    } finally {
      setState(() {
        _isProcessing = false;
        _processingStatus = '';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Color(0xFF1A1A1A),
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text(
          'Audio Fingerprinting',
          style: TextStyle(color: Colors.white),
        ),
        actions: [
          // Add the system audio toggle switch in the app bar
          Row(
            children: [
              Text(
                'System Audio',
                style: TextStyle(color: Colors.white70),
              ),
              Switch(
                value: _isSystemAudio,
                onChanged: (value) {
                  setState(() {
                    _isSystemAudio = value;
                  });
                },
                activeColor: Color(0xFF6C63FF),
              ),
            ],
          ),
        ],
      ),
      body: Stack(
        children: [
          // Main content
          _storedSongs.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.music_off,
                        size: 64,
                        color: Color(0xFF6C63FF).withOpacity(0.5),
                      ),
                      SizedBox(height: 16),
                      Text(
                        'No songs in library',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.7),
                          fontSize: 18,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: _storedSongs.length,
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  itemBuilder: (context, index) {
                    final song = _storedSongs[index];
                    return Container(
                      margin: EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: Color(0xFF2D2D2D),
                        borderRadius: BorderRadius.circular(15),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.2),
                            blurRadius: 8,
                            offset: Offset(0, 4),
                          ),
                        ],
                      ),
                      child: ListTile(
                        leading: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Color(0xFF6C63FF).withOpacity(0.2),
                          ),
                          child: Icon(Icons.music_note, color: Colors.white70),
                        ),
                        title: Text(
                          song.name,
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        subtitle: Text(
                          song.duration.toString(),
                          style: TextStyle(color: Colors.white70),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon:
                                  Icon(Icons.play_arrow, color: Colors.white70),
                              onPressed: () => {},
                            ),
                            IconButton(
                              icon: Icon(Icons.delete, color: Colors.white70),
                              onPressed: () => {},
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
          // Loading overlay
          if (_isProcessing)
            Container(
              color: Colors.black.withOpacity(0.5),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(
                      valueColor:
                          AlwaysStoppedAnimation<Color>(Color(0xFF6C63FF)),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _processingStatus,
                      style: TextStyle(color: Colors.white70),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Add song button
            FloatingActionButton(
              onPressed: _isProcessing ? null : _addNewSong,
              backgroundColor: const Color(0xFF6C63FF),
              mini: true,
              child: const Icon(Icons.add, color: Colors.white),
              heroTag: 'add',
            ),
            const SizedBox(height: 16),
            // Audio playback buttons (if available)
            if (_lastOriginalAudioUrl != null && _lastProcessedAudioUrl != null)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FloatingActionButton(
                    onPressed: _playOriginalAudio,
                    backgroundColor: const Color(0xFF6C63FF),
                    mini: true,
                    child: const Icon(Icons.music_note, color: Colors.white),
                    heroTag: 'original',
                  ),
                  const SizedBox(width: 8),
                  FloatingActionButton(
                    onPressed: _playProcessedAudio,
                    backgroundColor: const Color(0xFF6C63FF),
                    mini: true,
                    child: const Icon(Icons.graphic_eq, color: Colors.white),
                    heroTag: 'processed',
                  ),
                ],
              ),
            const SizedBox(height: 16),
            // Upload button
            FloatingActionButton(
              onPressed: _isProcessing ? null : _uploadAndMatchFile,
              backgroundColor: Colors.blueGrey,
              mini: true,
              child: const Icon(Icons.upload_file, color: Colors.white),
              heroTag: 'upload',
            ),
            const SizedBox(height: 16),
            // System audio recording button (Shazam-like)
            FloatingActionButton(
              onPressed: _isProcessing ? null : _startSystemAudioRecording,
              backgroundColor: Colors.orange,
              child: _isRecording
                  ? const Icon(Icons.stop, color: Colors.white)
                  : const Icon(Icons.speaker, color: Colors.white),
              tooltip: 'Record System Audio',
              heroTag: 'system',
            ),
            const SizedBox(height: 16),
            // Microphone recording button
            FloatingActionButton(
              onPressed: _isProcessing ? null : _startMatching,
              backgroundColor: const Color(0xFF6C63FF),
              child: _isRecording
                  ? const Icon(Icons.stop, color: Colors.white)
                  : const Icon(Icons.mic, color: Colors.white),
              tooltip: 'Start Recording',
              heroTag: 'mic',
            ),
          ],
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
    );
  }

  Future<void> _playAudio(String url) async {
    AudioPlayer? player;
    try {
      print('Playing audio from URL: $url');
      player = AudioPlayer();

      // Set a listener for player state changes
      player.playerStateStream.listen((state) {
        print(
            'Player state changed: ${state.processingState} - playing: ${state.playing}');
      });

      // Set a listener for errors
      player.playbackEventStream.listen(
        (event) => print('Playback event: $event'),
        onError: (Object e, StackTrace st) {
          print('A stream error occurred: $e');
        },
      );

      // Set a listener for position updates
      player.positionStream.listen(
        (position) => print('Current position: ${position.inSeconds}s'),
        onError: (Object e, StackTrace st) {
          print('Position stream error: $e');
        },
      );

      print('Setting URL...');
      await player.setUrl(url);
      print('URL set, starting playback...');
      await player.play();
      print('Playback started');

      // Wait for playback to complete
      await player.processingStateStream.firstWhere(
        (state) => state == ProcessingState.completed,
      );
      print('Playback completed');
    } catch (e, st) {
      print('Error playing audio: $e');
      print('Stack trace: $st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error playing audio: $e')),
        );
      }
    } finally {
      await player?.dispose();
    }
  }

  @override
  void dispose() {
    record.dispose();
    super.dispose();
  }
}
