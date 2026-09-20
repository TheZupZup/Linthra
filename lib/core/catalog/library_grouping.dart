import 'dart:convert';

import '../models/album.dart';
import '../models/artist.dart';
import '../models/track.dart';
import 'text_folding.dart';

/// Derives [Album] and [Artist] groupings from the flat track catalog.
///
/// Why derive instead of persist: the only stable, offline catalog Linthra
/// keeps is the track table. Artist grouping still has no stable ID to key
/// off, so it stays name-based. Album grouping, however, prefers a track's own
/// [Track.albumId] when the source reported one (see [albumIdForTrack]), so
/// tracks belonging to the same source album stay grouped together even when
/// their per-track [Track.artistName] differs — e.g. one track is a
/// collaboration/feature and another isn't. Sources with no stable album id
/// (local files, or a source that didn't report one for a given track) fall
/// back to name-based grouping, same as before.
///
/// Lives in `core` so both the Library UI and the Android Auto browse tree share
/// one grouping implementation (the browse tree must not reach into the library
/// feature). Grouping keys are built from [foldText], so case and accents never
/// split one album/artist into two. Album identity, from most to least
/// specific:
///  1. [Track.albumId] — a source-reported, provider-namespaced stable id
///     (e.g. `jellyfin:al-1`), when present. This is the only tier that can
///     group tracks with different [Track.artistName] values into one album.
///  2. `albumName + albumArtistName` — when the source has no stable id but
///     does report a distinct album-artist, e.g. Subsonic without ID3
///     browsing.
///  3. `albumName + artistName` — the original fallback, so two different
///     artists' "Greatest Hits" still stay distinct without either signal.
/// Tracks with no album title fold into one "Unknown Album" regardless of
/// artist. Each tier's key is prefixed so ids from different tiers can never
/// collide with one another. All ordering uses total comparators (every tie
/// broken down to the stable id), so a given catalog always produces the exact
/// same order — sorting is predictable and stable.

/// Display label for tracks with no album metadata.
const String kUnknownAlbum = 'Unknown Album';

/// Display label for tracks with no artist metadata.
const String kUnknownArtist = 'Unknown Artist';

const String _unknownAlbumId = 'unknown-album';
const String _unknownArtistId = 'unknown-artist';

String _encode(String key) =>
    base64Url.encode(utf8.encode(key)).replaceAll('=', '');

/// Joins (album, artist) into a key that is injective on the pair: the album's
/// length is prefixed, so the album portion is read by length and a separator
/// inside a title can never make ("a b", "c") collide with ("a", "b c").
String _albumKey(String album, String artist) =>
    '${album.length}|$album|$artist';

/// `value` trimmed to `null` when it is null or blank, so a source's
/// empty-string field reads the same as an absent one.
String? _nonBlank(String? value) {
  final String? trimmed = value?.trim();
  return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
}

/// The stable album id [track] belongs to, tried in order:
///
///  1. [Track.albumId], when the source reported one — encoded behind an
///     `id:` tier prefix so it can never collide with a name-derived key from
///     tier 2/3 even if the raw strings happened to match.
///  2. `albumName + albumArtistName`, behind an `aa:` tier prefix, when the
///     source has no stable id but does report a distinct album artist.
///  3. `albumName + artistName`, behind an `ar:` tier prefix — the original
///     name-only fallback.
///
/// Tracks with no album title (and no [Track.albumId]) share the single
/// [_unknownAlbumId] regardless of tier. Every produced id is `al-` + a
/// base64url encoding of the tiered key: every character is URL-safe (so the
/// id can ride in a route path — or an Android Auto media id — untouched) and
/// the `al-` prefix can never produce the unknown sentinel, so the two never
/// collide.
String albumIdForTrack(Track track) {
  final String? albumId = _nonBlank(track.albumId);
  if (albumId != null) {
    return 'al-${_encode('id:$albumId')}';
  }
  final String album = foldText(track.albumName ?? '');
  if (album.isEmpty) return _unknownAlbumId;
  final String? albumArtist = _nonBlank(foldText(track.albumArtistName ?? ''));
  if (albumArtist != null) {
    return 'al-${_encode('aa:${_albumKey(album, albumArtist)}')}';
  }
  final String artist = foldText(track.artistName ?? '');
  return 'al-${_encode('ar:${_albumKey(album, artist)}')}';
}

