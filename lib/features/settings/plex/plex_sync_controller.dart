import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/album.dart';
import '../../../core/models/artist.dart';
import '../../../core/models/track.dart';
import '../../../core/repositories/incremental_catalog_writer.dart';
import '../../../core/repositories/music_library_repository.dart';
import '../../../core/sources/plex/plex_exception.dart';
import '../../../core/sources/plex/plex_music_source.dart';
import '../../../data/repositories/music_library_repository_provider.dart';
import '../../../data/repositories/plex_sync_cache_store_provider.dart';
import '../../library/library_controller.dart';
import 'plex_settings_controller.dart';
import 'plex_sync_state.dart';

/// Drives the "Sync Plex library" action — built to stay smooth on large
/// libraries (1000+ tracks), where the old one-shot sync froze the UI.
///
/// Three things keep a scan off the UI thread and incremental:
///  - **Scanning is off-isolate.** Reading the catalog goes through
///    [PlexMusicSource]/[PlexClient], which decodes big library pages on a
///    background isolate (the heaviest synchronous step). Only **tracks** are
///    read: albums/artists are derived from tracks by the library screen
///    (`library_browse_providers.dart`) and are *not* persisted, so fetching
///    them was three full library walks of wasted work.
///  - **Writing is batched.** Results are stored through the
///    `MusicLibraryRepository` under the stable `plex` source id — the same
///    catalog the Library screen reads — but in chunks of [_writeBatchSize] via
///    [IncrementalCatalogWriter] when available, refreshing after the first
///    chunk so the library fills progressively instead of after one big write.
///  - **Unchanged libraries are skipped — across restarts.** A content
///    signature of the last successful sync is kept, and persisted (see
///    [PlexSyncCacheStore]); a re-sync (a re-tapped *Sync* button, a same-server
///    reconnect, or a selection toggle that settles back to an already-synced
///    set) that finds the same content skips the whole database rebuild +
///    refresh — even on the first sync after a restart, which the old in-memory
///    signature could not. The durable catalog itself already lives in SQLite,
///    so the app never re-scans Plex on launch just to show the library; this
///    avoids redundant *re*-syncs rebuilding it.
///
/// Playback is untouched: a scan only writes the catalog, never the player. A
/// `plex:` track resolves its stream URL lazily at play time, so music keeps
/// playing — and new tracks stay playable — throughout a sync.
///
/// Unlike Jellyfin/Subsonic (which sync the whole server), the Plex library is
/// **scoped by the user's selected music sections**, so the catalog mirrors the
/// selection: a sync against an empty selection (or an empty result) **replaces**
/// the stored Plex rows, so deselecting a library removes its tracks. Re-running
/// against unchanged content is the only case that skips the write.
///
/// The settings controller kicks [syncAfterSelectionChange] after every
/// committed selection change, so picking a library populates the Library screen
/// on its own. Rapid checkbox toggles coalesce: changes that land while a sync
/// is running mark it dirty and the finished sync re-runs once against the
/// newest selection, instead of queueing one full library walk per tap.
///
/// Security: the source mints any authenticated stream URL lazily at play time,
/// so nothing persisted here carries a credential, and the content signature is
/// built from credential-free catalog fields only — so the durable
/// [PlexSyncCacheStore] record (a one-way content hash plus the non-secret
/// server id) holds no secret either. This controller never logs the session,
/// and surfaces only friendly, secret-free messages through [PlexSyncState].
class PlexSyncController extends Notifier<PlexSyncState> {
  /// Guards against overlapping syncs (an auto-sync racing a manual tap). Set
  /// synchronously before any await so a second concurrent call simply bails,
  /// satisfying "never run two syncs at once" without cancelling the first.
  bool _syncing = false;

  /// Set when a selection change lands while a sync is already running, so
  /// the in-flight sync re-runs once when it finishes — the catalog must end
  /// on the newest selection, not the one the first walk started with.
  bool _selectionChangedDuringSync = false;

