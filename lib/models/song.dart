class Song {
  final String id;
  final String name;
  final int duration;

  Song({
    required this.id,
    required this.name,
    required this.duration,
  });

  factory Song.fromJson(Map<String, dynamic> json) {
    return Song(
      id: json['id'] as String,
      name: json['name'] as String,
      duration: json['duration'] as int,
    );
  }

  factory Song.fromApiResponse(Map<String, dynamic> json) {
    return Song(
      id: json['songId'],
      name: json['songName'],
      duration: json['duration'] as int,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'duration': duration,
    };
  }
}
