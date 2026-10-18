import '../../core/catalog/library_grouping.dart';
import '../../core/catalog/text_folding.dart';
import '../../core/models/track.dart';

/// What the Songs list can be ordered by (#893).
enum SongSortField { title, artist, album, dateAdded }

/// The orders the Songs list offers: one [field], one direction.
///
/// Persisted by [name], never by index, so a stored choice survives an order
/// being added or reordered later.
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
/// The order and the sections come from one key, folded once per song (#872):
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
SortedSongs sortSongs(
  List<Track> tracks,
  SongSort sort, {
  Map<String, DateTime> addedAt = const <String, DateTime>{},
}) {
  final SongSortField field = sort.field;
  final List<_Album>? albums =
      field == SongSortField.artist || field == SongSortField.album
          ? _albumsOf(tracks)
          : null;
  final List<_SongKey> keys = <_SongKey>[
    for (int i = 0; i < tracks.length; i++)
      _SongKey(tracks[i], field, addedAt, albums?[i]),
  ];
  // Picked once, rather than per comparison.
  final _Compare compareValue = switch (field) {
    SongSortField.title => _SongKey.compareTitle,
    SongSortField.artist || SongSortField.album => _SongKey.compareValue,
    SongSortField.dateAdded => _SongKey.compareAdded,
  };
  final _Compare compareTies = switch (field) {
    SongSortField.title => _SongKey.compareTags,
    SongSortField.artist => _SongKey.compareArtistTies,
    SongSortField.album => _SongKey.compareAlbumTies,
    SongSortField.dateAdded => _SongKey.compareTitleThenTags,
  };
  final int direction = sort.descending ? -1 : 1;
  keys.sort((_SongKey a, _SongKey b) {
    if (a.missing != b.missing) return a.missing ? 1 : -1;
    if (!a.missing) {
      final int byValue = compareValue(a, b);
      if (byValue != 0) return byValue * direction;
    }
    final int byTies = compareTies(a, b);
    if (byTies != 0) return byTies;
    return a.track.uri.compareTo(b.track.uri);
  });
  return SortedSongs(
    <Track>[for (final _SongKey key in keys) key.track],
    field == SongSortField.dateAdded
        ? null
        : <String>[for (final _SongKey key in keys) key.section],
  );
}

typedef _Compare = int Function(_SongKey a, _SongKey b);

/// The album a song is filed under, with one name and one artist for the
/// whole album.
typedef _Album = ({String id, String? name, String? artist});

/// The album each of [tracks] is filed under, keyed the way the Albums tab
/// groups them ([albumIdForTrack]), with one name and one artist per album.
///
/// Every song on an album shares them, so the album stays in one piece and in
/// album order even when its songs' own tags disagree: a name missing from one
/// of them, a suffix on another, a compilation with a stable id where each
/// track only names its own performer. The alphabetically first name wins, and
/// the album's own artist when any song carries one, otherwise its first
/// track artist, so neither depends on the order the catalog came in.
List<_Album> _albumsOf(List<Track> tracks) {
  final List<String> ids = <String>[
    for (final Track track in tracks) albumIdForTrack(track),
  ];
  final Map<String, String> names = <String, String>{};
  final Map<String, String> albumArtists = <String, String>{};
  final Map<String, String> trackArtists = <String, String>{};
  void keepFirst(Map<String, String> labels, String album, String? label) {
    if (label == null) return;
    final String? current = labels[album];
    if (current == null || label.compareTo(current) < 0) labels[album] = label;
  }

  for (int i = 0; i < tracks.length; i++) {
    final Track track = tracks[i];
    keepFirst(names, ids[i], _SongKey._fold(track.albumName));
    keepFirst(albumArtists, ids[i], _SongKey._fold(track.albumArtistName));
    keepFirst(trackArtists, ids[i], _SongKey._fold(track.artistName));
  }
  return <_Album>[
    for (final String id in ids)
      (id: id, name: names[id], artist: albumArtists[id] ?? trackArtists[id]),
  ];
}

/// A song with what it is ordered by, folded once so a large library isn't
/// re-folded on every comparison. The tie-breakers are folded only when a
/// comparison gets that far.
class _SongKey {
  factory _SongKey(
    Track track,
    SongSortField field,
    Map<String, DateTime> addedAt,
    _Album? album,
  ) {
    final String title = _fold(track.title) ?? '';
    final String titleSection = _sectionOf(title);
    switch (field) {
      case SongSortField.title:
        return _SongKey._(track, title, titleSection, section: titleSection);
      case SongSortField.artist:
      case SongSortField.album:
        final String? value = field == SongSortField.artist
            ? _fold(track.artistName)
            : album!.name;
        return _SongKey._(
          track,
          title,
          titleSection,
          value: value,
          section: value == null ? kUnknownSongSection : _sectionOf(value),
          missing: value == null,
          album: album,
        );
      case SongSortField.dateAdded:
        final int? added = addedAt[track.uri]?.microsecondsSinceEpoch;
        return _SongKey._(
          track,
          title,
          titleSection,
          section: titleSection,
          addedAt: added,
          missing: added == null,
        );
    }
  }

