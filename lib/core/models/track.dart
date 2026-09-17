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
    this.albumId,
    this.albumArtistName,
    this.duration = Duration.zero,
    this.trackNumber,
    this.discNumber,
    this.artworkUri,
    this.replayGain = ReplayGain.none,
  });

  final String id;
  final String title;
  final String uri;
  final String? artistName;
  final String? albumName;

  /// The source's stable, provider-namespaced album id (e.g. `jellyfin:al-1`,
  /// `plex:201`, `subsonic:al-27`), when the source exposes one. Mirrors
  /// [uri]'s namespacing so two providers' same bare album id can never
  /// collide. `null` for sources with no stable album id (local files) or when
  /// the source didn't report one for this track. Preferred over [albumName] +
  /// [artistName] for album grouping — see `library_grouping.dart`.
  final String? albumId;

  /// The album's artist, as reported by the source (e.g. Jellyfin's
  /// `AlbumArtist`, Plex's grandparent title), distinct from [artistName]
  /// (this track's own credited artist). Lets tracks that are collaborations —
  /// same album, different per-track [artistName] — still group under one
  /// album via `albumName + albumArtistName` when no [albumId] is available.
  /// `null` when the source carries no separate album-artist concept, or when
  /// it isn't a trustworthy fit (e.g. Subsonic's classic API has no reliable
  /// per-song album-artist field).
  final String? albumArtistName;

  final Duration duration;
  final int? trackNumber;

  /// The 1-based disc this track sits on in a multi-disc release, when the
  /// source reported a trustworthy one. Null for a single-disc album, for a
  /// file with no disc tag, and for every source that does not carry the value
  /// this far yet (all of them today, see #85), so outside tests this is
  /// currently always null and album order is unchanged.
  ///
  /// Album ordering reads it first (`library_grouping.dart` sorts by disc, then
  /// track), so the album surfaces and anything queueing from them fall into
  /// disc order the moment a source starts populating it. Without it a
  /// multi-disc album interleaves, because track numbers restart on each disc.
  final int? discNumber;

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
    String? albumId,
    String? albumArtistName,
    Duration? duration,
    int? trackNumber,
    int? discNumber,
    Uri? artworkUri,
    ReplayGain? replayGain,
  }) {
    return Track(
      id: id ?? this.id,
      title: title ?? this.title,
      uri: uri ?? this.uri,
      artistName: artistName ?? this.artistName,
      albumName: albumName ?? this.albumName,
      albumId: albumId ?? this.albumId,
      albumArtistName: albumArtistName ?? this.albumArtistName,
      duration: duration ?? this.duration,
      trackNumber: trackNumber ?? this.trackNumber,
      discNumber: discNumber ?? this.discNumber,
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