/// The stable artist id [track] belongs to. Tracks with no artist share the
/// single [_unknownArtistId]; otherwise the id is `ar-` + a base64url encoding
/// of the folded name. See [albumIdForTrack] for the URL-safety guarantees.
String artistIdForTrack(Track track) {
  final String artist = foldText(track.artistName ?? '');
  if (artist.isEmpty) return _unknownArtistId;
  return 'ar-${_encode(artist)}';
}

/// All albums in [tracks], sorted by title then artist (then id), ascending.
List<Album> groupAlbums(List<Track> tracks) {
  final Map<String, _AlbumAgg> byId = <String, _AlbumAgg>{};
  for (final Track track in tracks) {
    byId.putIfAbsent(albumIdForTrack(track), () => _AlbumAgg()).add(track);
  }
  final List<Album> albums = <Album>[
    for (final MapEntry<String, _AlbumAgg> e in byId.entries)
      e.value.toAlbum(e.key),
  ];
  albums.sort(_albumCompare);
  return albums;
}

/// All artists in [tracks], sorted by name (then id), ascending.
List<Artist> groupArtists(List<Track> tracks) {
  final Map<String, _ArtistAgg> byId = <String, _ArtistAgg>{};
  for (final Track track in tracks) {
    byId.putIfAbsent(artistIdForTrack(track), () => _ArtistAgg()).add(track);
  }
  final List<Artist> artists = <Artist>[
    for (final MapEntry<String, _ArtistAgg> e in byId.entries)
      e.value.toArtist(e.key),
  ];
  artists.sort(_artistCompare);
  return artists;
}

/// The album with [albumId] in [tracks], or null when no track belongs to it.
Album? albumById(List<Track> tracks, String albumId) {
  for (final Album album in groupAlbums(tracks)) {
    if (album.id == albumId) return album;
  }
  return null;
}

/// The artist with [artistId] in [tracks], or null when none matches.
Artist? artistById(List<Track> tracks, String artistId) {
  for (final Artist artist in groupArtists(tracks)) {
    if (artist.id == artistId) return artist;
  }
  return null;
}

/// Tracks on the album [albumId], in playable album order: by disc number, then
/// track number (numbered first, ascending in both), then title, then id.
///
/// This is *the* album order in Linthra. The album surfaces render it and the
/// album queue actions enqueue it, so what a listener sees is what they get.
/// Disc comes before track because track numbers restart on every disc: sorted
/// by number alone, a two-disc album interleaves (d1t1, d2t1, d1t2, …) instead
/// of playing disc 1 end to end and then disc 2. [Track.discNumber] is null for
/// every source today (#85), which makes the disc tier a no-op and leaves the
/// order for single-disc albums exactly as it was.
List<Track> tracksForAlbum(List<Track> tracks, String albumId) {
  final List<Track> result = <Track>[
    for (final Track t in tracks)
      if (albumIdForTrack(t) == albumId) t,
  ];
  result.sort(_trackInAlbumCompare);
  return result;
}

/// Tracks by the artist [artistId], grouped by album then album order, so an
/// artist's catalog reads album-by-album.
List<Track> tracksForArtist(List<Track> tracks, String artistId) {
  final List<Track> result = <Track>[
    for (final Track t in tracks)
      if (artistIdForTrack(t) == artistId) t,
  ];
  result.sort(_trackForArtistCompare);
  return result;
}

/// Albums by the artist [artistId], sorted like [groupAlbums].
List<Album> albumsForArtist(List<Track> tracks, String artistId) {
  return groupAlbums(<Track>[
    for (final Track t in tracks)
      if (artistIdForTrack(t) == artistId) t,
  ]);
}

