import 'replay_gain.dart';

/// A single playable track, independent of where it came from.
///
/// [uri] may point to a local file path or a remote resource. Keeping it
/// source-agnostic lets the same model flow through local, Jellyfin, and
/// WebDAV sources without change.
class Track {
  const Track({
    required this.id,
    required this.title,
    required this.uri,
    this.artistName,
    this.albumName,
    this.duration = Duration.zero,
    this.trackNumber,
    this.artworkUri,
    this.replayGain = ReplayGain.none,
  });

  final String id;
  final String title;
  final String uri;
  final String? artistName;
  final String? albumName;
  final Duration duration;
  final int? trackNumber;
  final Uri? artworkUri;

  /// Loudness metadata used for volume normalization. Defaults to
  /// [ReplayGain.none]; sources that read it populate this when available.
  final ReplayGain replayGain;

  /// "Artist • Album" with whichever parts are present, joined by " • ".
  /// Empty when the track carries neither, so callers pick their own fallback
  /// (the raw [uri], a hidden subtitle, …).
  String get artistAlbumLabel {
    final parts = <String>[
      if (artistName != null && artistName!.isNotEmpty) artistName!,
      if (albumName != null && albumName!.isNotEmpty) albumName!,
    ];
    return parts.join(' • ');
  }

  Track copyWith({
    String? id,
    String? title,
    String? uri,
    String? artistName,
    String? albumName,
    Duration? duration,
    int? trackNumber,
    Uri? artworkUri,
    ReplayGain? replayGain,
  }) {
    return Track(
      id: id ?? this.id,
      title: title ?? this.title,
      uri: uri ?? this.uri,
      artistName: artistName ?? this.artistName,
      albumName: albumName ?? this.albumName,
      duration: duration ?? this.duration,
      trackNumber: trackNumber ?? this.trackNumber,
      artworkUri: artworkUri ?? this.artworkUri,
      replayGain: replayGain ?? this.replayGain,
    );
  }

  /// Identity is the provider-namespaced [uri], not the bare [id]: two copies of
  /// the same server-side id from different providers (e.g. `jellyfin:101` and
  /// `subsonic:101`) are genuinely different tracks and must not compare equal,
  /// or they'd collide in Sets/Maps, `List` equality, `Stream.distinct`, and
  /// Riverpod family keys. Same-provider re-fetches share a uri, so a `copyWith`
  /// that only refreshes metadata still compares equal (as before). Code that
  /// wants to group same-id copies across providers keys on [id] explicitly (the
  /// catalog unifier), so this never affects that.
  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is Track && other.uri == uri);

  @override
  int get hashCode => uri.hashCode;
}
