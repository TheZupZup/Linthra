import '../../core/models/track.dart';
import '../../core/native/native_song_sort.dart';

/// Choose how to sort songs.
enum SongSortField { title, artist, album, dateAdded }

/// This is the list of song sorting options.
/// Each option has a sort type and a direction.
///
/// We save the option by it's name.
/// This keep the saved choice working after updates.
enum SongSort {
  titleAscending(SongSortField.title),
  titleDescending(SongSortField.title, descending: true),
  artistAscending(SongSortField.artist),
  artistDescending(SongSortField.artist, descending: true),
  albumAscending(SongSortField.album),
  albumDescending(SongSortField.album, descending: true),
  newestAdded(SongSortField.dateAdded, descending: true),
  oldestAdded(SongSortField.dateAdded);

  const SongSort(this.field, {this.descending = false});

  final SongSortField field;

  /// Z to A, or newest first.
  final bool descending;

  /// The order the list has always had: by title, A to Z.
  static const SongSort fallback = SongSort.titleAscending;

  /// The order stored as [name], or null for an absent or unknown one.
  static SongSort? byName(String? name) {
    for (final SongSort sort in values) {
      if (sort.name == name) return sort;
    }
    return null;
  }
}

/// The section a song without the sorted-by artist or album files under. It
/// sits after every other section, whichever way the list runs.
const String kUnknownSongSection = '?';

/// Songs in the order a [SongSort] puts them, with the section each one files
/// under.
class SortedSongs {
  const SortedSongs(this.tracks, this.sections);

  final List<Track> tracks;

  /// The section of each of [tracks], index for index: an uppercase A–Z, '#'
  /// for anything that doesn't start with one, or [kUnknownSongSection]. Null
  /// for an order with no sections ([SongSortField.dateAdded]), where an
  /// alphabet index would mean nothing.
  final List<String>? sections;
}

/// Orders [tracks] by [sort].
///
/// The order and the sections come from one key, folded once per song:
/// case, common accents and surrounding spaces count for nothing, so "Édith
/// Piaf" sorts and files under E, and each section is one contiguous run.
///
/// A song missing the sorted-by artist, album or date always comes last, in
/// either direction. An unknown is not the smallest value, and sorting every
/// untagged song to the top would bury the ones that do sort.
///
/// Ties are broken all the way down to [Track.uri], so the result never
/// depends on the order [tracks] came in. Only the sorted-by value follows the
/// direction: the tie-breakers stay ascending, so an artist's songs read album
/// by album in album order whether the artists run A to Z or Z to A, and songs
/// added together read by title.
///
/// [addedAt] maps a song's [Track.uri] to when it first entered the library.
/// [albums] files each song under its album for the artist and album orders;
/// pass the catalog's when [tracks] is a search of it, so a search that hides
/// the song carrying an album's name doesn't move the rest to Unknown Album.
/// Without it the albums are worked out from [tracks] alone.
///
/// Sorted in the Rust core (native/linthra_core/src/song_sort.rs).
SortedSongs sortSongs(
  List<Track> tracks,
  SongSort sort, {
  Map<String, DateTime> addedAt = const <String, DateTime>{},
  SongAlbums? albums,
}) {
  final SongSortField field = sort.field;
  final bool filesByAlbum =
      field == SongSortField.artist || field == SongSortField.album;
  final (List<int>, List<String>?) sorted = NativeSongSort.sort(
    tracks,
    catalog: filesByAlbum ? albums?.catalog : null,
    field: field.index,
    descending: sort.descending,
    addedAt: addedAt,
  );
  return SortedSongs(
    <Track>[for (final int i in sorted.$1) tracks[i]],
    sorted.$2,
  );
}

/// The album every song of a catalog is filed under, keyed the way the Albums
/// tab groups them (`albumIdForTrack`), with one name and one artist per
/// album. Worked out once per catalog, so a search sorts against it without
/// walking the whole library again.
///
/// Every song on an album shares them, so the album stays in one piece and in
/// album order even when its songs' own tags disagree: a name missing from one
/// of them, a suffix on another, a compilation with a stable id where each
/// track only names its own performer. The alphabetically first name wins, and
/// the album's own artist when any song carries one, otherwise its first
/// track artist, so neither depends on the order the catalog came in.
class SongAlbums {
  /// Cheap: the Rust core files a sort against [catalog] itself.
  SongAlbums.of(this.catalog);

  /// The catalog the albums come from.
  final List<Track> catalog;
}
