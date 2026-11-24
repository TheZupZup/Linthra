import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/catalog/search_tokens.dart';
import '../../core/models/track.dart';
import '../../core/native/linthra_core.dart';
import 'library_search.dart';
import 'unified_library_providers.dart';

/// Below this many songs the Songs tab filters directly ([filterTracks]):
/// that already answers within a frame, and an index would cost a background
/// isolate for nothing.
const int kIndexedSongSearchMinimum = 2000;

/// An index over one exact list of songs, answering the Library search with
/// the same rules as [filterTracks], built once per catalog change.
///
/// Backed by the Rust core when the build has it, and by [DartSearchIndex]
/// otherwise; both find the same songs (test/fixtures/search_cases.txt).
class SongSearchIndex {
  SongSearchIndex._(
    this.tracks,
    this._matchPositions,
    this._dispose, [
    this._bestIds,
  ]);

  /// The list the index was built from. Positions only mean something for
  /// this exact instance; a newer catalog needs a newer index.
  final List<Track> tracks;

  final Uint32List Function(String query) _matchPositions;
  final void Function() _dispose;

  /// The uris of the best matches, best first, when the index ranks (the
  /// Rust one); null for the Dart one, which only filters.
  final List<String> Function(String query, int limit)? _bestIds;

  late final Map<String, Track> _byUri = <String, Track>{
    for (final Track track in tracks) track.uri: track,
  };

  /// The best [limit] songs for [query], best first, or null when this index
  /// does not rank (then the caller ranks what [filter] finds).
  List<Track>? best(String query, int limit) {
    final List<String> Function(String query, int limit)? bestIds = _bestIds;
    if (bestIds == null) return null;
    return <Track>[
      for (final String uri in bestIds(query, limit))
        if (_byUri[uri] case final Track track) track,
    ];
  }

  /// [tracks] that match [query], in their original order. A blank query
  /// keeps everything.
  List<Track> filter(String query) {
    if (query.trim().isEmpty) return tracks;
    return <Track>[
      for (final int position in _matchPositions(query)) tracks[position],
    ];
  }

  void dispose() => _dispose();
}

/// Builds the index for [tracks] on a background isolate: with the Rust core
/// when [useRustCore] (by default, when this build has it), with Dart
/// otherwise. Tests pass [useRustCore] to cover both.
Future<SongSearchIndex> buildSongSearchIndex(
  List<Track> tracks, {
  bool? useRustCore,
}) async {
  if (useRustCore ?? LinthraCore.isAvailable) {
    final List<NativeSearchRecord> records = <NativeSearchRecord>[
      for (final Track track in tracks)
        NativeSearchRecord(
          id: track.uri,
          title: track.title,
          artist: track.artistName ?? '',
          album: track.albumName ?? '',
          albumArtist: track.albumArtistName,
          // Not searched in the Library: a unified song can come from
          // several servers at once.
          provider: '',
        ),
    ];
    final int? address =
        await Isolate.run(() => NativeSearchIndex.buildDetached(records));
    if (address != null) {
      final NativeSearchIndex native = NativeSearchIndex.adopt(address);
      return SongSearchIndex._(
        tracks,
        native.matchPositions,
        native.dispose,
        (String query, int limit) => native.search(query, limit: limit),
      );
    }
    // The Rust core failed to load on the worker isolate: fall through.
  }
  final List<SearchableTrack> searchable = <SearchableTrack>[
    for (final Track track in tracks)
      SearchableTrack(
        title: track.title,
        artist: track.artistName ?? '',
        album: track.albumName ?? '',
        albumArtist: track.albumArtistName,
        provider: '',
      ),
  ];
  final DartSearchIndex dart =
      await Isolate.run(() => DartSearchIndex(searchable));
  return SongSearchIndex._(tracks, dart.matchPositions, () {});
}

/// The Songs tab's search index for the current catalog, or null for a
/// catalog small enough to filter directly. While it builds (or if building
/// fails), the tab filters with [filterTracks], which finds the same songs.
final songSearchIndexProvider = FutureProvider<SongSearchIndex?>((ref) async {
  final List<Track> tracks = ref.watch(libraryUnifiedTracksProvider);
  if (tracks.length < kIndexedSongSearchMinimum) return null;

  bool disposed = false;
  ref.onDispose(() => disposed = true);
  final SongSearchIndex index = await buildSongSearchIndex(tracks);
  if (disposed) {
    // The catalog changed while this one was being built: nobody will read
    // it, so free it now rather than at the next collection.
    index.dispose();
    return null;
  }
  ref.onDispose(index.dispose);
  return index;
});

/// The Songs tab's matches for [query] in [songs]: from [index] when it was
/// built from this exact list, by filtering directly otherwise.
List<Track> searchSongs(
  List<Track> songs,
  String query,
  SongSearchIndex? index,
) {
  if (index != null && identical(index.tracks, songs)) {
    return index.filter(query);
  }
  return filterTracks(songs, query);
}
