import 'package:flutter/foundation.dart';

import '../sources/music_provider.dart';
import 'repeat_mode.dart';
import 'track.dart';

/// Crash-safe snapshot of non-secret playback state that can survive a process
/// restart.
///
/// Carries only **logical** track identity (provider-namespaced uris like
/// `jellyfin:101`, local paths), queue order/modes, and a seek position — never
/// an authenticated stream URL, provider token, or raw resolver output. Remote
/// playback always re-resolves through the normal provider/session path after
/// restore.
@immutable
class PersistedPlaybackSession {
  const PersistedPlaybackSession({
    required this.tracks,
    required this.currentIndex,
    this.position = Duration.zero,
    this.shuffleEnabled = false,
    this.repeatMode = RepeatMode.off,
    this.originalOrder,
    this.owners,
    this.schemaVersion = currentSchemaVersion,
  });

  /// Bump when the on-disk shape changes in a way older readers cannot ignore.
  /// Unknown/future versions are dropped wholesale on load (fail safe).
  static const int currentSchemaVersion = 1;

  /// Effective play order at the time of the snapshot (already shuffled when
  /// [shuffleEnabled] is true).
  final List<Track> tracks;

  /// Index of the current track within [tracks].
  final int currentIndex;

  /// Seek position within the current track. Clamped on restore when duration
  /// is known.
  final Duration position;

  final bool shuffleEnabled;
  final RepeatMode repeatMode;

  /// Pre-shuffle order when [shuffleEnabled], otherwise null. Same logical
  /// track identity rules as [tracks].
  final List<Track>? originalOrder;

  /// Whose songs each remote provider's tracks are, by provider source id
  /// (`subsonic`, …): the same non-secret account fingerprint the sync stores
  /// keep, or the Plex server's `machineIdentifier`. A remote track id only
  /// means something there, so a restore under anyone else leaves them out
  /// (#767). A provider missing from it is one nobody could say for.
  ///
  /// Null for a record saved before Linthra wrote this, whose tracks restore
  /// as they always did.
  final Map<String, String>? owners;

  final int schemaVersion;

  bool get isEmpty => tracks.isEmpty;

  Track? get current {
    if (currentIndex < 0 || currentIndex >= tracks.length) return null;
    return tracks[currentIndex];
  }

  /// This session with [owners] in place of its own.
  PersistedPlaybackSession withOwners(Map<String, String>? owners) {
    return PersistedPlaybackSession(
      tracks: tracks,
      currentIndex: currentIndex,
      position: position,
      shuffleEnabled: shuffleEnabled,
      repeatMode: repeatMode,
      originalOrder: originalOrder,
      owners: owners == null ? null : _safeOwners(owners),
      schemaVersion: schemaVersion,
    );
  }

  /// Builds a session from live playback, or `null` when there is nothing
  /// useful / safe to persist (no current track, or any identity that is not
  /// logical).
  static PersistedPlaybackSession? fromPlayback({
    required List<Track> previous,
    required Track current,
    required List<Track> upNext,
    required Duration position,
    required bool shuffleEnabled,
    required RepeatMode repeatMode,
    List<Track>? originalOrder,
  }) {
    final List<Track> tracks = <Track>[...previous, current, ...upNext];
    if (!_allLogical(tracks)) return null;
    if (originalOrder != null && !_allLogical(originalOrder)) return null;
    return PersistedPlaybackSession(
      tracks: tracks,
      currentIndex: previous.length,
      position: position < Duration.zero ? Duration.zero : position,
      shuffleEnabled: shuffleEnabled,
      repeatMode: repeatMode,
      originalOrder:
          originalOrder == null ? null : List<Track>.of(originalOrder),
    );
  }