int _albumCompare(Album a, Album b) {
  final int byTitle = foldText(a.title).compareTo(foldText(b.title));
  if (byTitle != 0) return byTitle;
  final int byArtist =
      foldText(a.artistName ?? '').compareTo(foldText(b.artistName ?? ''));
  if (byArtist != 0) return byArtist;
  return a.id.compareTo(b.id);
}

int _artistCompare(Artist a, Artist b) {
  final int byName = foldText(a.name).compareTo(foldText(b.name));
  if (byName != 0) return byName;
  return a.id.compareTo(b.id);
}

int _trackInAlbumCompare(Track a, Track b) {
  final int byDisc = _byNumbering(a.discNumber, b.discNumber);
  if (byDisc != 0) return byDisc;
  final int byTrack = _byNumbering(a.trackNumber, b.trackNumber);
  if (byTrack != 0) return byTrack;
  final int byTitle = foldText(a.title).compareTo(foldText(b.title));
  if (byTitle != 0) return byTitle;
  return a.id.compareTo(b.id);
}

/// Orders one tier of optional 1-based numbering: numbered ascending, a
/// numbered value before an unnumbered one, and 0 when the two carry the same
/// number (or neither carries one) so the next tier decides. Shared by the disc
/// and track tiers, which order identically.
int _byNumbering(int? a, int? b) {
  if (a != null && b != null) return a.compareTo(b);
  if (a != null) return -1;
  if (b != null) return 1;
  return 0;
}

int _trackForArtistCompare(Track a, Track b) {
  final int byAlbum =
      foldText(a.albumName ?? '').compareTo(foldText(b.albumName ?? ''));
  if (byAlbum != 0) return byAlbum;
  return _trackInAlbumCompare(a, b);
}

/// Accumulates one album's display fields as its tracks are seen. The first
/// non-empty title/artist/artwork wins, so a stray untagged track in the group
/// can't blank out a name the others provide.
class _AlbumAgg {
  String? _title;

  /// The first [Track.albumArtistName] and the first [Track.artistName] seen,
  /// kept **separate** until [toAlbum]. Collapsing them as tracks arrive would
  /// make the label order-dependent: a first track carrying only a per-track
  /// credit ("Main Artist feat. Guest") would win and then block the real
  /// album artist a later track supplies. Resolving at the end lets any album
  /// artist in the group supersede the track-artist fallback, whatever order
  /// the tracks are aggregated in.
  String? _albumArtist;
  String? _trackArtist;

  Uri? _artwork;
  int _count = 0;

  void add(Track track) {
    _count++;
    final String? album = track.albumName;
    if ((_title == null || _title!.isEmpty) &&
        album != null &&
        album.isNotEmpty) {
      _title = album;
    }
    _albumArtist ??= _nonBlank(track.albumArtistName);
    _trackArtist ??= _nonBlank(track.artistName);
    _artwork ??= track.artworkUri;
  }

  Album toAlbum(String id) {
    // The album artist labels the album whenever *any* track in the group
    // carries one; otherwise the first track artist seen, which is the
    // pre-existing behavior for sources that report no album artist.
    return Album(
      id: id,
      title: (_title == null || _title!.isEmpty) ? kUnknownAlbum : _title!,
      artistName: _albumArtist ?? _trackArtist,
      artworkUri: _artwork,
      trackCount: _count,
    );
  }
}

/// Accumulates one artist's display fields and how many distinct albums and
/// tracks they have.
class _ArtistAgg {
  String? _name;
  Uri? _artwork;
  final Set<String> _albumIds = <String>{};
  int _trackCount = 0;

  void add(Track track) {
    _trackCount++;
    final String? artist = track.artistName;
    if ((_name == null || _name!.isEmpty) &&
        artist != null &&
        artist.isNotEmpty) {
      _name = artist;
    }
    _artwork ??= track.artworkUri;
    _albumIds.add(albumIdForTrack(track));
  }

  Artist toArtist(String id) {
    return Artist(
      id: id,
      name: (_name == null || _name!.isEmpty) ? kUnknownArtist : _name!,
      albumCount: _albumIds.length,
      trackCount: _trackCount,
      artworkUri: _artwork,
    );
  }
}
