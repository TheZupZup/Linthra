import 'dart:async';
import 'dart:io' show File;

import '../models/persisted_playback_session.dart';
import '../models/playback_state.dart';
import '../models/track.dart';
import '../repositories/playback_session_store.dart';
import '../sources/music_provider.dart';
import 'local_playback_controller.dart';

/// Persists logical playback state across unexpected process restarts and
/// restores it as a **paused** queue on the next launch.
///
/// Writes only [PersistedPlaybackSession] documents (logical track identity,
/// modes, position) — never stream URLs or tokens. On restore, remote tracks
/// are loaded through the engine's normal resolver path and [autoplay] stays
/// off so a crash/restart never blasts audio. Tracks that can't play right now
/// are left out of the engine but kept in the record; only a record that can't
/// be read at all is cleared, and restore never blocks startup.
class PlaybackSessionPersistence {
  /// [remoteAccountOf] says who a remote provider's songs would play for now
  /// (the signed-in account's fingerprint, the Plex server's
  /// `machineIdentifier`), or null while it is signed out. [queueOwnerOf]
  /// says whose songs a remote provider's queued tracks are, which a save
  /// records for the next restore to check (#767). Without [remoteAccountOf]
  /// every remote track counts as playable; without [queueOwnerOf] nothing is
  /// recorded, and records restore as they always did.
  PlaybackSessionPersistence({
    required PlaybackSessionStore store,
    required LocalPlaybackController controller,
    required Stream<PlaybackState> playbackStates,
    String? Function(MusicProvider provider)? remoteAccountOf,
    Future<String?> Function(MusicProvider provider)? queueOwnerOf,
    bool Function(String localUri)? localFileExists,
    Duration positionSaveInterval = const Duration(seconds: 10),
  })  : _store = store,
        _controller = controller,
        _remoteAccountOf = remoteAccountOf,
        _queueOwnerOf = queueOwnerOf,
        _localFileExists = localFileExists ?? _defaultLocalFileExists,
        _positionSaveInterval = positionSaveInterval {
    _subscription = playbackStates.listen(_onPlaybackState);
  }

  final PlaybackSessionStore _store;
  final LocalPlaybackController _controller;
  final String? Function(MusicProvider provider)? _remoteAccountOf;
  final Future<String?> Function(MusicProvider provider)? _queueOwnerOf;
  final bool Function(String localUri) _localFileExists;

  /// How long a run of pure position ticks is coalesced before the session is
  /// rewritten.
  ///
  /// Every save re-encodes the whole logical queue and rewrites the store's one
  /// document, so this interval is the cost of the feature: at a couple of
  /// seconds it was hundreds of encodes and disk writes an hour for a session
  /// nobody was reading — real CPU and I/O on a laptop running on battery, for
  /// a record only a crash ever consumes. Every *meaningful* moment still
  /// persists immediately (a track change, a queue edit, pause/stop, and a
  /// clean shutdown via [dispose]), so what this interval bounds is the
  /// position an unexpected kill mid-playback can lose.
  final Duration _positionSaveInterval;

  StreamSubscription<PlaybackState>? _subscription;
  Timer? _positionTimer;
  PlaybackState? _lastPersisted;

  /// The freshest state seen while a position save is pending. The debounced
  /// save writes *this*, not the state that happened to arm the timer, so a
  /// longer interval costs fewer writes without ever persisting a staler
  /// position than the moment it fires.
  PlaybackState? _pendingPositionState;

  /// The saved session behind a restore that couldn't hand the engine all of
  /// it. Saves go into it while the live queue is still the restored part, and
  /// it is let go the moment the queue is anything else.
  _HeldSession? _held;
  bool _restoring = false;
  bool _disposed = false;

  /// Bumped by every save and clear, so a save that waited on [_queueOwnerOf]
  /// can tell a newer one went out meanwhile and not land on top of it.
  int _writes = 0;

  /// Whose songs the queue saved last holds, as recorded with it.
  Map<String, String>? _lastOwners;