  /// Serializes to a JSON-compatible map. Never includes stream URLs or tokens.
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'v': schemaVersion,
      'i': currentIndex,
      'p': position.inMilliseconds,
      's': shuffleEnabled,
      'r': repeatMode.name,
      't': <Map<String, dynamic>>[
        for (final Track track in tracks) logicalTrackToJson(track),
      ],
      if (originalOrder != null)
        'o': <Map<String, dynamic>>[
          for (final Track track in originalOrder!) logicalTrackToJson(track),
        ],
      if (owners != null) 'a': Map<String, String>.of(owners!),
    };
  }

  /// Rebuilds a session from [toJson] output, or `null` if the record is
  /// unusable (wrong version, corrupt shape, no restorable tracks).
  ///
  /// Invalid individual tracks are dropped; [currentIndex] is remapped onto the
  /// surviving list. A wholly empty result yields `null`. When that is only
  /// because [isTrackRestorable] turned every track down, the record itself is
  /// still sound and is not a reason to clear the store.
  static PersistedPlaybackSession? fromJson(
    Map<String, dynamic> json, {
    bool Function(Track track)? isTrackRestorable,
  }) {
    final Object? version = json['v'];
    if (version is! int || version != currentSchemaVersion) return null;

    final Object? rawTracks = json['t'];
    if (rawTracks is! List) return null;

    final Object? rawIndex = json['i'];
    final int requestedIndex = rawIndex is int ? rawIndex : 0;
    String? preferredCurrentUri;
    if (requestedIndex >= 0 && requestedIndex < rawTracks.length) {
      final Object? preferred = rawTracks[requestedIndex];
      if (preferred is Map) {
        final Object? uri = preferred['uri'];
        if (uri is String && uri.isNotEmpty) preferredCurrentUri = uri;
      }
    }

    final List<Track> parsed = <Track>[];
    // Where the saved current entry itself landed, when it survived. A queue
    // can hold the same song twice, so its uri alone could name an earlier
    // copy.
    int? savedEntryAt;
    for (int i = 0; i < rawTracks.length; i++) {
      final Object? entry = rawTracks[i];
      if (entry is! Map) continue;
      final Track? track =
          logicalTrackFromJson(Map<String, dynamic>.from(entry));
      if (track == null) continue;
      if (isTrackRestorable != null && !isTrackRestorable(track)) continue;
      if (i == requestedIndex) savedEntryAt = parsed.length;
      parsed.add(track);
    }
    if (parsed.isEmpty) return null;

    // Prefer the originally current entry when it survived filtering, then
    // another copy of it; otherwise land on the first surviving track so
    // restore never points past the end or at a dropped remote/local row.
    int currentIndex = 0;
    if (savedEntryAt != null) {
      currentIndex = savedEntryAt;
    } else if (preferredCurrentUri != null) {
      final int found =
          parsed.indexWhere((Track t) => t.uri == preferredCurrentUri);
      if (found >= 0) currentIndex = found;
    }

    final Object? rawPosition = json['p'];
    final int positionMs =
        rawPosition is int && rawPosition >= 0 ? rawPosition : 0;

    final bool shuffleEnabled = json['s'] == true;
    final RepeatMode repeatMode = _repeatModeFromName(json['r']);

    List<Track>? originalOrder;
    final Object? rawOriginal = json['o'];
    if (shuffleEnabled && rawOriginal is List) {
      final List<Track> order = <Track>[];
      for (final Object? entry in rawOriginal) {
        if (entry is! Map) continue;
        final Track? track =
            logicalTrackFromJson(Map<String, dynamic>.from(entry));
        if (track == null) continue;
        if (isTrackRestorable != null && !isTrackRestorable(track)) continue;
        order.add(track);
      }
      if (order.isNotEmpty) originalOrder = order;
    }

    final Track current = parsed[currentIndex];
    final Duration position = _clampPosition(
      Duration(milliseconds: positionMs),
      current.duration,
    );

    return PersistedPlaybackSession(
      tracks: parsed,
      currentIndex: currentIndex,
      position: position,
      shuffleEnabled: shuffleEnabled,
      repeatMode: repeatMode,
      originalOrder: shuffleEnabled ? originalOrder : null,
      owners: _ownersFromJson(json['a']),
    );
  }

  /// [raw] as [owners]. Absent is a record from before them (null); anything
  /// unreadable says nobody's, so its remote tracks wait rather than restore
  /// under whoever is signed in.
  static Map<String, String>? _ownersFromJson(Object? raw) {
    if (raw == null) return null;
    if (raw is! Map) return const <String, String>{};
    return _safeOwners(<String, String>{
      for (final MapEntry<Object?, Object?> entry in raw.entries)
        if (entry.key is String && entry.value is String)
          entry.key! as String: entry.value! as String,
    });
  }

  /// [owners] without an entry that is blank or could carry a secret. Leaving
  /// one out only makes its provider's tracks wait.
  static Map<String, String> _safeOwners(Map<String, String> owners) {
    return <String, String>{
      for (final MapEntry<String, String> entry in owners.entries)
        if (entry.key.isNotEmpty &&
            entry.value.isNotEmpty &&
            !_looksTokenBearing(entry.value.toLowerCase()))
          entry.key: entry.value,
    };
  }

  static bool _allLogical(List<Track> tracks) {
    for (final Track track in tracks) {
      if (!isLogicalTrackUri(track.uri)) return false;
    }
    return true;
  }

  static RepeatMode _repeatModeFromName(Object? name) {
    if (name is! String) return RepeatMode.off;
    for (final RepeatMode mode in RepeatMode.values) {
      if (mode.name == name) return mode;
    }
    return RepeatMode.off;
  }

  static Duration _clampPosition(Duration position, Duration duration) {
    if (position < Duration.zero) return Duration.zero;
    if (duration > Duration.zero && position > duration) return duration;
    return position;
  }
}

