import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/catalog/logical_track.dart';
import '../../core/catalog/track_unifier.dart';
import '../../core/models/track.dart';
import '../../core/repositories/library_added_store.dart';
import '../../core/repositories/library_song_sort_store.dart';
import '../../data/repositories/library_added_store_provider.dart';
import '../../data/repositories/library_song_sort_store_provider.dart';
import 'library_controller.dart';
import 'library_state.dart';
import 'remembered_sort.dart';
import 'song_sort.dart';
import 'source_availability_providers.dart';
import 'source_preference_controller.dart';
import 'unified_library_providers.dart';

/// The order the Songs list is in, remembered across launches.
class SongSortController extends RememberedSortController<SongSort> {
  @override
  SongSort get fallback => SongSort.fallback;

  @override
  SongSort? byName(String? name) => SongSort.byName(name);

  @override
  LibrarySongSortStore get store => ref.read(librarySongSortStoreProvider);
}

final songSortControllerProvider =
    NotifierProvider<SongSortController, SongSort>(SongSortController.new);

/// When each Library song first arrived, keyed by [Track.uri], for the "Date
/// added" orders.
///
/// A song's server says when it was added to it (Jellyfin's `DateCreated`,
/// Subsonic's `created`); a song whose server doesn't, a local file among
/// them, takes the first-seen time RecordingMusicLibraryRepository stamps on
/// every scan and sync. The same times are behind the Recently added mix
/// ([libraryAddedAt]): never a release date or a file's modification time. A song held by more than one
/// provider takes its earliest copy's time, under every copy's uri, so
/// changing the preferred source never moves a song in the list. A song nobody
/// stamped is left out.
///
/// Copies are grouped over the whole stored catalog, not only what is
/// reachable: a server that drops out must not hand its songs a later copy's
/// time and move them until it is back.
///
/// Recomputed whenever the catalog reloads, which is after any write that may
/// have stamped new songs. Auto-disposed, so the map is only read while a date
/// order is on screen.
final librarySongAddedAtProvider =
    FutureProvider.autoDispose<Map<String, DateTime>>((ref) async {
  final LibraryAddedStore store = ref.watch(libraryAddedStoreProvider);
  final List<Track> catalog =
      ref.watch(libraryControllerProvider.select((LibraryState s) => s.tracks));
  // With every source reachable the active library is the catalog itself, so
  // its unified songs are the ones to group by rather than unifying twice.
  final List<LogicalTrack> songs =
      identical(ref.watch(activeLibraryTracksProvider), catalog)
          ? ref.watch(libraryLogicalTracksProvider)
          : unifyTracks(catalog, ref.watch(librarySourcePriorityProvider));
  Map<String, DateTime> stored;
  try {
    stored = await store.load();
  } catch (_) {
    // A store that can't be read leaves only the servers' dates, rather than
    // leaving the list waiting on it.
    stored = const <String, DateTime>{};
  }
  final Map<String, DateTime> bySong = <String, DateTime>{};
  for (final LogicalTrack song in songs) {
    DateTime? earliest;
    for (final TrackSourceCandidate copy in song.candidates) {
      final DateTime? at = libraryAddedAt(copy.track, stored);
      if (at != null && (earliest == null || at.isBefore(earliest))) {
        earliest = at;
      }
    }
    if (earliest == null) continue;
    for (final TrackSourceCandidate copy in song.candidates) {
      bySong[copy.track.uri] = earliest;
    }
  }
  return bySong;
});
