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
  final List<_SongKey> keys = <_SongKey>[
    for (final Track track in tracks) _SongKey(track, field, addedAt),
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
  if (field == SongSortField.album) _labelAlbums(keys);
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

/// Gives every song the artist its album is filed under, one per album, so an
/// album's songs share it and stay together in album order whoever performs
/// each track (a compilation with a stable album id and no album artist would
/// otherwise split by performer).
///
/// The album's own artist wins when any of its songs carries one, otherwise
/// its first track artist alphabetically, so the label never depends on the
/// order the catalog came in.
void _labelAlbums(List<_SongKey> keys) {
  final Map<String, String> albumArtists = <String, String>{};
  final Map<String, String> trackArtists = <String, String>{};
  void keepFirst(Map<String, String> labels, String album, String? artist) {
    if (artist == null) return;
    final String? current = labels[album];
    if (current == null || artist.compareTo(current) < 0) {
      labels[album] = artist;
    }
  }

  for (final _SongKey key in keys) {
    keepFirst(
        albumArtists, key._albumId, _SongKey._fold(key.track.albumArtistName));
    keepFirst(trackArtists, key._albumId, key._artist);
  }
  for (final _SongKey key in keys) {
    key.albumLabel = albumArtists[key._albumId] ?? trackArtists[key._albumId];
  }
}

/// A song with what it is ordered by, folded once so a large library isn't
/// re-folded on every comparison. The tie-breakers are folded only when a
/// comparison gets that far.
class _SongKey {
  factory _SongKey(
    Track track,
    SongSortField field,
    Map<String, DateTime> addedAt,
  ) {
    final String title = _fold(track.title) ?? '';
    final String titleSection = _sectionOf(title);
    switch (field) {
      case SongSortField.title:
        return _SongKey._(track, title, titleSection, section: titleSection);
      case SongSortField.artist:
      case SongSortField.album:
        final String? value = _fold(
          field == SongSortField.artist ? track.artistName : track.albumName,
        );
        return _SongKey._(
          track,
          title,
          titleSection,
          value: value,
          section: value == null ? kUnknownSongSection : _sectionOf(value),
          missing: value == null,
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

  late final String? _artist = _fold(track.artistName);
  late final String? _album = _fold(track.albumName);

  /// The artist this song's album is filed under, set by [_labelAlbums] when
  /// sorting by album, so two artists' "Greatest Hits" stay apart instead of
  /// interleaving track by track.
  String? albumLabel;

  /// The album the song groups under on the Albums tab, so two albums sharing
  /// a name and artist still never interleave.
  late final String _albumId = albumIdForTrack(track);

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
    final int byAlbum = _nullsLast(a._album, b._album);
    if (byAlbum != 0) return byAlbum;
    return _compareAlbumOrder(a, b);
  }

  /// One album name's songs: by the album's artist, then in album order.
  static int compareAlbumTies(_SongKey a, _SongKey b) {
    final int byArtist = _nullsLast(a.albumLabel, b.albumLabel);
    if (byArtist != 0) return byArtist;
    return _compareAlbumOrder(a, b);
  }

  /// By album, then the album's own disc and track order, then title.
  static int _compareAlbumOrder(_SongKey a, _SongKey b) {
    final int byAlbum = a._albumId.compareTo(b._albumId);
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