  /// Content signature of the last successful sync (selection + the scanned
  /// tracks). When a fresh scan produces the same signature, the database
  /// rebuild and the library refresh are skipped — the expensive part of a
  /// re-sync of an unchanged library. Seeded once per controller from the
  /// durable [PlexSyncCacheStore] (see [_signatureLoaded]) and persisted back
  /// after each successful rebuild, so the "nothing changed" fast path survives
  /// a restart — not just the SQLite catalog it guards, which already did.
  String? _lastSyncedSignature;

  /// Whether [_lastSyncedSignature] has been seeded from the durable
  /// [PlexSyncCacheStore] yet. The first sync of a fresh controller (e.g. just
  /// after a restart restored the session) loads the persisted signature once,
  /// so an unchanged library is recognised across launches; later syncs reuse
  /// the in-memory value the previous write left behind.
  bool _signatureLoaded = false;

  /// How many tracks are written per batch. 100 keeps each main-isolate
  /// serialization step small while bounding the number of progress refreshes.
  static const int _writeBatchSize = 100;

  @override
  PlexSyncState build() => const PlexSyncState();

  /// The manual "Sync Plex library" action. Scans the selected sections and
  /// replaces the Plex slice of the local catalog. Reflects scanning / writing /
  /// done / error through [state]; never throws.
  Future<void> sync() => _runSync();

  /// Keeps the catalog in step after a library-selection change. Coalesces:
  /// if a sync is already running it only marks it dirty (one re-run at the
  /// end), so toggling several checkboxes doesn't stack full library walks.
  Future<void> syncAfterSelectionChange() {
    if (_syncing) {
      _selectionChangedDuringSync = true;
      return Future<void>.value();
    }
    return _runSync();
  }

  /// Removes every synced Plex row from the local catalog and refreshes the
  /// Library screen. Used on disconnect (the rows are unplayable without a
  /// session — phase 1 has no offline cache) and when connecting to a
  /// different server (the old rows' ratingKeys belong to another machine).
  ///
  /// Quiet by design: it reports nothing through [state] — the caller owns the
  /// user-facing message — but throws on a storage failure so the caller can
  /// phrase that message honestly. Resets the content signature — the in-memory
  /// value and the durable [PlexSyncCacheStore] record — so the next sync
  /// rebuilds rather than mistaking the freshly-emptied slice for "already in
  /// sync" with a future server's identical content.
  Future<void> removeSyncedCatalog() async {
    await _writeCatalogInBatches(const <Track>[]);
    _lastSyncedSignature = _signatureFor(const <String>[], const <Track>[]);
    // The durable signature described the rows just cleared; forget it (and
    // mark it loaded) so the next sync rebuilds rather than skipping against a
    // stale fingerprint. Best-effort and last, so a write failure above still
    // propagates to the caller unchanged.
    _signatureLoaded = true;
    await _clearPersistedSignature();
  }

  Future<void> _runSync() async {
    if (_syncing) return;
    _syncing = true;
    try {
      do {
        _selectionChangedDuringSync = false;
        await _syncOnce();
      } while (_selectionChangedDuringSync);
    } finally {
      _syncing = false;
    }
  }

  Future<void> _syncOnce() async {
    final PlexMusicSource? source = ref.read(plexMusicSourceProvider);
    if (source == null) {
      state = const PlexSyncState.error(
        'Connect to your Plex server in Settings before syncing.',
      );
      return;
    }

    final List<String> sectionKeys = source.session.selectedSectionKeys;
    try {
      // 0. Seed the "nothing changed" signature from the durable cache once, so
      //    an unchanged library is recognised even on the first sync after a
      //    restart restored the session (not just within a single run).
      await _ensureSignatureLoaded(source.session.machineIdentifier);

      // 1. Read the library from the server. An empty selection is an empty
      //    library by definition, so it touches no network — and still flows
      //    through the same write path so a previously wider selection's rows
      //    are pruned. The scan itself decodes off the UI isolate.
      final List<Track> tracks;
      if (sectionKeys.isEmpty) {
        tracks = const <Track>[];
      } else {
        state = const PlexSyncState.scanning();
        tracks = await source.fetchTracks();
      }

      // 2. Skip the whole rebuild when nothing changed since the last sync.
      final String signature = _signatureFor(sectionKeys, tracks);
      if (signature == _lastSyncedSignature) {
        state = PlexSyncState.done(
          trackCount: tracks.length,
          message: _doneMessage(sectionKeys, tracks.length, upToDate: true),
        );
        return;
      }

      // 3. Write progressively so the library fills as the sync goes, instead
      //    of staying blank until one monolithic write finishes.
      state = PlexSyncState.syncing(trackCount: tracks.length);
      await _writeCatalogInBatches(tracks);
      _lastSyncedSignature = signature;
      // Remember this outcome so a re-sync of an unchanged library on the next
      // launch can skip the rebuild above. Best-effort: a cache write failure
      // only costs one redundant rebuild, never the sync itself.
      await _persistSignature(source.session.machineIdentifier, signature);

      state = PlexSyncState.done(
        trackCount: tracks.length,
        message: _doneMessage(sectionKeys, tracks.length, upToDate: false),
      );
    } on PlexException catch (error) {
      state = PlexSyncState.error(_friendlyMessage(error));
    } catch (_) {
      state = const PlexSyncState.error(_savingFailedMessage);
    }
  }

