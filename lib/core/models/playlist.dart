/// A user-created, ordered collection of tracks. Stores track IDs rather than
/// full Track objects so ordering and membership persist cheaply.
class Playlist {
  const Playlist({
    required this.id,
    required this.name,
    this.trackIds = const [],
    this.createdAt,
  });

  final String id;
  final String name;
  final List<String> trackIds;
  final DateTime? createdAt;

  int get length => trackIds.length;

  Playlist copyWith({
    String? id,
    String? name,
    List<String>? trackIds,
    DateTime? createdAt,
  }) {
    return Playlist(
      id: id ?? this.id,
      name: name ?? this.name,
      trackIds: trackIds ?? this.trackIds,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is Playlist && other.id == id);

  @override
  int get hashCode => id.hashCode;
}
