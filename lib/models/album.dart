/// An album grouping. References its artist by name to stay decoupled from any
/// particular source's ID scheme.
class Album {
  const Album({
    required this.id,
    required this.title,
    this.artistName,
    this.year,
    this.artworkUri,
    this.trackCount = 0,
  });

  final String id;
  final String title;
  final String? artistName;
  final int? year;
  final Uri? artworkUri;
  final int trackCount;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is Album && other.id == id);

  @override
  int get hashCode => id.hashCode;
}
