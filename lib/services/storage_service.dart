import 'dart:convert';
import 'dart:math';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';

class StorageService {
  static const String _songsKey = 'stored_songs';
  final _prefs = SharedPreferences.getInstance();

  static Future<StorageService> create() async {
    final prefs = await SharedPreferences.getInstance();
    return StorageService();
  }

  Future<List<Song>> getAllSongs() async {
    final prefs = await _prefs;
    final songsJson = prefs.getStringList(_songsKey) ?? [];
    return songsJson.map((json) => Song.fromJson(jsonDecode(json))).toList();
  }

  Future<void> addSong(Song song) async {
    final prefs = await _prefs;
    final songs = await getAllSongs();
    songs.add(song);
    await _saveSongs(songs);
  }

  Future<void> deleteSong(String songId) async {
    final prefs = await _prefs;
    final songs = await getAllSongs();
    songs.removeWhere((song) => song.id == songId);
    await _saveSongs(songs);
    
    // Also delete the audio file if it exists
    try {
      final song = songs.firstWhere((s) => s.id == songId);
      if (song.audioPath != null) {
        final file = File(song.audioPath!);
        if (await file.exists()) {
          await file.delete();
        }
      }
    } catch (e) {
      print('Error deleting audio file: $e');
    }
  }

  Future<List<Song>> findMatches(List<Map<String, dynamic>> fingerprints) async {
    final songs = await getAllSongs();
    if (songs.isEmpty) return [];

    print('Matching against ${songs.length} songs');
    print('Input fingerprints: ${fingerprints.length}');

    // Create a hash table for faster lookup
    final Map<int, List<MapEntry<String, int>>> hashTable = {};
    for (final song in songs) {
      if (song.fingerprints == null) continue;
      
      for (final fp in song.fingerprints!) {
        final hash = fp['hash'] as int;
        hashTable.putIfAbsent(hash, () => []).add(MapEntry(song.id, fp['offset'] as int));
      }
    }

    // Count matches per song with early stopping
    final Map<String, Map<int, int>> songMatches = {};
    int maxMatchesNeeded = 100; // Stop after finding this many matches for a song
    
    // Process fingerprints in larger batches for better performance
    const batchSize = 1000;
    bool foundGoodMatch = false;
    
    for (var i = 0; i < fingerprints.length && !foundGoodMatch; i += batchSize) {
      final end = min(i + batchSize, fingerprints.length);
      final batch = fingerprints.sublist(i, end);
      
      for (final fp in batch) {
        final hash = fp['hash'] as int;
        final offset = fp['offset'] as int;
        
        final matches = hashTable[hash];
        if (matches != null) {
          for (final match in matches) {
            final songId = match.key;
            final songOffset = match.value;
            final timeDiff = offset - songOffset;
            
            songMatches.putIfAbsent(songId, () => {});
            songMatches[songId]![timeDiff] = (songMatches[songId]![timeDiff] ?? 0) + 1;
            
            // Check if we have a good match
            if (songMatches[songId]![timeDiff]! >= maxMatchesNeeded) {
              foundGoodMatch = true;
              break;
            }
          }
        }
        if (foundGoodMatch) break;
      }
    }

    // Find best matches
    final List<MapEntry<String, int>> results = [];
    for (final entry in songMatches.entries) {
      final songId = entry.key;
      final timeDiffs = entry.value;
      
      // Get the most common time difference
      int bestCount = 0;
      for (final count in timeDiffs.values) {
        if (count > bestCount) bestCount = count;
      }
      
      if (bestCount >= 50) { // Require at least 50 aligned matches
        results.add(MapEntry(songId, bestCount));
      }
    }

    // Sort by match count
    results.sort((a, b) => b.value.compareTo(a.value));
    
    // Get matching songs
    final matches = <Song>[];
    for (final result in results.take(3)) {
      final song = songs.firstWhere((s) => s.id == result.key);
      print('Match found: ${song.title} with ${result.value} matching fingerprints');
      matches.add(song);
    }

    return matches;
  }

  Future<void> _saveSongs(List<Song> songs) async {
    final prefs = await _prefs;
    final songsJson = songs.map((song) => jsonEncode(song.toJson())).toList();
    await prefs.setStringList(_songsKey, songsJson);
  }
}
