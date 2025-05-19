import 'dart:io';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../models/song.dart';

class ApiService {
  // Using Mac's local IP address for wireless device testing
  static const String baseUrl = 'http://10.0.1.16:5001';

  Future<List<Song>> getSongs() async {
    try {
      final uri = Uri.parse('$baseUrl/songs');
      final response = await http.get(uri);

      if (response.statusCode == 200) {
        final List<dynamic> jsonList = json.decode(response.body);
        return jsonList.map((json) => Song.fromJson(json)).toList();
      } else {
        throw Exception('Failed to load songs: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Error getting songs: $e');
    }
  }

  Future<Map<String, dynamic>> matchAudio(String audioPath) async {
    try {
      final uri = Uri.parse('$baseUrl/match');
      final request = http.MultipartRequest('POST', uri);

      final file = File(audioPath);
      final stream = http.ByteStream(file.openRead());
      final length = await file.length();
String filename = audioPath.split('/').last;
      if (!filename.toLowerCase().endsWith('.mp3') &&
          !filename.toLowerCase().endsWith('.wav') &&
          !filename.toLowerCase().endsWith('.m4a') &&
          !filename.toLowerCase().endsWith('.ogg')) {
        filename += '.mp3'; // Default to mp3 if no extension
      }
      
      final multipartFile = await http.MultipartFile(
        'file',
        stream,
        length,
        filename: filename
      );
      
      request.files.add(multipartFile);

      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        final result = json.decode(response.body);
        return {
          'matched': result['matched'] ?? false,
          'songId': result['song_id']?.toString(),
          'songName': result['song'],
          'confidence': result['confidence'] ?? 0
        };
      } else {
        throw Exception('Failed to match audio: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Error matching audio: $e');
    }
  }

  Future<Map<String, dynamic>> addSong(String audioPath, String songName) async {
    try {
      final uri = Uri.parse('$baseUrl/add');
      var request = http.MultipartRequest('POST', uri);
      
      // Add the audio file
      final file = File(audioPath);
      final bytes = await file.readAsBytes();
      // Ensure we have a valid file extension
      String filename = audioPath.split('/').last;
      if (!filename.toLowerCase().endsWith('.mp3') &&
          !filename.toLowerCase().endsWith('.wav') &&
          !filename.toLowerCase().endsWith('.m4a') &&
          !filename.toLowerCase().endsWith('.ogg')) {
        filename += '.mp3'; // Default to mp3 if no extension
      }
      
      final multipartFile = http.MultipartFile.fromBytes(
        'file',
        bytes,
        filename: filename,
      );
      
      request.files.add(multipartFile);
      request.fields['name'] = songName;
      
      // Send the request
      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);
      
      print('Response status: ${response.statusCode}');
      print('Response body: ${response.body}');
      
      if (response.statusCode == 200) {
        final result = json.decode(response.body);
        return {
          'success': result['success'],
          'songId': result['song_id'].toString(),
          'songName': songName,
          'duration': result['stats']['duration'],
          'message': result['message']
        };
      } else {
        throw Exception('Failed to add song: ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      throw Exception('Error adding song: $e');
    }
  }
}
