/// A user-created, ordered collection of songs. Stores song IDs rather than
/// full Song objects so ordering and membership persist cheaply.
class Playlist {
  const Playlist({
    required this.id,
    required this.name,
    this.songIds = const [],
    this.createdAt,
  });

  final String id;
  final String name;
  final List<String> songIds;
  final DateTime? createdAt;

  int get length => songIds.length;

  Playlist copyWith({
    String? id,
    String? name,
    List<String>? songIds,
    DateTime? createdAt,
  }) {
    return Playlist(
      id: id ?? this.id,
      name: name ?? this.name,
      songIds: songIds ?? this.songIds,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is Playlist && other.id == id);

  @override
  int get hashCode => id.hashCode;
}
