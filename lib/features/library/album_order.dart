import '../../core/models/album.dart';

/// Chose the order of albums.
enum AlbumOrder {
  titleAZ,
  titleZA,
  artistAZ,
  artistZA,
}

/// Sort abums by tuitle from A to Z
/// Keep the original album list unchanged.
List<Album> sortAlbumsByTitle(
  List<Album> albums, {
  bool descending = false,
}) {
  final List<Album> result = List<Album>.from(albums);

  result.sort((first, second) {
    if (descending) {
      return second.title.compareTo(first.title);
    }

    return first.title.compareTo(second.title);
  });

  return result;
}
