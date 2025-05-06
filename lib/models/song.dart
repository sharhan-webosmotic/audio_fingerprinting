class Song {
  final String id;
  final String title;
  final String artist;
  final List<Map<String, dynamic>> fingerprints;
  final DateTime createdAt;
  final String? audioPath;

  Song({
    required this.id,
    required this.title,
    required this.artist,
    required this.fingerprints,
    required this.createdAt,
    this.audioPath,
  });

  factory Song.fromJson(Map<String, dynamic> json) {
    return Song(
      id: json['id'] as String,
      title: json['title'] as String,
      artist: json['artist'] as String,
      fingerprints: List<Map<String, dynamic>>.from(json['fingerprints']),
      createdAt: DateTime.parse(json['createdAt'] as String),
      audioPath: json['audioPath'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'artist': artist,
      'fingerprints': fingerprints,
      'createdAt': createdAt.toIso8601String(),
      'audioPath': audioPath,
    };
  }
}
