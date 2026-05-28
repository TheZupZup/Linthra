import '../../core/catalog/text_folding.dart';
import '../../core/models/album.dart';
import '../../core/models/artist.dart';
import '../../core/models/track.dart';

/// Pure, dependency-free text matching for the Library search box.
///
/// All comparisons run through [foldText] (in `core/catalog`) so search is
/// case-insensitive and, where practical, accent-insensitive: typing "beyonce"
/// finds "Beyoncé" and "amelie" finds "Amélie".

bool _contains(String? field, String foldedQuery) =>
    field != null && field.isNotEmpty && foldText(field).contains(foldedQuery);

/// Songs matching [query] by title, artist, or album. An empty query returns
/// [tracks] unchanged (no allocation of a filtered copy is implied by callers).
List<Track> filterTracks(List<Track> tracks, String query) {
  final String q = foldText(query);
  if (q.isEmpty) return tracks;
  return <Track>[
    for (final Track t in tracks)
      if (_contains(t.title, q) ||
          _contains(t.artistName, q) ||
          _contains(t.albumName, q))
        t,
  ];
}

/// Albums matching [query] by album title or album artist.
List<Album> filterAlbums(List<Album> albums, String query) {
  final String q = foldText(query);
  if (q.isEmpty) return albums;
  return <Album>[
    for (final Album a in albums)
      if (_contains(a.title, q) || _contains(a.artistName, q)) a,
  ];
}

/// Artists matching [query] by name.
List<Artist> filterArtists(List<Artist> artists, String query) {
  final String q = foldText(query);
  if (q.isEmpty) return artists;
  return <Artist>[
    for (final Artist a in artists)
      if (_contains(a.name, q)) a,
  ];
}
