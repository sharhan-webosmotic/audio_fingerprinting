import '../models/song.dart';
import 'api_service.dart';

class StorageService {
  final ApiService _apiService = ApiService();

  static Future<StorageService> create() async {
    return StorageService();
  }

  Future<List<Song>> getSongs() async {
    try {
      final response = await _apiService.getSongs();
      return response;
    } catch (e) {
      print('Error getting songs: $e');
      return [];
    }
  }

  Future<Song?> addSong(String filePath, String name) async {
    try {
      final response = await _apiService.addSong(filePath, name);
      return Song(
        id: response['songId'],
        name: response['songName'],
        duration: response['duration']?.toDouble() ?? 0.0,
      );
    } catch (e) {
      print('Error adding song: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>> matchAudio(String filePath) async {
    try {
      final response = await _apiService.matchAudio(filePath);
      return response;
    } catch (e) {
      print('Error matching audio: $e');
      return {
        'matched': false,
        'error': e.toString(),
      };
    }
  }
}
