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

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is Track && other.id == id);

  @override
  int get hashCode => id.hashCode;
}
