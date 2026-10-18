import 'dart:async';

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
import 'song_sort.dart';
import 'source_availability_providers.dart';
import 'source_preference_controller.dart';
import 'unified_library_providers.dart';

/// The order the Songs list is in, remembered across launches (#893).
///
/// Starts on [SongSort.fallback] and moves to the stored order once the read
/// lands. An order the user picks before then wins over the stored one, the
/// same rule the remembered Library tab follows. A storage failure on either
/// side only costs the memory of the choice, never the choice itself.
class SongSortController extends Notifier<SongSort> {
  bool _loadStarted = false;

  /// Whether the user has picked an order in this session, so a late stored
  /// value can't take it back.
  bool _chosen = false;

  /// Writes run one after another, so a slow write can't land after a newer
  /// one and store an order the user already left.
  Future<void> _writes = Future<void>.value();

  @override
  SongSort build() {
    if (!_loadStarted) {
      _loadStarted = true;
      unawaited(_load());
    }
    return SongSort.fallback;
  }

  Future<void> _load() async {
    final String? stored;
    try {
      stored = await ref.read(librarySongSortStoreProvider).read();
    } catch (_) {
      // No remembered order: the list stays by title, as it always was.
      return;
    }
    final SongSort? sort = SongSort.byName(stored);
    if (_chosen || sort == null) return;
    state = sort;
  }

  /// Sorts the Songs list by [sort] and remembers it.
  ///
  /// Stored even when it is the order already on screen: until the stored
  /// order has loaded the list shows the fallback, and picking it then means
  /// it.
  void select(SongSort sort) {
    _chosen = true;
    state = sort;
    final LibrarySongSortStore store = ref.read(librarySongSortStoreProvider);
    _writes = _writes.then((_) async {
      try {
        await store.write(sort.name);
      } catch (_) {
        // The order still applies for this session; the next launch simply
        // opens on the last one that was saved.
      }
    });
  }
}

final songSortControllerProvider =
    NotifierProvider<SongSortController, SongSort>(SongSortController.new);

/// When each Library song first arrived, keyed by [Track.uri], for the "Date
/// added" orders (#893).
///
/// These are the first-seen times RecordingMusicLibraryRepository stamps on
/// every scan and sync, the same ones behind the Recently added mix: never a
/// release date or a file's modification time. A song held by more than one
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
  final Map<String, DateTime> stored;
  try {
    stored = await store.load();
  } catch (_) {
    // A store that can't be read sorts every song as undated rather than
    // leaving the list waiting on it.
    return const <String, DateTime>{};
  }
  final Map<String, DateTime> bySong = <String, DateTime>{};
  for (final LogicalTrack song in songs) {
    DateTime? earliest;
    for (final TrackSourceCandidate copy in song.candidates) {
      final DateTime? at = firstSeenAt(copy.track, stored);
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