/// Whether [uri] is a persistable logical track identity.
///
/// Accepts provider-namespaced remote ids (`jellyfin:…`, `subsonic:…`,
/// `plex:…`) and non-HTTP local paths. Rejects authenticated stream URLs,
/// token-bearing query strings, and blank values so a bad write can never put a
/// secret on disk.
bool isLogicalTrackUri(String uri) {
  final String trimmed = uri.trim();
  if (trimmed.isEmpty) return false;
  final String lower = trimmed.toLowerCase();
  if (lower.startsWith('http://') || lower.startsWith('https://')) {
    return false;
  }
  if (_looksTokenBearing(lower, filePath: lower.startsWith('/'))) return false;

  final String? bareId = MusicProviders.bareRemoteIdForTrackUri(trimmed);
  if (bareId != null) {
    // Remote: must be exactly `scheme:<non-empty id>` with no path/query noise.
    return bareId.isNotEmpty && !bareId.contains('/') && !bareId.contains('?');
  }

  // Local: anything non-HTTP that isn't a remote scheme is treated as a path /
  // content uri identity. Still reject token-looking query fragments.
  return true;
}

/// JSON shape for one logical [Track]. Deliberately omits ReplayGain (optional
/// loudness metadata) — restore never needs it to re-resolve playback.
Map<String, dynamic> logicalTrackToJson(Track track) {
  return <String, dynamic>{
    'id': track.id,
    'title': track.title,
    'uri': track.uri,
    if (track.artistName != null) 'artist': track.artistName,
    if (track.albumName != null) 'album': track.albumName,
    if (track.albumId != null) 'albumId': track.albumId,
    if (track.albumArtistName != null) 'albumArtist': track.albumArtistName,
    'durationMs': track.duration.inMilliseconds,
    if (track.trackNumber != null) 'trackNumber': track.trackNumber,
    if (track.artworkUri != null && isPersistableArtworkUri(track.artworkUri!))
      'artwork': track.artworkUri.toString(),
  };
}

/// Rebuilds a [Track] from [logicalTrackToJson] output, or `null` when the
/// identity is missing/unsafe.
Track? logicalTrackFromJson(Map<String, dynamic> json) {
  final Object? id = json['id'];
  final Object? title = json['title'];
  final Object? uri = json['uri'];
  if (id is! String || id.isEmpty) return null;
  if (title is! String || title.isEmpty) return null;
  if (uri is! String || !isLogicalTrackUri(uri)) return null;

  final Object? durationMs = json['durationMs'];
  final Duration duration = durationMs is int && durationMs >= 0
      ? Duration(milliseconds: durationMs)
      : Duration.zero;

  final Object? trackNumber = json['trackNumber'];
  final Object? artwork = json['artwork'];
  Uri? artworkUri;
  if (artwork is String && artwork.isNotEmpty) {
    final Uri? parsed = Uri.tryParse(artwork);
    if (parsed != null && isPersistableArtworkUri(parsed)) {
      artworkUri = parsed;
    }
  }

  return Track(
    id: id,
    title: title,
    uri: uri,
    artistName: json['artist'] as String?,
    albumName: json['album'] as String?,
    albumId: json['albumId'] as String?,
    albumArtistName: json['albumArtist'] as String?,
    duration: duration,
    trackNumber: trackNumber is int ? trackNumber : null,
    artworkUri: artworkUri,
  );
}

/// Artwork is safe to persist when it is a credential-free reference (Jellyfin
/// primary-image URL without a token, `subsonic-cover:…`, `plex-thumb:…`, or a
/// local path). Token-bearing query strings are rejected.
bool isPersistableArtworkUri(Uri uri) {
  final String raw = uri.toString().toLowerCase();
  if (_looksTokenBearing(raw)) return false;
  return true;
}

bool _looksTokenBearing(String value, {bool filePath = false}) {
  // Common provider token query keys and auth header-ish fragments that must
  // never reach the playback-session document.
  const List<String> markers = <String>[
    'api_key=',
    'apikey=',
    'access_token=',
    'accesstoken=',
    'x-plex-token=',
    'x_plex_token=',
    'authorization=',
    'jwt=',
  ];
  for (final String marker in markers) {
    if (value.contains(marker)) return true;
  }
  // How a token is written in a header, which a file path never is. In a
  // path it is part of ordinary names: Pallbearer, Torchbearer, "The Bearer
  // of Bad News". Turning those down would leave the whole queue unsaved.
  return !filePath && value.contains('bearer ');
}
