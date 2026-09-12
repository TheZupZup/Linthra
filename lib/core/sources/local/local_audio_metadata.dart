/// Audio tags read from an on-device item: an Android SAF document via the
/// native content resolver, or a desktop file via
/// `FilesystemLocalMetadataReader`.
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
    this.albumId,
    this.trackNumber,
    this.discNumber,
    this.duration,
    this.artworkUri,
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

  /// A stable, already source-namespaced album identifier when the native
  /// source exposes one. Android MediaStore provides this even when individual
  /// tracks in a compilation have different artist values.
  final String? albumId;

  /// The 1-based track number within its album, when known.
  final int? trackNumber;

  /// The 1-based disc number within a multi-disc album (e.g. ID3 `TPOS`,
  /// Vorbis `DISCNUMBER`), when the file carries a usable one.
  ///
  /// Null for a single-disc release, a file with no disc tag, and a tag that
  /// can't be trusted (blank, non-numeric, zero or negative) — the same "no
  /// trustworthy value" meaning every other field here has. There is no
  /// filename fallback: a disc number is never guessed from a name or folder,
  /// only read from real tags.
  ///
  /// Reported by the Android SAF walk today; the desktop reader leaves it null
  /// until it reads the tag too, and nothing groups albums by it yet (#85).
  final int? discNumber;

  /// The track's real duration, when the source reported one. Distinct from the
  /// filename — a filename can never reveal a duration, so this only comes from
  /// actual tag/stream metadata.
  final Duration? duration;

  /// A URI to the file's embedded cover art when one was extracted, or null when
  /// the file carries none. Unlike the text fields this is not derived from the
  /// file name — it can only come from real embedded artwork — so it is passed
  /// straight through to [Track.artworkUri]. On Android the native SAF walk
  /// caches the embedded picture into Linthra's private cache and reports a
  /// `file://` URI to it (never a user file path).
  final Uri? artworkUri;

  /// Whether every field is absent — i.e. the source carried no usable tag (or
  /// embedded art) at all, so the mapper relies entirely on filename/folder
  /// fallback.
  bool get isEmpty =>
      title == null &&
      artist == null &&
      albumArtist == null &&
      album == null &&
      albumId == null &&
      trackNumber == null &&
      discNumber == null &&
      duration == null &&
      artworkUri == null;

  /// A metadata holder with no fields set.
  static const LocalAudioMetadata empty = LocalAudioMetadata();
}