  /// Loads any persisted session, sanitizes it, and restores it paused onto
  /// the local engine. Best-effort: failures are swallowed and the bad record
  /// is cleared so startup can never be blocked by restore.
  ///
  /// A track that can't play at launch (a file on a drive that isn't plugged
  /// in, a server whose sign-in couldn't be read yet, another account's song)
  /// is away, not gone: it is left out of the engine but stays in the saved
  /// session until the listener picks a different queue, even when nothing at
  /// all could be restored.
  Future<void> restore() async {
    if (_disposed) return;
    _restoring = true;
    try {
      final PersistedPlaybackSession? raw;
      try {
        raw = await _store.load();
      } catch (_) {
        // The store could not be read (an I/O error on its file), which says
        // nothing about the record in it. Cleared now, the clear's own read
        // could go through and delete a saved queue that was whole. Nothing
        // is restored this launch; the next save replaces the record anyway.
        return;
      }
      if (raw == null) return;

      final PersistedPlaybackSession? saved =
          PersistedPlaybackSession.fromJson(raw.toJson());
      if (saved == null || saved.current == null) {
        await _store.clear();
        return;
      }

      // Asked once per track, so the restored queue and the map back into
      // [saved] can't disagree about a drive that appears mid-restore.
      final Map<String, bool> verdicts = <String, bool>{};
      bool restorable(Track track) => verdicts.putIfAbsent(
          track.uri, () => _isTrackRestorable(track, saved.owners));
      final PersistedPlaybackSession? session =
          PersistedPlaybackSession.fromJson(
        saved.toJson(),
        isTrackRestorable: restorable,
      );
      final List<int> restoredAt = <int>[
        for (int i = 0; i < saved.tracks.length; i++)
          if (restorable(saved.tracks[i])) i,
      ];

      if (restoredAt.length < saved.tracks.length) {
        _held = _HeldSession(
          saved: saved,
          restoredAt: restoredAt,
          startIndex: session?.currentIndex ?? 0,
        );
      }
      if (session != null) {
        final Future<void> loading = _controller.restoreSession(
          tracks: session.tracks,
          startIndex: session.currentIndex,
          position: session.position,
          shuffleEnabled: session.shuffleEnabled,
          repeatMode: session.repeatMode,
          originalOrder: session.originalOrder,
        );
        // The queue is the engine's from here. Its track may take a silent
        // server's whole timeout to load, and launch does not wait for that
        // (the window comes up meanwhile): a queue the listener picks in the
        // meantime is what the next launch has to bring back.
        _restoring = false;
        await loading;
      }
    } catch (_) {
      _held = null;
      try {
        await _store.clear();
      } catch (_) {
        // Ignore: a clear failure must not block startup either.
      }
    } finally {
      _restoring = false;
    }
  }

  void _onPlaybackState(PlaybackState state) {
    if (_disposed || _restoring) return;

    if (state.currentTrack == null) {
      // Nothing could be restored and nothing has been queued since. An idle
      // engine still publishes (a volume step, a mute), and that isn't the
      // listener emptying a queue.
      if (_held?.restoredAt.isEmpty ?? false) return;
      _held = null;
      _positionTimer?.cancel();
      _positionTimer = null;
      _pendingPositionState = null;
      _lastPersisted = null;
      _lastOwners = null;
      _writes++;
      unawaited(_clearQuietly());
      return;
    }

    // Persist immediately on structural / mode / status changes; debounce the
    // high-frequency position ticks while playing.
    final bool structuralChange = _lastPersisted == null ||
        _lastPersisted!.currentTrack?.uri != state.currentTrack?.uri ||
        !_listEqualsByUri(_lastPersisted!.upNext, state.upNext) ||
        !_listEqualsByUri(_lastPersisted!.previous, state.previous) ||
        _lastPersisted!.shuffleEnabled != state.shuffleEnabled ||
        _lastPersisted!.repeatMode != state.repeatMode ||
        _lastPersisted!.status != state.status;

    if (structuralChange) {
      _positionTimer?.cancel();
      _positionTimer = null;
      _pendingPositionState = null;
      unawaited(_persist(state));
      return;
    }

    if (state.status == PlaybackStatus.playing) {
      _pendingPositionState = state;
      _positionTimer ??= Timer(_positionSaveInterval, _flushPosition);
    } else {
      _positionTimer?.cancel();
      _positionTimer = null;
      _pendingPositionState = null;
      // Paused, and nothing the *document* holds has moved. A state can change
      // for reasons this document has no field for — a volume step or a mute,
      // which emit as fast as a slider drags — and rewriting an identical
      // session for each of those is a disk write per pointer move.
      if (_lastPersisted!.position == state.position) return;
      unawaited(_persist(state, positionOnly: true));
    }
  }