  /// Seeds [_lastSyncedSignature] from the durable [PlexSyncCacheStore] the
  /// first time this controller syncs, scoped to the current server's
  /// [machineIdentifier]. Idempotent (runs once per controller) and best-effort:
  /// a missing record — or a read hiccup — leaves the signature null, so the
  /// sync simply rebuilds, the safe default. Only seeds when nothing is set yet,
  /// so an in-session value from an earlier write always wins over the durable
  /// one.
  Future<void> _ensureSignatureLoaded(String machineIdentifier) async {
    if (_signatureLoaded) return;
    _signatureLoaded = true;
    if (_lastSyncedSignature != null) return;
    try {
      _lastSyncedSignature = await ref
          .read(plexSyncCacheStoreProvider)
          .readSignature(machineIdentifier);
    } catch (_) {
      // A cache read hiccup just means the next sync rebuilds; never fatal.
    }
  }

  /// Persists [signature] as the last successful sync for [machineIdentifier].
  /// Best-effort: a write failure must not fail a sync whose catalog write has
  /// already succeeded — it only costs a redundant rebuild on the next launch.
  Future<void> _persistSignature(
    String machineIdentifier,
    String signature,
  ) async {
    try {
      await ref
          .read(plexSyncCacheStoreProvider)
          .writeSignature(machineIdentifier, signature);
    } catch (_) {
      // Best-effort: swallow so the sync still reports success.
    }
  }

  /// Forgets the durable signature. Best-effort: a failure only costs a
  /// redundant rebuild on the next sync.
  Future<void> _clearPersistedSignature() async {
    try {
      await ref.read(plexSyncCacheStoreProvider).clear();
    } catch (_) {
      // Best-effort: swallow (see [_persistSignature]).
    }
  }

  /// Replaces the Plex slice of the catalog with [tracks] in chunks, refreshing
  /// the Library screen after the first chunk so it isn't blank while the rest
  /// streams in. Falls back to a single whole-slice write when the repository
  /// has no [IncrementalCatalogWriter] capability (some test fakes). Other
  /// sources' rows are untouched (the write is scoped by `sourceId`).
  Future<void> _writeCatalogInBatches(List<Track> tracks) async {
    final MusicLibraryRepository repository =
        ref.read(musicLibraryRepositoryProvider);

    if (repository is! IncrementalCatalogWriter) {
      await repository.upsertCatalog(
        sourceId: PlexMusicSource.sourceId,
        tracks: tracks,
        albums: const <Album>[],
        artists: const <Artist>[],
      );
      await _refreshLibrary();
      return;
    }

    final IncrementalCatalogWriter writer =
        repository as IncrementalCatalogWriter;
    final List<List<Track>> batches = _chunk(tracks, _writeBatchSize);

    if (batches.isEmpty) {
      // No tracks — still clear the slice (deselected, or an empty library).
      await writer.beginCatalogReplacement(
        sourceId: PlexMusicSource.sourceId,
        tracks: const <Track>[],
      );
      await _refreshLibrary();
      return;
    }

    for (int i = 0; i < batches.length; i++) {
      if (i == 0) {
        await writer.beginCatalogReplacement(
          sourceId: PlexMusicSource.sourceId,
          tracks: batches[i],
        );
        // First chunk visible immediately.
        await _refreshLibrary();
      } else {
        await writer.appendToCatalog(
          sourceId: PlexMusicSource.sourceId,
          tracks: batches[i],
        );
      }
    }

    // One final refresh once every chunk has landed (a single-chunk sync
    // already refreshed above).
    if (batches.length > 1) {
      await _refreshLibrary();
    }
  }

