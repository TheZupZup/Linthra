import '../../core/catalog/search_tokens.dart';
import '../../core/catalog/search_typos.dart';
import '../../core/models/album.dart';
import '../../core/models/artist.dart';
import '../../core/models/track.dart';

/// The Library search box's matching rules, shared by every tab: each word
/// typed must start a word of the item, in any order, ignoring case and
/// accents. "puppets metal" finds "Master of Puppets" by Metallica; "ica"
/// does not, since it starts no word. A word that starts no word of any item
/// is matched within its typos instead, so "metalica" finds Metallica.
///
/// They are the Rust core's rules (see search_tokens.dart). The Songs tab of
/// a large library answers from an index instead (song_search_index.dart);
/// these direct filters are what it falls back to, so both must agree.

/// The tokens of [fields], as the search sees them.
List<String> _tokensOf(Iterable<String?> fields) => <String>[
      for (final String? field in fields)
        if (field != null && field.isNotEmpty) ...searchTokens(field),
    ];

/// [items] whose [fields] match [query]. A blank query keeps everything (the
/// same list instance); a query with no words in it ("!!!") matches nothing.
List<T> _filter<T>(
  List<T> items,
  String query,
  Iterable<String?> Function(T item) fields,
) {
  if (query.trim().isEmpty) return items;
  final List<String> terms = searchTokens(query);
  if (terms.isEmpty) return <T>[];
  final List<List<String>> tokens = <List<String>>[
    for (final T item in items) _tokensOf(fields(item)),
  ];
  // A word that starts no token of any item is matched within its typos.
  final List<bool Function(String token)>? matchers = termMatchers(
    terms,
    <String>{for (final List<String> t in tokens) ...t},
  );
  if (matchers == null) return <T>[];
  return <T>[
    for (int i = 0; i < items.length; i++)
      if (matchers.every(tokens[i].any)) items[i],
  ];
}

/// The fields a song is found by: the same as the Rust index is given.
Iterable<String?> songSearchFields(Track track) => <String?>[
      track.title,
      track.artistName,
      track.albumName,
      track.albumArtistName,
    ];

/// Songs matching [query] by title, artist, album or album artist.
List<Track> filterTracks(List<Track> tracks, String query) =>
    _filter(tracks, query, songSearchFields);

/// Albums matching [query] by album title or album artist.
List<Album> filterAlbums(List<Album> albums, String query) => _filter(
      albums,
      query,
      (Album album) => <String?>[album.title, album.artistName],
    );

/// Artists matching [query] by name.
List<Artist> filterArtists(List<Artist> artists, String query) =>
    _filter(artists, query, (Artist artist) => <String?>[artist.name]);