  /// Writes the freshest position seen since the debounce started.
  void _flushPosition() {
    _positionTimer = null;
    final PlaybackState? state = _pendingPositionState;
    _pendingPositionState = null;
    if (state == null || _disposed) return;
    unawaited(_persist(state, positionOnly: true));
  }

  /// Saves [state]. [positionOnly] when the queue is the one saved last, only
  /// further along it, so whose songs it holds is what was recorded then.
  Future<void> _persist(
    PlaybackState state, {
    bool positionOnly = false,
  }) async {
    final Track? current = state.currentTrack;
    if (current == null) return;
    final int write = ++_writes;

    // A queue that ran out is kept where Play takes it up again. Saved at the
    // end of its last track, the next launch put that track back there,
    // paused, and Play then played its last instant and ran out again.
    final PlaybackState kept = state.status == PlaybackStatus.completed
        ? _whereEndedQueueResumes(state)
        : state;

    // Still on the queue a partial restore gave the engine: progress goes into
    // the whole saved session, so the tracks left out at launch stay in it.
    final _HeldSession? held = _held;
    if (held != null && held.isRestoredQueue(state)) {
      await _save(held.progressedTo(kept), state);
      return;
    }
    _held = null;

    final PersistedPlaybackSession? session =
        PersistedPlaybackSession.fromPlayback(
      previous: kept.previous,
      current: kept.currentTrack!,
      upNext: kept.upNext,
      position: kept.position,
      shuffleEnabled: state.shuffleEnabled,
      repeatMode: state.repeatMode,
      // The live controller does not expose originalOrder on PlaybackState; a
      // shuffled queue is persisted in its effective order and restored as
      // already-shuffled (originalOrder null → unshuffle becomes a no-op until
      // the user toggles shuffle off/on). That keeps the document free of a
      // second secret-bearing surface while still restoring useful up-next.
      originalOrder: null,
    );
    if (session == null) return;
    final Future<String?> Function(MusicProvider provider)? ownerOf =
        _queueOwnerOf;
    if (ownerOf == null) {
      await _save(session, state);
      return;
    }
    final Map<String, String>? recorded = _lastOwners;
    if (positionOnly && recorded != null) {
      // Nothing to ask: a clean shutdown flushes this way, when there may be
      // nobody left to ask.
      await _save(session.withOwners(recorded), state);
      return;
    }
    final Map<String, String> owners = await _ownersOf(session.tracks, ownerOf);
    // A newer save or a clear went out while this one asked: this one is
    // behind it.
    if (write != _writes) return;
    await _save(session.withOwners(owners), state);
  }

  Future<void> _save(
    PersistedPlaybackSession session,
    PlaybackState state,
  ) async {
    try {
      await _store.save(session);
      _lastPersisted = state;
      _lastOwners = session.owners;
    } catch (_) {
      // Non-fatal: persistence must never break playback.
    }
  }

  /// Whose songs the remote providers' tracks among [tracks] are, as
  /// [ownerOf] says. A provider it can't answer for is left out, so at the
  /// next restore its tracks wait rather than play for whoever is signed in.
  static Future<Map<String, String>> _ownersOf(
    List<Track> tracks,
    Future<String?> Function(MusicProvider provider) ownerOf,
  ) async {
    final Set<MusicProvider> providers = <MusicProvider>{
      for (final Track track in tracks) MusicProviders.forTrackUri(track.uri),
    }..remove(MusicProviders.local);
    final Map<String, String> owners = <String, String>{};
    for (final MusicProvider provider in providers) {
      try {
        final String? owner = await ownerOf(provider);
        if (owner != null) owners[provider.sourceId] = owner;
      } catch (_) {
        // Left out: its tracks wait.
      }
    }
    return owners;
  }

  Future<void> _clearQuietly() async {
    try {
      await _store.clear();
    } catch (_) {
      // Non-fatal.
    }
  }

  /// [state], a queue that ran out, moved to where Play after the end takes
  /// it up (the controller's own rule): a track queued since the end, from its
  /// start, or else the queue from the top, in the order it played.
  static PlaybackState _whereEndedQueueResumes(PlaybackState state) {
    final List<Track> tracks = <Track>[
      ...state.previous,
      if (state.currentTrack != null) state.currentTrack!,
      ...state.upNext,
    ];
    final int at = state.upNext.isEmpty ? 0 : state.previous.length + 1;
    return PlaybackState(
      status: state.status,
      currentTrack: tracks[at],
      previous: tracks.sublist(0, at),
      hasPrevious: at > 0,
      upNext: tracks.sublist(at + 1),
      shuffleEnabled: state.shuffleEnabled,
      repeatMode: state.repeatMode,
    );
  }