  Future<void> _refreshLibrary() =>
      ref.read(libraryControllerProvider.notifier).refresh();

  /// Splits [tracks] into runs of at most [size]. An empty list yields no
  /// batches (the caller still clears the slice explicitly).
  List<List<Track>> _chunk(List<Track> tracks, int size) {
    if (tracks.isEmpty) return const <List<Track>>[];
    final List<List<Track>> batches = <List<Track>>[];
    for (int i = 0; i < tracks.length; i += size) {
      batches.add(tracks.sublist(i, math.min(i + size, tracks.length)));
    }
    return batches;
  }

  /// A stable, credential-free fingerprint of a sync's outcome: the selected
  /// sections plus the scanned tracks' identity and display fields. Two scans
  /// with the same signature describe the same library, so the second can skip
  /// the rebuild. Order-independent over tracks (a server reordering its listing
  /// is not a real change); the selection and track count are folded in so a
  /// changed selection or a different count always re-syncs.
  String _signatureFor(List<String> sectionKeys, List<Track> tracks) {
    final List<String> sortedSections = List<String>.of(sectionKeys)..sort();
    final Iterable<int> trackHashes = tracks.map(
      (Track t) => Object.hash(
        t.id,
        t.title,
        t.artistName,
        t.albumName,
        t.duration.inMilliseconds,
        t.trackNumber,
        t.artworkUri?.toString(),
      ),
    );
    final int content = Object.hashAllUnordered(trackHashes);
    return '${sortedSections.join(',')}|${tracks.length}|$content';
  }

  static const String _savingFailedMessage =
      'Something went wrong saving your Plex library. Please try again.';

  String _tracksLabel(int trackCount) =>
      trackCount == 1 ? '1 track' : '$trackCount tracks';

  /// The friendly line for a finished sync, branching on selection/result, and
  /// noting when nothing changed.
  String _doneMessage(
    List<String> sectionKeys,
    int trackCount, {
    required bool upToDate,
  }) {
    if (sectionKeys.isEmpty) {
      return 'No music libraries are selected — choose at least one '
          'above to sync its music.';
    }
    if (trackCount == 0) {
      return 'Your selected libraries have no tracks yet — nothing to sync.';
    }
    if (upToDate) {
      return 'Your Plex library is already up to date '
          '(${_tracksLabel(trackCount)}).';
    }
    return 'Synced ${_tracksLabel(trackCount)} from your Plex libraries.';
  }

  /// Turns a typed Plex failure into a friendly, actionable line. Branches on
  /// [PlexErrorKind] rather than message text, and never carries the token —
  /// every string here is static.
  String _friendlyMessage(PlexException error) {
    switch (error.kind) {
      case PlexErrorKind.notReachable:
        return "Couldn't reach your Plex server. Check your connection and "
            'that the server is online.';
      case PlexErrorKind.unauthorized:
        return 'Your Plex session was rejected by the server. Disconnect and '
            'connect again with a new token.';
      case PlexErrorKind.notPlex:
        return "That server didn't respond like a Plex Media Server. "
            'Double-check the server address in Settings.';
      case PlexErrorKind.serverError:
        return 'Your Plex server reported an error. Try again in a moment.';
      case PlexErrorKind.notFound:
        return "A selected library wasn't found on your Plex server. Refresh "
            'your music libraries in Settings, then sync again.';
      // The factory messages for these already carry specific, actionable,
      // token-free wording (which port Plex listens on, the unsupported-
      // version hint, …), so surface them as-is.
      case PlexErrorKind.invalidUrl:
      case PlexErrorKind.unsupportedResponse:
      case PlexErrorKind.unexpected:
        return error.message;
    }
  }
}

final plexSyncControllerProvider =
    NotifierProvider<PlexSyncController, PlexSyncState>(
  PlexSyncController.new,
);
