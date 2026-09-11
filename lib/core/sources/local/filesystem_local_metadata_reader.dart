import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';

import '../../models/local_file_stamp.dart';
import '../../services/local_artwork_cache.dart';
import 'local_audio_metadata.dart';
import 'local_metadata_reader.dart';
import 'vorbis_comment_fields.dart';

/// Reads audio tags — and embedded cover art — from a real file on disk: the
/// desktop/Linux half of [LocalMetadataReader], where Android's SAF walk reads
/// both natively.
///
/// Without this, a Linux library shows filenames and folder names: the mapper's
/// fallback is deliberately decent, but "03 - Track.flac" in a folder called
/// "Album" is not the same as a real title, artist, duration and cover. This is
/// what makes a local Linux library look like a library (#407, #408).
///
/// It reads through `audio_metadata_reader` (MIT, pure Dart), which opens the
/// file and parses only the tag structures (headers, frames, comment blocks)
/// rather than reading a whole 60 MB FLAC into memory to find its title. Cover
/// art is fetched (`getImage: true`) only on a cache miss — [_artworkCache] is
/// consulted first, so a file whose cover was already extracted on an earlier
/// scan costs exactly what a tags-only read costs; pulling the embedded
/// picture back out of a parse nobody needs is exactly the cost that skips.
///
/// Deliberately total, like the SAF reader it mirrors: an unreadable file, an
/// unsupported container, a truncated tag or a format the package has no parser
/// for all return `null`, so the track still appears with its filename-derived
/// metadata instead of vanishing from the library.
class FilesystemLocalMetadataReader
    implements LocalMetadataReader, LocalArtworkMaintainer {
  FilesystemLocalMetadataReader({LocalArtworkCache? artworkCache})
      : _artworkCache = artworkCache ?? LocalArtworkCache();

  final LocalArtworkCache _artworkCache;

  @override
  Future<void> retainArtwork(Set<Uri> live) => _artworkCache.retainOnly(live);

  @override
  Future<LocalAudioMetadata?> readFromPath(String path) async {
    try {
      final File file = File(path);
      // `await`, and an asynchronous `stat()` rather than `statSync()`, is
      // load-bearing: it is the only point in this method that reaches the
      // event loop. `readAllMetadata` below is synchronous, so without a real
      // asynchronous call first, this method would do all its work before
      // returning an already-completed Future. A caller awaiting that gets a
      // microtask, and the microtask queue drains completely before the event
      // loop runs again, so a scan of thousands of files would be one
      // unbroken chain with no frame rendered and no input handled from the
      // first file to the last. Measured on a 2000-iteration stand-in: zero
      // event-loop ticks with the synchronous check, one per file with this.
      // Switching this back to a synchronous check re-freezes the desktop UI
      // for the length of the scan, silently (see the test that asserts the
      // yield).
      //
      // `stat` rather than `exists` because it is the same one syscall and
      // answers strictly more: whether this is a regular file (a *directory*
      // named `Album.mp3` used to read as "exists" and then fail deeper in),
      // and the size and mtime that identify which bytes any cached cover was
      // extracted from.
      final FileStat stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) return null;
      final LocalFileStamp stamp = LocalFileStamp(
        sizeBytes: stat.size,
        modifiedAtMs: stat.modified.millisecondsSinceEpoch,
      );

      // A cover cached from an earlier scan needs no re-extraction: checking
      // first means a hit costs nothing beyond this stat, and only a genuine
      // miss asks the parser for the (possibly large) embedded picture. The
      // lookup is keyed by the stamp too, so a file re-tagged with new art
      // misses here and re-extracts rather than serving the cover from before
      // the edit.
      final File? cachedArtwork = await _artworkCache.cachedFile(path, stamp);
      final bool needsArtwork = cachedArtwork == null;

      // Format-specific rather than the package's unified `readMetadata`: that
      // one folds ID3's TPE2 (album artist) into a single `artist` field, which
      // would lose the distinction the catalog groups albums by.
      final Object tag = readAllMetadata(file, getImage: needsArtwork);
      final LocalAudioMetadata? parsedTags = _fromParserTag(tag);
      // FLAC's comment block is readable in the clear, so prefer the real
      // ARTIST/ALBUMARTIST over what the package merged. See
      // [VorbisCommentFields] for why no heuristic can substitute for this.
      final Map<String, List<String>>? vorbisFields =
          parsedTags == null ? null : await VorbisCommentFields.read(file);
      final LocalAudioMetadata textMetadata = parsedTags == null
          ? LocalAudioMetadata.empty
          : _withVorbisArtists(parsedTags, vorbisFields);

      Uri? artworkUri =
          cachedArtwork == null ? null : Uri.file(cachedArtwork.path);
      if (needsArtwork) {
        final Picture? cover = _bestCover(_picturesOf(tag));
        if (cover != null) {
          artworkUri = await _artworkCache.store(path, stamp, cover.bytes);
        }
      }

      final LocalAudioMetadata result = LocalAudioMetadata(
        title: textMetadata.title,
        artist: textMetadata.artist,
        albumArtist: textMetadata.albumArtist,
        album: textMetadata.album,
        albumId: textMetadata.albumId,
        trackNumber: textMetadata.trackNumber,
        duration: textMetadata.duration,
        artworkUri: artworkUri,
      );
      return result.isEmpty ? null : result;
    } catch (_) {
      // Any failure is "no tags", never a failed scan. The path is not logged:
      // a user's file path is private data (see CONTRIBUTING, Privacy).
      return null;
    }
  }

  /// The embedded pictures a parsed container carries, regardless of which
  /// format-specific field they live under. Every format but MP4 collects them
  /// as `pictures`; MP4's `covr` atom is modeled as a single nullable picture.
  static List<Picture> _picturesOf(Object tag) => switch (tag) {
        Mp3Metadata() => tag.pictures,
        ApeMetadata() => tag.pictures,
        VorbisMetadata() => tag.pictures,
        RiffMetadata() => tag.pictures,
        Mp4Metadata() =>
          tag.picture == null ? const <Picture>[] : <Picture>[tag.picture!],
        _ => const <Picture>[],
      };

  /// The picture to treat as *the* cover, when a file carries more than one
  /// (a front cover alongside a back cover or a band photo, say): the one
  /// explicitly tagged as the front cover, or the first attached picture when
  /// none is.
  static Picture? _bestCover(List<Picture> pictures) {
    for (final Picture picture in pictures) {
      if (picture.pictureType == PictureType.coverFront) return picture;
    }
    return pictures.isEmpty ? null : pictures.first;
  }

  /// Replaces the artist fields with the file's real ones when the comment
  /// block could be read with its field names intact.
  ///
  /// [fields] is null for every non-FLAC container (and for an unreadable
  /// block), in which case [metadata] keeps whatever the package's merged list
  /// produced. Both fields join their values: the spec's way to write a joint
  /// credit is to repeat the field, and that is as true of an album credited to
  /// two artists as of a track. Keeping only the first would drop the rest of
  /// the credit and group the album under an incomplete name.
  static LocalAudioMetadata _withVorbisArtists(
    LocalAudioMetadata metadata,
    Map<String, List<String>>? fields,
  ) {
    if (fields == null) return metadata;
    final List<String> artists = _nonBlank(fields['ARTIST']);
    final List<String> albumArtists = _nonBlank(fields['ALBUMARTIST']);
    return LocalAudioMetadata(
      title: metadata.title,
      artist: artists.isEmpty ? null : artists.join(', '),
      albumArtist: albumArtists.isEmpty ? null : albumArtists.join(', '),
      album: metadata.album,
      albumId: metadata.albumId,
      trackNumber: metadata.trackNumber,
      duration: metadata.duration,
      artworkUri: metadata.artworkUri,
    );
  }

  static List<String> _nonBlank(List<String>? values) => <String>[
        for (final String value in values ?? const <String>[])
          if (value.trim().isNotEmpty) value.trim(),
      ];

  /// The track artist from Vorbis's merged ARTIST/ALBUMARTIST list, or null
  /// when the entries disagree. Only OGG and Opus reach this: FLAC's real field
  /// names are read instead (see [VorbisCommentFields]).
  ///
  /// Vorbis comments carry no ordering requirement, and the package folds both
  /// tags into one list in file order, so `first` is whichever the tagger
  /// happened to write first. On a compilation (`ARTIST=Featured Guest`,
  /// `ALBUMARTIST=Various Artists`) that means the same file reports the
  /// performer or the compilation name depending on the tool that wrote it,
  /// verified against fixtures written both ways.
  ///
  /// The distinction only matters when the values actually differ. A normal
  /// album tags both with the same name, so the list is one repeated value and
  /// there is nothing to guess; that is the common case and it is answered
  /// exactly. When they disagree this returns null rather than a coin flip, and
  /// the mapper falls back to the filename and folder: absent beats wrong half
  /// the time. It cannot do better, because two distinct entries are equally
  /// consistent with a collaboration (two ARTIST fields) and a compilation
  /// (ARTIST plus ALBUMARTIST), the case FLAC no longer has to guess at.
  static String? _unambiguousArtist(List<String> merged) {
    final Set<String> distinct = <String>{
      for (final String value in merged)
        if (value.trim().isNotEmpty) value.trim(),
    };
    return distinct.length == 1 ? distinct.first : null;
  }

  /// Maps one parsed container to Linthra's source-agnostic holder.
  ///
  /// Only the fields the catalog can actually store are mapped. The package
  /// also exposes disc number, year and genre, which `Track` has nowhere to put
  /// today. Surfacing those needs a catalog/schema change, so they are left
  /// unread rather than parsed into a field nothing reads.
  ///
  /// Typed as [Object] on purpose: the package's common supertype (`ParserTag`)
  /// lives under `src/` and is not exported, and reaching into another
  /// package's private library to name it would be worse than matching the
  /// public container types directly.
  static LocalAudioMetadata? _fromParserTag(Object tag) {
    return switch (tag) {
      // ID3: TIT2 / TPE1 / TPE2 / TALB. The one format where the track artist
      // and the album artist are unambiguously separate.
      Mp3Metadata() => _metadata(
          title: tag.songName,
          artist: tag.leadPerformer,
          albumArtist: tag.bandOrOrchestra,
          album: tag.album,
          trackNumber: tag.trackNumber,
          duration: tag.duration,
        ),
      // APEv2 names its album artist outright.
      ApeMetadata() => _metadata(
          title: tag.title,
          artist: tag.artist,
          albumArtist: tag.albumArtist,
          album: tag.album,
          trackNumber: tag.trackNumber,
          duration: tag.duration,
        ),
      // Vorbis comments (FLAC, OGG, Opus). The package appends both ARTIST and
      // ALBUMARTIST to one list (`case 'ARTIST' || "ALBUMARTIST"`), discarding
      // which was which. The artist here is therefore provisional: for FLAC,
      // readFromPath replaces it (and fills the album artist) from the real
      // field names via [VorbisCommentFields]. OGG and Opus keep what
      // [_unambiguousArtist] can salvage and report no album artist, which lets
      // the mapper group on album + artist the same way the Subsonic source
      // handles a server with no trustworthy per-song album artist.
      VorbisMetadata() => _metadata(
          title: tag.title.firstOrNull,
          artist: _unambiguousArtist(tag.artist),
          album: tag.album.firstOrNull,
          trackNumber: tag.trackNumber.firstOrNull,
          duration: tag.duration,
        ),
      // iTunes-style atoms. The package does not read `aART`, so no album
      // artist.
      Mp4Metadata() => _metadata(
          title: tag.title,
          artist: tag.artist,
          album: tag.album,
          trackNumber: tag.trackNumber,
          duration: tag.duration,
        ),
      // RIFF INFO chunks (WAV), which have no album-artist concept at all.
      RiffMetadata() => _metadata(
          title: tag.title,
          artist: tag.artist,
          album: tag.album,
          trackNumber: tag.trackNumber,
          duration: tag.duration,
        ),
      _ => null,
    };
  }

  /// Builds the holder, or null when the file carried nothing usable.
  ///
  /// Blank and whitespace-only tags (common in files written by sloppy
  /// taggers) are normalized to absent here so the mapper's filename fallback wins
  /// instead of a track showing an empty title. A non-positive track number is
  /// meaningless as an index and folds to null the same way.
  static LocalAudioMetadata? _metadata({
    String? title,
    String? artist,
    String? albumArtist,
    String? album,
    int? trackNumber,
    Duration? duration,
  }) {
    final LocalAudioMetadata metadata = LocalAudioMetadata(
      title: _blankToNull(title),
      artist: _blankToNull(artist),
      albumArtist: _blankToNull(albumArtist),
      album: _blankToNull(album),
      trackNumber:
          (trackNumber != null && trackNumber > 0) ? trackNumber : null,
      duration:
          (duration != null && duration > Duration.zero) ? duration : null,
    );
    return metadata.isEmpty ? null : metadata;
  }

  static String? _blankToNull(String? value) {
    if (value == null) return null;
    final String trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
