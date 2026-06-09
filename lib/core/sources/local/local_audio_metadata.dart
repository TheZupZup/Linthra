/// Audio tags read from an on-device item (an Android SAF document via the
/// native content resolver, or — in a future follow-up — a desktop file).
///
/// Every field is optional: a `null` value means "this source had no
/// trustworthy value for this field", so [LocalTrackMapper] falls back to a
/// filename/folder-derived value rather than showing a blank or an ugly path.
/// Blank-string normalization (treating `''`/whitespace as absent) is the
/// mapper's job, so this stays a dumb, source-agnostic holder that is trivial to
/// construct in tests and from the native reply alike.
class LocalAudioMetadata {
  const LocalAudioMetadata({
    this.title,
    this.artist,
    this.albumArtist,
    this.album,
    this.trackNumber,
    this.duration,
  });

  /// The track title (e.g. ID3 `TIT2`).
  final String? title;

  /// The performing/track artist (e.g. ID3 `TPE1`).
  final String? artist;

  /// The album artist (e.g. ID3 `TPE2`), preferred over [artist] for grouping
  /// so a single-artist album never splits and the mapping matches the
  /// Jellyfin/Subsonic sources (which also key a track's displayed artist off
  /// the album artist when present). See [primaryArtist].
  final String? albumArtist;

  /// The album title (e.g. ID3 `TALB`).
  final String? album;

  /// The 1-based track number within its album, when known.
  final int? trackNumber;

  /// The track's real duration, when the source reported one. Distinct from the
  /// filename — a filename can never reveal a duration, so this only comes from
  /// actual tag/stream metadata.
  final Duration? duration;

  /// Whether every field is absent — i.e. the source carried no usable tag at
  /// all, so the mapper relies entirely on filename/folder fallback.
  bool get isEmpty =>
      title == null &&
      artist == null &&
      albumArtist == null &&
      album == null &&
      trackNumber == null &&
      duration == null;

  /// A metadata holder with no fields set.
  static const LocalAudioMetadata empty = LocalAudioMetadata();
}