  _SongKey._(
    this.track,
    this.title,
    this.titleSection, {
    required this.section,
    this.value,
    this.addedAt,
    this.missing = false,
    this.album,
  });

  static final RegExp _latinLetter = RegExp('^[a-z]');

  final Track track;

  /// The folded title, and the section it files under. Every order falls back
  /// on the title, so both are always here.
  final String title;
  final String titleSection;

  /// The folded artist or album being sorted by, or null when the song has
  /// none.
  final String? value;

  /// When the song first entered the library, or null when nobody recorded it.
  final int? addedAt;

  /// The section this song files under in this order.
  final String section;

  /// Whether the song has no value to sort by in this order, which puts it
  /// after every song that has one.
  final bool missing;

  /// The album the song is filed under, when sorting by artist or album.
  final _Album? album;

  late final String? _artist = _fold(track.artistName);
  late final String? _album = _fold(track.albumName);

  /// By title section, then folded title, then the title as written, so two
  /// spellings that fold alike still land in one order. The section comes
  /// first, which is what puts the '#' section ahead of A.
  static int compareTitle(_SongKey a, _SongKey b) {
    final int bySection = a.titleSection.compareTo(b.titleSection);
    if (bySection != 0) return bySection;
    final int byFolded = a.title.compareTo(b.title);
    if (byFolded != 0) return byFolded;
    return a.track.title.compareTo(b.track.title);
  }

  /// By the artist or album being sorted on, section first.
  static int compareValue(_SongKey a, _SongKey b) {
    final int bySection = a.section.compareTo(b.section);
    if (bySection != 0) return bySection;
    return a.value!.compareTo(b.value!);
  }

  static int compareAdded(_SongKey a, _SongKey b) =>
      a.addedAt!.compareTo(b.addedAt!);

  /// By artist, then album.
  static int compareTags(_SongKey a, _SongKey b) {
    final int byArtist = _nullsLast(a._artist, b._artist);
    if (byArtist != 0) return byArtist;
    return _nullsLast(a._album, b._album);
  }

  static int compareTitleThenTags(_SongKey a, _SongKey b) {
    final int byTitle = compareTitle(a, b);
    if (byTitle != 0) return byTitle;
    return compareTags(a, b);
  }

  /// One artist's songs: album by album, each in the order it plays in.
  static int compareArtistTies(_SongKey a, _SongKey b) {
    final int byAlbum = _nullsLast(a.album!.name, b.album!.name);
    if (byAlbum != 0) return byAlbum;
    return _compareAlbumOrder(a, b);
  }

  /// One album name's songs: by the album's artist, so two artists' "Greatest
  /// Hits" stay apart, then in album order.
  static int compareAlbumTies(_SongKey a, _SongKey b) {
    final int byArtist = _nullsLast(a.album!.artist, b.album!.artist);
    if (byArtist != 0) return byArtist;
    return _compareAlbumOrder(a, b);
  }

  /// By album, so two albums sharing a name and artist never interleave, then
  /// the album's own disc and track order, then title.
  static int _compareAlbumOrder(_SongKey a, _SongKey b) {
    final int byAlbum = a.album!.id.compareTo(b.album!.id);
    if (byAlbum != 0) return byAlbum;
    final int byDisc = _nullsLast(a.track.discNumber, b.track.discNumber);
    if (byDisc != 0) return byDisc;
    final int byTrack = _nullsLast(a.track.trackNumber, b.track.trackNumber);
    if (byTrack != 0) return byTrack;
    return compareTitle(a, b);
  }

  /// `value` lower-cased without common accents or surrounding spaces, or null
  /// when nothing is left. `trim` first catches the Unicode spaces [foldText]
  /// leaves alone.
  static String? _fold(String? value) {
    if (value == null) return null;
    final String folded = foldText(value.trim());
    return folded.isEmpty ? null : folded;
  }

  /// An uppercase A–Z, or '#' for anything else (digits, symbols, other
  /// scripts, nothing at all).
  static String _sectionOf(String folded) =>
      _latinLetter.hasMatch(folded) ? folded[0].toUpperCase() : '#';

  /// Present values ascending, then the missing ones.
  static int _nullsLast<T extends Comparable<Object>>(T? a, T? b) {
    if (a != null && b != null) return a.compareTo(b);
    if (a != null) return -1;
    if (b != null) return 1;
    return 0;
  }
}
