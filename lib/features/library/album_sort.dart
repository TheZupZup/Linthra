import '../../core/catalog/text_folding.dart';
import '../../core/models/album.dart';

/// What the Albums grid can be sorted on.
enum AlbumSortField { title, artist, dateAdded }

/// Every order the Albums grid offers, each a field and a direction.
///
/// Stored by [name], so a remembered choice survives reordering this list.
enum AlbumSort {
  titleAscending(AlbumSortField.title),
  titleDescending(AlbumSortField.title, descending: true),
  artistAscending(AlbumSortField.artist),
  artistDescending(AlbumSortField.artist, descending: true),
  newestAdded(AlbumSortField.dateAdded, descending: true),
  oldestAdded(AlbumSortField.dateAdded);

  const AlbumSort(this.field, {this.descending = false});

  final AlbumSortField field;

  /// Z to A, or newest first.
  final bool descending;

  /// The order the grid has always had: by title, A to Z.
  static const AlbumSort fallback = AlbumSort.titleAscending;

  /// The order stored as [name], or null for an absent or unknown one.
  static AlbumSort? byName(String? name) {
    for (final AlbumSort sort in values) {
      if (sort.name == name) return sort;
    }
    return null;
  }
}

/// [albums] in the order [sort] puts them. [albums] itself is left alone.
///
/// Title A to Z is the order `groupAlbums` already returns, so [albums] comes
/// back as it is. The other orders fold case and common accents the same way.
///
/// An album without the sorted-by artist or date comes last whichever way the
/// grid runs. Only the sorted-by value follows the direction: ties stay by
/// title A to Z, then artist, then [Album.id], so the result never depends on
/// the order [albums] came in.
///
/// [addedAt] maps an [Album.id] to when the album was added: the earliest of
/// its songs, which is when it entered the library.
///
/// Stays in Dart: a library has a few thousand albums against hundreds of
/// thousands of songs, and album_sort_bench.dart sorts 20 000 in a few
/// milliseconds, less than crossing into the Rust core would cost.
List<Album> sortAlbums(
  List<Album> albums,
  AlbumSort sort, {
  Map<String, DateTime> addedAt = const <String, DateTime>{},
}) {
  if (sort == AlbumSort.titleAscending) return albums;
  final List<_AlbumKey> keys = <_AlbumKey>[
    for (final Album album in albums) _AlbumKey(album, sort.field, addedAt),
  ];
  final int direction = sort.descending ? -1 : 1;
  final int Function(_AlbumKey a, _AlbumKey b) compareValue =
      switch (sort.field) {
    AlbumSortField.title => _AlbumKey.compareTitle,
    AlbumSortField.artist => _AlbumKey.compareArtist,
    AlbumSortField.dateAdded => _AlbumKey.compareAdded,
  };
  keys.sort((_AlbumKey a, _AlbumKey b) {
    if (a.missing != b.missing) return a.missing ? 1 : -1;
    if (!a.missing) {
      final int byValue = compareValue(a, b);
      if (byValue != 0) return byValue * direction;
    }
    return _AlbumKey.compareTies(a, b);
  });
  return <Album>[for (final _AlbumKey key in keys) key.album];
}

/// An album with what it is ordered by, folded once rather than on every
/// comparison.
class _AlbumKey {
  _AlbumKey(this.album, AlbumSortField field, Map<String, DateTime> addedAt)
      : title = foldText(album.title),
        artist = foldText(album.artistName ?? ''),
        sortArtist = foldText((album.artistName ?? '').trim()),
        added = field == AlbumSortField.dateAdded
            ? addedAt[album.id]?.microsecondsSinceEpoch
            : null,
        missing = switch (field) {
          AlbumSortField.title => false,
          AlbumSortField.artist => (album.artistName ?? '').trim().isEmpty,
          AlbumSortField.dateAdded => addedAt[album.id] == null,
        };

  final Album album;

  /// Folded as `groupAlbums` folds them, so title A to Z here and there agree.
  final String title;
  final String artist;

  /// The artist without surrounding spaces, which is what the artist order
  /// sorts on.
  final String sortArtist;
  final int? added;

  /// Whether the album has nothing to sort by in this order.
  final bool missing;

  static int compareTitle(_AlbumKey a, _AlbumKey b) =>
      a.title.compareTo(b.title);

  static int compareArtist(_AlbumKey a, _AlbumKey b) =>
      a.sortArtist.compareTo(b.sortArtist);

  static int compareAdded(_AlbumKey a, _AlbumKey b) =>
      a.added!.compareTo(b.added!);

  /// Title, then artist, then id: `groupAlbums`' own order.
  static int compareTies(_AlbumKey a, _AlbumKey b) {
    final int byTitle = a.title.compareTo(b.title);
    if (byTitle != 0) return byTitle;
    final int byArtist = a.artist.compareTo(b.artist);
    if (byArtist != 0) return byArtist;
    return a.album.id.compareTo(b.album.id);
  }
}
