import 'dart:convert';

import '../models/album.dart';
import '../models/artist.dart';
import '../models/track.dart';
import 'text_folding.dart';

/// Derives [Album] and [Artist] groupings from the flat track catalog.
///
/// Why derive instead of persist: the only stable, offline catalog Linthra
/// keeps is the track table — album/artist *IDs* from a source (e.g. Jellyfin's
/// `AlbumId`) are not stored on a [Track] today, so there are no stable IDs to
/// group by. Grouping here by the tracks' own metadata is therefore the honest,
/// source-uniform approach: it works identically for Jellyfin tracks (which
/// carry real album/artist names) and local files (which usually carry neither,
/// and so fold into a single "Unknown Album" / "Unknown Artist"). Persisting
/// source album/artist IDs for sharper grouping is a documented follow-up.
///
/// Lives in `core` so both the Library UI and the Android Auto browse tree share
/// one grouping implementation (the browse tree must not reach into the library
/// feature). Grouping keys are built from [foldText], so case and accents never
/// split one album/artist into two. Album identity is (album title + artist) so
/// two different artists' "Greatest Hits" stay distinct; tracks with no album
/// fold into one "Unknown Album" regardless of artist. All ordering uses total
/// comparators (every tie broken down to the stable id), so a given catalog
/// always produces the exact same order — sorting is predictable and stable.

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

/// The stable album id [track] belongs to. Tracks with no album title share the
/// single [_unknownAlbumId]; otherwise the id is `al-` + a base64url encoding of
/// the (title, artist) key. Every character is URL-safe (so the id can ride in
/// a route path — or an Android Auto media id — untouched) and the `al-` prefix
/// can never produce the unknown sentinel, so the two never collide.
String albumIdForTrack(Track track) {
  final String album = foldText(track.albumName ?? '');
  if (album.isEmpty) return _unknownAlbumId;
  final String artist = foldText(track.artistName ?? '');
  return 'al-${_encode(_albumKey(album, artist))}';
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

/// Tracks on the album [albumId], in playable album order: by track number
/// (numbered first, ascending), then title, then id. No disc number is stored
/// on a [Track], so numbering is the finest order available.
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
  final int? an = a.trackNumber;
  final int? bn = b.trackNumber;
  if (an != null && bn != null && an != bn) return an.compareTo(bn);
  if (an != null && bn == null) return -1;
  if (an == null && bn != null) return 1;
  final int byTitle = foldText(a.title).compareTo(foldText(b.title));
  if (byTitle != 0) return byTitle;
  return a.id.compareTo(b.id);
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
  String? _artist;
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
    final String? artist = track.artistName;
    if ((_artist == null || _artist!.isEmpty) &&
        artist != null &&
        artist.isNotEmpty) {
      _artist = artist;
    }
    _artwork ??= track.artworkUri;
  }

  Album toAlbum(String id) {
    return Album(
      id: id,
      title: (_title == null || _title!.isEmpty) ? kUnknownAlbum : _title!,
      artistName: (_artist != null && _artist!.isNotEmpty) ? _artist : null,
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
