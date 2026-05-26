import '../../core/models/album.dart';
import '../../core/models/artist.dart';
import '../../core/models/track.dart';

/// Pure, dependency-free text matching for the Library search box.
///
/// All comparisons run through [foldText] so search is case-insensitive and,
/// where practical, accent-insensitive: typing "beyonce" finds "Beyoncé" and
/// "amelie" finds "Amélie". The folding is intentionally small and offline (a
/// fixed Latin diacritics table rather than a Unicode-normalization package), so
/// it adds no dependency and never reaches the network — there is nothing here
/// that could expose a token or an authenticated URL.

/// Common single-codepoint Latin diacritics mapped to their unaccented base, so
/// folding stays a cheap table lookup. Keys are lower-case; callers lower-case
/// first. Anything not listed passes through unchanged.
const Map<String, String> _diacritics = <String, String>{
  'á': 'a',
  'à': 'a',
  'â': 'a',
  'ä': 'a',
  'ã': 'a',
  'å': 'a',
  'ā': 'a',
  'ă': 'a',
  'ą': 'a',
  'ç': 'c',
  'ć': 'c',
  'č': 'c',
  'ċ': 'c',
  'ď': 'd',
  'đ': 'd',
  'é': 'e',
  'è': 'e',
  'ê': 'e',
  'ë': 'e',
  'ē': 'e',
  'ė': 'e',
  'ę': 'e',
  'ě': 'e',
  'ğ': 'g',
  'í': 'i',
  'ì': 'i',
  'î': 'i',
  'ï': 'i',
  'ī': 'i',
  'į': 'i',
  'ı': 'i',
  'ł': 'l',
  'ľ': 'l',
  'ñ': 'n',
  'ń': 'n',
  'ň': 'n',
  'ó': 'o',
  'ò': 'o',
  'ô': 'o',
  'ö': 'o',
  'õ': 'o',
  'ø': 'o',
  'ō': 'o',
  'ő': 'o',
  'ŕ': 'r',
  'ř': 'r',
  'š': 's',
  'ś': 's',
  'ş': 's',
  'ș': 's',
  'ť': 't',
  'ț': 't',
  'ú': 'u',
  'ù': 'u',
  'û': 'u',
  'ü': 'u',
  'ū': 'u',
  'ů': 'u',
  'ű': 'u',
  'ý': 'y',
  'ÿ': 'y',
  'ž': 'z',
  'ź': 'z',
  'ż': 'z',
  'ß': 'ss',
  'œ': 'oe',
  'æ': 'ae',
};

/// Lower-cases [input], strips common diacritics, and collapses runs of
/// whitespace to a single space (trimmed). The result is the canonical form
/// used both for matching and for stable grouping keys, so "  The   Café " and
/// "the cafe" fold to the same value.
String foldText(String input) {
  final String lower = input.toLowerCase();
  final StringBuffer out = StringBuffer();
  bool lastWasSpace = false;
  for (int i = 0; i < lower.length; i++) {
    final String ch = lower[i];
    if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') {
      if (!lastWasSpace) {
        out.write(' ');
        lastWasSpace = true;
      }
      continue;
    }
    lastWasSpace = false;
    out.write(_diacritics[ch] ?? ch);
  }
  return out.toString().trim();
}

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
