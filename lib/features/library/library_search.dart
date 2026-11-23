import '../../core/catalog/search_tokens.dart';
import '../../core/models/album.dart';
import '../../core/models/artist.dart';
import '../../core/models/track.dart';

/// The Library search box's matching rules, shared by every tab: each word
/// typed must start a word of the item, in any order, ignoring case and
/// accents. "puppets metal" finds "Master of Puppets" by Metallica; "ica"
/// does not, since it starts no word.
///
/// They are the Rust core's rules (see search_tokens.dart). The Songs tab of
/// a large library answers from an index instead (song_search_index.dart);
/// these direct filters are what it falls back to, so both must agree.

/// True when every one of [terms] starts a token of one of [fields].
bool _matchesAll(List<String> terms, Iterable<String?> fields) {
  final List<String> tokens = <String>[
    for (final String? field in fields)
      if (field != null && field.isNotEmpty) ...searchTokens(field),
  ];
  return terms.every(
    (String term) => tokens.any((String token) => token.startsWith(term)),
  );
}

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
  return <T>[
    for (final T item in items)
      if (_matchesAll(terms, fields(item))) item,
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
