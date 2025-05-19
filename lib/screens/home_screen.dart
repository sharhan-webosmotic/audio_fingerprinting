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



class HomeScreen extends StatefulWidget {
  const HomeScreen({Key? key}) : super(key: key);

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late StorageService _storageService;
  bool _isProcessing = false;
  List<Song> _storedSongs = [];
  String _processingStatus = '';
  final record = AudioRecorder();
  final systemRecorder = SystemAudioRecorder();
  bool _isRecording = false;
  bool _isSystemAudio = false;

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
            content: Text(
              matchResult['matched']
                ? 'Song: ${matchResult['songName']}\nConfidence: ${matchResult['confidence']}%'
                : 'No matching song found in the database.'
            ),
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
    setState(() {
      _isProcessing = true;
      _processingStatus = 'Recording system audio...';
      _isRecording = true;
    });

    try {
      // Setup system audio recorder callbacks
      systemRecorder.onRecordingComplete = (String path) {
        print('System audio recording complete: $path');
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
    } catch (e) {
      print('Error starting system audio recording: $e');
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
          content: Text(
            matchResult['matched']
              ? 'Song: ${matchResult['songName']}\nConfidence: ${matchResult['confidence']}%'
              : 'No matching song found in the database.'
          ),
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
        final config = RecordConfig(
          encoder: AudioEncoder.wav,  // WAV format for acoustid compatibility
          bitRate: 256000,  // Standard bitrate
          sampleRate: 44100,  // 44.1kHz - standard for audio fingerprinting
          numChannels: 1,  // Mono - better for fingerprinting algorithms
        );
        
        print('Starting recording...');
        await record.start(config, path: path);
        print('Recording started');

        print('Waiting for 8 seconds...');
        // Record for 12 seconds to get better fingerprint
        await Future.delayed(const Duration(seconds: 12));
        print('Stopping recording...');
        final recordedPath = await record.stop();
        print('Recording stopped');
        
        print('Recorded file path: $recordedPath');
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
          final matchResult = await _storageService.matchAudio(recordedPath);
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
              content: Text(
                matchResult['matched']
                  ? 'Song: ${matchResult['songName']}\nConfidence: ${matchResult['confidence']}%'
                  : 'No matching song found in the database.'
              ),
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
                    hintText: 'Enter the name of the song'
                  ),
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
      body: Column(
        children: [
          Expanded(
            child: _storedSongs.isEmpty
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
                              icon: Icon(Icons.play_arrow, color: Colors.white70),
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
          ),
          if (_isProcessing)
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  CircularProgressIndicator(
                    valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF6C63FF)),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _processingStatus,
                    style: TextStyle(color: Colors.white70),
                  ),
                ],
              ),
            ),
        ],
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Add song button
          Padding(
            padding: const EdgeInsets.only(right: 16.0),
            child: Align(
              alignment: Alignment.centerRight,
              child: FloatingActionButton(
                onPressed: _isProcessing ? null : _addNewSong,
                backgroundColor: Color(0xFF6C63FF),
                mini: true,
                child: const Icon(Icons.add, color: Colors.white),
                heroTag: 'add',
              ),
            ),
          ),
          const SizedBox(height: 16),
          // Upload button
          Padding(
            padding: const EdgeInsets.only(right: 16.0),
            child: Align(
              alignment: Alignment.centerRight,
              child: FloatingActionButton(
                onPressed: _isProcessing ? null : _uploadAndMatchFile,
                backgroundColor: Colors.blueGrey,
                mini: true,
                child: const Icon(Icons.upload_file, color: Colors.white),
                heroTag: 'upload',
              ),
            ),
          ),
          const SizedBox(height: 16),
          // Large recording button
          Center(
            child: GestureDetector(
              onTap: _isProcessing ? null : _startMatching,
              child: Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0xFF6C63FF),
                  boxShadow: [
                    BoxShadow(
                      color: Color(0xFF6C63FF).withOpacity(0.3),
                      blurRadius: 24,
                      spreadRadius: 4,
                    ),
                  ],
                ),
                child: _isProcessing
                  ? Center(
                      child: LoadingAnimationWidget.waveDots(
                        color: Colors.white,
                        size: 50,
                      ),
                    )
                  : const Icon(
                      Icons.mic,
                      color: Colors.white,
                      size: 48,
                    ),
              ),
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }

  @override
  void dispose() {
    record.dispose();
    super.dispose();
  }
}
