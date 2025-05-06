import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'dart:math';
import '../services/audio_fingerprint_service.dart';
import '../services/storage_service.dart';
import '../models/song.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late StorageService _storageService;
  late AudioFingerprintService _fingerprintService;
  late AudioPlayer _audioPlayer;
  bool _isProcessing = false;
  bool _isPlaying = false;
  String? _currentlyPlayingSongId;
  String? _recordedAudioPath;
  List<Song> _storedSongs = [];
  List<Song> _matchedSongs = [];
  String _processingStatus = '';

  @override
  void initState() {
    super.initState();
    _initializeServices();
  }

  Future<void> _initializeServices() async {
    _audioPlayer = AudioPlayer();
    _fingerprintService = AudioFingerprintService();
    _storageService = await StorageService.create();
    await _loadSongs();
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    super.dispose();
  }

  void _setupAudioPlayer() {
    _audioPlayer.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        setState(() {
          _isPlaying = false;
          _currentlyPlayingSongId = null;
        });
      }
    });
  }

  Future<void> _loadSongs() async {
    final songs = await _storageService.getAllSongs();
    setState(() {
      _storedSongs = songs;
    });
    print('Loaded ${songs.length} stored songs');
  }

  Future<void> _playStoredSong(Song song) async {
    if (song.audioPath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No audio file available for this song')),
      );
      return;
    }

    try {
      if (_isPlaying && _currentlyPlayingSongId == song.id) {
        await _audioPlayer.stop();
        setState(() {
          _isPlaying = false;
          _currentlyPlayingSongId = null;
        });
      } else {
        if (_isPlaying) {
          await _audioPlayer.stop();
        }
        setState(() {
          _isPlaying = true;
          _currentlyPlayingSongId = song.id;
        });
        await _audioPlayer.setFilePath(song.audioPath!);
        await _audioPlayer.play();
      }
    } catch (e) {
      print('Error playing stored song: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error playing audio: $e')),
      );
      setState(() {
        _isPlaying = false;
        _currentlyPlayingSongId = null;
      });
    }
  }

  Future<void> _deleteSong(Song song) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Song'),
        content: Text('Are you sure you want to delete "${song.title}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await _storageService.deleteSong(song.id);
        await _loadSongs(); // Reload the list
        
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Song deleted successfully')),
        );
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error deleting song: $e')),
        );
      }
    }
  }

  Future<void> _startRecording() async {
    setState(() {
      _isProcessing = true;
      _recordedAudioPath = null;
    });

    try {
      final audioPath = await _fingerprintService.recordAudio(seconds: 10);
      _recordedAudioPath = audioPath;
      print('Recording saved to: $audioPath');
      
      // Auto identify after recording
      if (audioPath != null) {
        await _identifySong(audioPath);
      }
    } catch (e) {
      setState(() {
        _recordedAudioPath = null;
      });
    } finally {
      setState(() {
        _isProcessing = false;
      });
    }
  }

  Future<void> _stopRecording() async {
    setState(() {
      _isProcessing = true;
      _processingStatus = 'Stopping recording...';
    });

    try {
      final path = await _fingerprintService.stopRecording();
      if (path != null) {
        setState(() {
          _recordedAudioPath = path;
          _processingStatus = 'Processing audio...';
        });
        
        // Automatically identify song after recording stops
        await _identifySong(path);
      } else {
        setState(() {
          _processingStatus = 'Error: Failed to save recording';
        });
      }
    } catch (e) {
      print('Error stopping recording: $e');
      setState(() {
        _processingStatus = 'Error: $e';
      });
    } finally {
      setState(() {
        _isProcessing = false;
      });
    }
  }

  Future<void> _togglePlayback() async {
    if (_recordedAudioPath == null) return;

    try {
      if (_isPlaying) {
        await _audioPlayer.stop();
        setState(() {
          _isPlaying = false;
          _currentlyPlayingSongId = null;
        });
      } else {
        setState(() {
          _isPlaying = true;
        });
        await _audioPlayer.setFilePath(_recordedAudioPath!);
        await _audioPlayer.play();
      }
    } catch (e) {
      print('Error playing audio: $e');
      setState(() {
        _isPlaying = false;
        _currentlyPlayingSongId = null;
      });
    }
  }

  Future<void> _identifySong(String audioPath) async {
    setState(() {
      _isProcessing = true;
      _processingStatus = 'Analyzing audio...';
      _matchedSongs = [];
    });

    try {
      // Generate fingerprints
      final fingerprints = await _fingerprintService.generateFingerprint(audioPath);
      
      setState(() {
        _processingStatus = 'Matching fingerprints...';
      });

      // Find matches
      final matches = await _storageService.findMatches(fingerprints);
      
      setState(() {
        _matchedSongs = matches;
        _processingStatus = matches.isEmpty ? 'No matches found' : 'Found ${matches.length} matches';
        _isProcessing = false;
      });
    } catch (e) {
      print('Error identifying song: $e');
      setState(() {
        _processingStatus = 'Error: $e';
        _isProcessing = false;
      });
    }
  }

  Future<void> _addNewSong() async {
    final titleController = TextEditingController();
    final artistController = TextEditingController();
    bool isRecording = false;
    String? selectedFilePath;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => Dialog(
          backgroundColor: Colors.transparent,
          child: Container(
            padding: EdgeInsets.all(24),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF6A1B9A),
                  Color(0xFF4A148C),
                ],
              ),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: Colors.white.withOpacity(0.2),
                width: 1,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Add New Song',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                  ),
                ),
                SizedBox(height: 24),
                TextField(
                  controller: titleController,
                  style: TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'Title',
                    labelStyle: TextStyle(color: Colors.white70),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.white30),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.white70),
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
                SizedBox(height: 16),
                TextField(
                  controller: artistController,
                  style: TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'Artist',
                    labelStyle: TextStyle(color: Colors.white70),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.white30),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.white70),
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
                SizedBox(height: 32),
                // File upload button
                if (!isRecording && selectedFilePath == null) ...[
                  TextButton.icon(
                    onPressed: () async {
                      final picker = ImagePicker();
                      try {
                        final XFile? file = await picker.pickVideo(source: ImageSource.gallery);
                        if (file != null) {
                          setDialogState(() {
                            selectedFilePath = file.path;
                          });
                        }
                      } catch (e) {
                        print('Error picking file: $e');
                      }
                    },
                    icon: Icon(Icons.upload_file, color: Colors.white70),
                    label: Text(
                      'Upload Audio File',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ),
                  Text(
                    'or',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 16,
                    ),
                  ),
                ],
                if (selectedFilePath != null) ...[
                  Container(
                    padding: EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.audio_file, color: Colors.white70),
                        SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            File(selectedFilePath!).uri.pathSegments.last,
                            style: TextStyle(color: Colors.white70),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          icon: Icon(Icons.close, color: Colors.white70),
                          onPressed: () {
                            setDialogState(() {
                              selectedFilePath = null;
                            });
                          },
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () async {
                      try {
                        setState(() {
                          _isProcessing = true;
                        });
                        
                        final fingerprints = await _fingerprintService.generateFingerprint(selectedFilePath!);
                        
                        final song = Song(
                          id: DateTime.now().millisecondsSinceEpoch.toString(),
                          title: titleController.text,
                          artist: artistController.text,
                          fingerprints: fingerprints,
                          createdAt: DateTime.now(),
                          audioPath: selectedFilePath,
                        );
                        
                        await _storageService.addSong(song);
                        await _loadSongs();
                        
                        setState(() {
                          _processingStatus = 'Song added successfully!';
                        });
                        
                        Navigator.pop(context);
                      } catch (e) {
                        setState(() {
                          _processingStatus = 'Error processing file: ${e.toString()}';
                        });
                      } finally {
                        setState(() {
                          _isProcessing = false;
                        });
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Color(0xFFE91E63),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: Text('Process and Add'),
                  ),
                ],
                // Recording button
                if (selectedFilePath == null) ...[
                  GestureDetector(
                    onTap: () async {
                      if (!isRecording) {
                        setDialogState(() {
                          isRecording = true;
                        });
                        
                        setState(() {
                          _isProcessing = true;
                        });
                        
                        try {
                          final audioPath = await _fingerprintService.recordAudio(seconds: 10);
                          final fingerprints = await _fingerprintService.generateFingerprint(audioPath);
                          
                          final song = Song(
                            id: DateTime.now().millisecondsSinceEpoch.toString(),
                            title: titleController.text,
                            artist: artistController.text,
                            fingerprints: fingerprints,
                            createdAt: DateTime.now(),
                            audioPath: audioPath,
                          );
                          
                          await _storageService.addSong(song);
                          await _loadSongs();
                          
                          setState(() {
                            _processingStatus = 'Song added successfully!';
                          });
                          
                          Navigator.pop(context);
                        } catch (e) {
                          setState(() {
                            _processingStatus = 'Error adding song: ${e.toString()}';
                          });
                          setDialogState(() {
                            isRecording = false;
                          });
                        } finally {
                          setState(() {
                            _isProcessing = false;
                          });
                        }
                      }
                    },
                    child: Container(
                      width: 120,
                      height: 120,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            Color(0xFFE91E63),
                            Color(0xFF9C27B0),
                          ],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Color(0xFFE91E63).withOpacity(0.3),
                            blurRadius: 20,
                            spreadRadius: 5,
                          ),
                        ],
                      ),
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          if (isRecording) ...[
                            for (var i = 1; i <= 3; i++)
                              TweenAnimationBuilder(
                                tween: Tween(begin: 0.0, end: 1.0),
                                duration: Duration(seconds: 1 * i),
                                curve: Curves.easeOut,
                                builder: (context, double value, child) {
                                  return Container(
                                    width: 120 * value,
                                    height: 120 * value,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: Color(0xFFE91E63).withOpacity(1 - value),
                                        width: 2,
                                      ),
                                    ),
                                  );
                                },
                              ),
                            CustomPaint(
                              size: Size(60, 60),
                              painter: WaveformPainter(),
                            ),
                          ] else
                            Icon(
                              Icons.mic,
                              size: 40,
                              color: Colors.white,
                            ),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(height: 16),
                  Text(
                    isRecording ? 'Recording...' : 'Tap to Record',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 16,
                    ),
                  ),
                ],
                if (!isRecording && selectedFilePath == null) ...[
                  SizedBox(height: 24),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(
                      'Cancel',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF6A1B9A), // Deep purple
              Color(0xFF4A148C), // Darker purple
            ],
          ),
        ),
        child: Stack(
          children: [
            // Background music notes
            ...List.generate(10, (index) {
              final random = Random();
              return Positioned(
                left: random.nextDouble() * MediaQuery.of(context).size.width,
                top: random.nextDouble() * MediaQuery.of(context).size.height,
                child: Opacity(
                  opacity: 0.1,
                  child: Transform.rotate(
                    angle: random.nextDouble() * pi,
                    child: Icon(
                      [Icons.music_note, Icons.queue_music][random.nextInt(2)],
                      size: 40 + random.nextDouble() * 40,
                      color: Colors.white,
                    ),
                  ),
                ),
              );
            }),
            SafeArea(
              child: Column(
                children: [
                  // Music library button
                  Align(
                    alignment: Alignment.topRight,
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: IconButton(
                        icon: Icon(Icons.library_music, color: Colors.white, size: 30),
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => MusicLibraryScreen(
                                songs: _storedSongs,
                                onAddSong: _addNewSong,
                                onDeleteSong: _deleteSong,
                                onPlaySong: _playStoredSong,
                                currentlyPlayingSongId: _currentlyPlayingSongId,
                                isPlaying: _isPlaying,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  Expanded(
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          // Recording button with wave animation
                          GestureDetector(
                            onTap: _isProcessing ? null : _startRecording,
                            child: Container(
                              width: 160,
                              height: 160,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: [
                                    Color(0xFFE91E63), // Pink
                                    Color(0xFF9C27B0), // Purple
                                  ],
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Color(0xFFE91E63).withOpacity(0.3),
                                    blurRadius: 20,
                                    spreadRadius: 5,
                                  ),
                                  BoxShadow(
                                    color: Color(0xFF9C27B0).withOpacity(0.3),
                                    blurRadius: 20,
                                    spreadRadius: 5,
                                  ),
                                ],
                              ),
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  // Animated waves when recording
                                  if (_isProcessing) ...[
                                    for (var i = 1; i <= 3; i++)
                                      TweenAnimationBuilder(
                                        tween: Tween(begin: 0.0, end: 1.0),
                                        duration: Duration(seconds: 1 * i),
                                        curve: Curves.easeOut,
                                        builder: (context, double value, child) {
                                          return Container(
                                            width: 160 * value,
                                            height: 160 * value,
                                            decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              border: Border.all(
                                                color: Color(0xFFE91E63).withOpacity(1 - value),
                                                width: 2,
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                  ],
                                  // Center content
                                  _isProcessing 
                                    ? CustomPaint(
                                        size: Size(80, 80),
                                        painter: WaveformPainter(),
                                      )
                                    : Icon(
                                        Icons.music_note,
                                        size: 50,
                                        color: Colors.white,
                                      ),
                                ],
                              ),
                            ),
                          ),
                          SizedBox(height: 24),
                          // Status text with custom font
                          Text(
                            _isProcessing ? 'Listening...' : 'Tap to Listen',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 1.2,
                              shadows: [
                                Shadow(
                                  color: Colors.black26,
                                  offset: Offset(0, 2),
                                  blurRadius: 4,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Matched songs list with new styling
                  if (_matchedSongs.isEmpty && _recordedAudioPath != null)
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.1),
                        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.2),
                          width: 1,
                        ),
                      ),
                      padding: EdgeInsets.all(20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.music_off, size: 48, color: Colors.white70),
                          SizedBox(height: 16),
                          Text(
                            'No matches found',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                              letterSpacing: 1,
                            ),
                          ),
                          SizedBox(height: 8),
                          Text(
                            'Try recording again or add this song to your library',
                            style: TextStyle(color: Colors.white70),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    )
                  else if (_matchedSongs.isNotEmpty)
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.1),
                        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.2),
                          width: 1,
                        ),
                      ),
                      padding: EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.queue_music, color: Colors.white70),
                              SizedBox(width: 10),
                              Text(
                                'Matched Songs',
                                style: TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                  letterSpacing: 1,
                                ),
                              ),
                            ],
                          ),
                          SizedBox(height: 16),
                          ...List.generate(_matchedSongs.length, (index) {
                            final song = _matchedSongs[index];
                            return Container(
                              margin: EdgeInsets.only(bottom: 12),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(15),
                                border: Border.all(
                                  color: Colors.white.withOpacity(0.2),
                                  width: 1,
                                ),
                              ),
                              child: ListTile(
                                leading: Container(
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Color(0xFFE91E63).withOpacity(0.2),
                                  ),
                                  child: Icon(Icons.music_note, color: Colors.white70),
                                ),
                                title: Text(
                                  song.title,
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                subtitle: Text(
                                  song.artist ?? 'Unknown Artist',
                                  style: TextStyle(color: Colors.white70),
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: Icon(Icons.play_arrow, color: Colors.white70),
                                      onPressed: () => _playStoredSong(song),
                                    ),
                                    IconButton(
                                      icon: Icon(Icons.delete, color: Colors.white70),
                                      onPressed: () => _deleteSong(song),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class MusicLibraryScreen extends StatelessWidget {
  final List<Song> songs;
  final Function() onAddSong;
  final Function(Song) onDeleteSong;
  final Function(Song) onPlaySong;
  final String? currentlyPlayingSongId;
  final bool isPlaying;

  const MusicLibraryScreen({
    Key? key,
    required this.songs,
    required this.onAddSong,
    required this.onDeleteSong,
    required this.onPlaySong,
    required this.currentlyPlayingSongId,
    required this.isPlaying,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF6A1B9A),
              Color(0xFF4A148C),
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // Header
              Padding(
                padding: EdgeInsets.all(16),
                child: Row(
                  children: [
                    IconButton(
                      icon: Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: () => Navigator.pop(context),
                    ),
                    Text(
                      'Music Library',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1,
                      ),
                    ),
                    Spacer(),
                    IconButton(
                      icon: Icon(Icons.add, color: Colors.white),
                      onPressed: onAddSong,
                    ),
                  ],
                ),
              ),
              // Song list
              Expanded(
                child: songs.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.music_off,
                              size: 64,
                              color: Colors.white.withOpacity(0.5),
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
                        itemCount: songs.length,
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        itemBuilder: (context, index) {
                          final song = songs[index];
                          return Container(
                            margin: EdgeInsets.only(bottom: 12),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(15),
                              border: Border.all(
                                color: Colors.white.withOpacity(0.2),
                                width: 1,
                              ),
                            ),
                            child: ListTile(
                              leading: Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Color(0xFFE91E63).withOpacity(0.2),
                                ),
                                child: Icon(Icons.music_note, color: Colors.white70),
                              ),
                              title: Text(
                                song.title,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              subtitle: Text(
                                song.artist ?? 'Unknown Artist',
                                style: TextStyle(color: Colors.white70),
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: Icon(
                                      isPlaying && currentlyPlayingSongId == song.id
                                          ? Icons.stop
                                          : Icons.play_arrow,
                                      color: Colors.white70,
                                    ),
                                    onPressed: () => onPlaySong(song),
                                  ),
                                  IconButton(
                                    icon: Icon(Icons.delete, color: Colors.white70),
                                    onPressed: () => onDeleteSong(song),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class WaveformPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;

    final width = size.width;
    final height = size.height;
    final centerY = height / 2;

    // Create animated wave effect
    final now = DateTime.now().millisecondsSinceEpoch / 200;
    
    for (var i = 0; i < width; i += 4) {
      final x = i.toDouble();
      // Create multiple overlapping sine waves
      final y1 = centerY + sin((x / width * 2 * pi) + now) * 10;
      final y2 = centerY + sin((x / width * 4 * pi) + now * 1.5) * 8;
      final y3 = centerY + sin((x / width * 6 * pi) + now * 0.5) * 6;
      
      // Combine waves
      final y = (y1 + y2 + y3) / 3;
      
      canvas.drawLine(
        Offset(x, centerY),
        Offset(x, y),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
