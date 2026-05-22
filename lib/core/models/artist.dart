/// An artist grouping.
class Artist {
  const Artist({
    required this.id,
    required this.name,
    this.albumCount = 0,
    this.artworkUri,
  });

  final String id;
  final String name;
  final int albumCount;
  final Uri? artworkUri;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is Artist && other.id == id);

  @override
  int get hashCode => id.hashCode;
}
