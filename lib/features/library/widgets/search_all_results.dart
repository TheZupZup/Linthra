import 'package:flutter/material.dart';

import '../../../core/catalog/search_rank.dart';
import '../../../core/models/album.dart';
import '../../../core/models/artist.dart';
import '../../../core/models/track.dart';
import '../../../shared/layout/adaptive_layout.dart';
import 'album_tile.dart';
import 'artist_tile.dart';
import 'track_tile.dart';

/// How many rows the mixed list shows. It is the shortlist a search opens on;
/// the Songs, Albums and Artists chips hold everything that matched.
const int kSearchAllLimit = 60;

/// The search's "All" view: artists, albums and songs in one list, the most
/// relevant first ([rankSearchResults]), each row saying what it is.
///
/// [songs] are the candidate songs: the best few from a ranking index, or
/// every match when there is none. Artists and albums are every match.
class SearchAllResults extends StatelessWidget {
  const SearchAllResults({
    required this.query,
    required this.artists,
    required this.albums,
    required this.songs,
    required this.onOpenArtist,
    required this.onOpenAlbum,
    super.key,
  });

  final String query;
  final List<Artist> artists;
  final List<Album> albums;
  final List<Track> songs;
  final ValueChanged<Artist> onOpenArtist;
  final ValueChanged<Album> onOpenAlbum;

  @override
  Widget build(BuildContext context) {
    final List<Object> rows = rankedSearchRows(query, artists, albums, songs);
    // Tapping a song queues the songs after it in this list, as in any list.
    final List<Track> shownSongs = <Track>[
      for (final Object row in rows)
        if (row is Track) row,
    ];
    int songIndex = 0;
    final List<Widget> tiles = <Widget>[
      for (final Object row in rows)
        switch (row) {
          final Artist artist => ArtistTile(
              key: ValueKey<String>('artist:${artist.id}'),
              artist: artist,
              kindLabel: 'Artist',
              onTap: () => onOpenArtist(artist),
            ),
          final Album album => AlbumTile(
              key: ValueKey<String>('album:${album.id}'),
              album: album,
              kindLabel: 'Album',
              onTap: () => onOpenAlbum(album),
            ),
          final Track track => TrackTile(
              key: ValueKey<String>('song:${track.uri}'),
              tracks: shownSongs,
              index: songIndex++,
            ),
          _ => const SizedBox.shrink(),
        },
    ];
    return Align(
      alignment: AlignmentDirectional.topStart,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: maxContentWidth),
        child: ListView(
          key: const Key('search_all_results'),
          children: tiles,
        ),
      ),
    );
  }
}

/// The rows of the "All" view for [query]: [artists], [albums] and [songs]
/// in [rankSearchResults] order, at most [kSearchAllLimit] of them.
List<Object> rankedSearchRows(
  String query,
  List<Artist> artists,
  List<Album> albums,
  List<Track> songs,
) {
  final List<Object> items = <Object>[...artists, ...albums, ...songs];
  final List<(SearchResultKind, String)> named = <(SearchResultKind, String)>[
    for (final Artist artist in artists) (SearchResultKind.artist, artist.name),
    for (final Album album in albums) (SearchResultKind.album, album.title),
    for (final Track song in songs) (SearchResultKind.song, song.title),
  ];
  return <Object>[
    for (final int position
        in rankSearchResults(query, named).take(kSearchAllLimit))
      items[position],
  ];
}