  /// Whether [track] can go back in the queue now. [owners] is whose songs
  /// the record says its remote tracks are.
  bool _isTrackRestorable(Track track, Map<String, String>? owners) {
    if (!isLogicalTrackUri(track.uri)) return false;
    final MusicProvider provider = MusicProviders.forTrackUri(track.uri);
    if (identical(provider, MusicProviders.local)) {
      return _localFileExists(track.uri);
    }
    final String? Function(MusicProvider provider)? accountOf =
        _remoteAccountOf;
    if (accountOf == null) return true;
    // Signed out, or its sign-in couldn't be read yet.
    final String? account = accountOf(provider);
    if (account == null) return false;
    // Saved before the record said whose songs these are: as before.
    if (owners == null) return true;
    // Another account's or server's songs (or nobody could say whose): their
    // ids would ask this one for other songs. They stay in the record for
    // when their own account is back.
    return owners[provider.sourceId] == account;
  }

  static bool _defaultLocalFileExists(String uri) {
    // content:// and similar non-file local identities are kept; only plain
    // filesystem paths are probed so a missing file after a move is dropped.
    if (uri.contains(':') && !uri.startsWith('/')) return true;
    try {
      return File(uri).existsSync();
    } catch (_) {
      return false;
    }
  }

  static bool _listEqualsByUri(List<Track> a, List<Track> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i].uri != b[i].uri) return false;
    }
    return true;
  }

  /// Stops listening, persisting any position still waiting on the debounce so
  /// a clean shutdown records exactly where playback was. Safe to call more
  /// than once.
  Future<void> dispose() async {
    if (_disposed) return;
    // Marked disposed up front, so a second (or concurrent) dispose can't run
    // the flush again — [_persist] itself deliberately doesn't check the flag,
    // which is what lets this last write through.
    _disposed = true;
    _positionTimer?.cancel();
    _positionTimer = null;
    final PlaybackState? pending = _pendingPositionState;
    _pendingPositionState = null;
    if (pending != null) await _persist(pending, positionOnly: true);
    await _subscription?.cancel();
    _subscription = null;
  }
}

/// A saved session that restore could hand the engine only part of.
class _HeldSession {
  _HeldSession({
    required this.saved,
    required this.restoredAt,
    required this.startIndex,
  });

  /// The whole saved session, tracks that couldn't play at launch included.
  final PersistedPlaybackSession saved;

  /// Where in [saved] each track the engine was given sits, in queue order.
  /// Empty when none of them could play.
  final List<int> restoredAt;

  /// The index in the restored queue the engine started on.
  final int startIndex;

  /// Whether [state] still holds exactly the restored queue. Moving through it
  /// is progress; any other queue is one the listener chose.
  bool isRestoredQueue(PlaybackState state) {
    final List<Track> live = <Track>[
      ...state.previous,
      if (state.currentTrack != null) state.currentTrack!,
      ...state.upNext,
    ];
    if (live.length != restoredAt.length) return false;
    for (int i = 0; i < live.length; i++) {
      if (live[i].uri != saved.tracks[restoredAt[i]].uri) return false;
    }
    return true;
  }

  /// [saved], moved on to where [state] is in the restored queue.
  PersistedPlaybackSession progressedTo(PlaybackState state) {
    final int at = state.previous.length;
    // Still on the track restore landed on in place of a current one that
    // couldn't play: the session keeps pointing at that one, where it was.
    final bool standingIn = at == startIndex &&
        saved.tracks[restoredAt[at]].uri != saved.current!.uri;
    return PersistedPlaybackSession(
      tracks: saved.tracks,
      currentIndex: standingIn ? saved.currentIndex : restoredAt[at],
      position: standingIn
          ? saved.position
          : (state.position < Duration.zero ? Duration.zero : state.position),
      shuffleEnabled: state.shuffleEnabled,
      repeatMode: state.repeatMode,
      // Still the same songs, the ones left out included: still theirs.
      owners: saved.owners,
    );
  }
}
