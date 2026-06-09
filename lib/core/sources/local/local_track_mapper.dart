import 'package:path/path.dart' as p;

import '../../models/track.dart';
import 'local_audio_metadata.dart';
import 'saf_document_lister.dart';

/// Builds a [Track] from an on-device source — a local file path or an Android
/// SAF document — merging any audio tags the source read over a clean
/// filename/folder fallback.
///
/// This is intentionally the *only* place that turns an on-device item into a
/// [Track], so the metadata story lives in one tested spot.
///
/// ## Tags first, then a clean fallback
///
/// When [LocalAudioMetadata] is present (the native SAF walk read tags, or a
/// future desktop reader did), its fields win — so a tagged file indexes with a
/// proper title, artist, album, duration, and track number, exactly like a
/// Jellyfin/Subsonic track. Each field falls back **independently** when its tag
/// is missing or blank, so a half-tagged file still gets the best of both.
///
/// The fallback never shows an ugly path. From the file's own name it derives a
/// leading track number and a clean title (`01 - Holocene` → #1, "Holocene");
/// from a filesystem layout it reads the conventional `…/Artist/Album/Track`
/// folders for the artist and album. (A SAF content URI exposes no folder path,
/// so SAF album/artist come only from tags — usually present on Android.)
///
/// The path / content URI is always both the stable [Track.id] and the
/// [Track.uri], independent of the (mutable) tags, so a re-scan after an edit
/// keeps the same identity.
abstract final class LocalTrackMapper {
  /// Maps [path] to a [Track].
  ///
  /// [metadata] are the file's tags when a reader provided them; [scanRoot] is
  /// the scanned folder, used to read the `Artist/Album` folders *relative to
  /// it* (so the scan root itself is never mistaken for an album). Both are
  /// optional: with neither, the title and any leading track number still come
  /// from the file name.
  static Track fromPath(
    String path, {
    LocalAudioMetadata? metadata,
    String? scanRoot,
  }) {
    final String base = p.basenameWithoutExtension(path);
    final _FolderNames folders = _folderNamesFor(path, scanRoot);
    return _build(
      id: path,
      uri: path,
      nameWithoutExtension: base,
      metadata: metadata,
      folderArtist: folders.artist,
      folderAlbum: folders.album,
    );
  }

  /// Maps a SAF [document] to a [Track]. The `content://` URI is both the stable
  /// id and the playable uri; tags come from [SafAudioDocument.metadata] and the
  /// title/track-number fallback from the display name.
  static Track fromSafDocument(SafAudioDocument document) {
    return _build(
      id: document.uri,
      uri: document.uri,
      nameWithoutExtension: p.basenameWithoutExtension(document.name),
      metadata: document.metadata,
    );
  }

  /// Merges [metadata] over the name/folder fallback into a [Track]. Every field
  /// falls back independently, and a blank tag value is treated as absent.
  static Track _build({
    required String id,
    required String uri,
    required String nameWithoutExtension,
    LocalAudioMetadata? metadata,
    String? folderArtist,
    String? folderAlbum,
  }) {
    final _NameParts parts = _parseName(nameWithoutExtension);
    return Track(
      id: id,
      uri: uri,
      title: _firstNonBlank(<String?>[metadata?.title, parts.title]) ??
          parts.title,
      artistName: _firstNonBlank(<String?>[
        metadata?.albumArtist,
        metadata?.artist,
        folderArtist,
      ]),
      albumName: _firstNonBlank(<String?>[metadata?.album, folderAlbum]),
      trackNumber: metadata?.trackNumber ?? parts.trackNumber,
      duration: metadata?.duration ?? Duration.zero,
    );
  }

  /// A leading track number (`01 - `, `01.`, `01 `, …) and the remaining title,
  /// parsed from a file/display name without its extension.
  ///
  /// A number is only taken when a separator follows it and a non-empty title
  /// remains, so a name that *is* a number ("1984") or has no separator keeps
  /// its whole self as the title and reports no track number. A real tag title,
  /// when present, is used verbatim instead — this only shapes the fallback.
  static _NameParts _parseName(String nameWithoutExtension) {
    final String trimmed = nameWithoutExtension.trim();
    final RegExpMatch? match = _leadingTrackNumber.firstMatch(trimmed);
    if (match != null) {
      final String rest = match.group(2)!.trim();
      if (rest.isNotEmpty) {
        return _NameParts(int.tryParse(match.group(1)!), rest);
      }
    }
    // No usable leading number: the whole (trimmed) name is the title. Guard the
    // pathological empty name so a track is never titled "".
    return _NameParts(null, trimmed.isEmpty ? nameWithoutExtension : trimmed);
  }

  /// `1`–`3` leading digits, then at least one separator, then a non-empty rest.
  /// The separators cover the common `01 - `, `01.`, `01_`, `01)` and bare-space
  /// conventions without stripping a number that is part of the title.
  static final RegExp _leadingTrackNumber =
      RegExp(r'^(\d{1,3})[\s._\-)\]]+(.+)$');

  /// The conventional `Artist/Album` folder names for [path], read *relative to*
  /// [scanRoot] so the scanned root is never treated as an album/artist. Returns
  /// empty names when there is no folder context (no root, or the file is not
  /// under it — e.g. a content-URI scan resolved to a path elsewhere).
  static _FolderNames _folderNamesFor(String path, String? scanRoot) {
    if (scanRoot == null || scanRoot.isEmpty) return const _FolderNames();
    final String root = p.normalize(scanRoot);
    final String full = p.normalize(path);
    if (!p.isWithin(root, full)) return const _FolderNames();
    final List<String> segments = p.split(p.relative(full, from: root));
    // Drop the file name itself; what's left are the folders below the root.
    final List<String> folders = segments.sublist(0, segments.length - 1);
    final String? album =
        folders.isNotEmpty ? _blankToNull(folders.last) : null;
    final String? artist =
        folders.length >= 2 ? _blankToNull(folders[folders.length - 2]) : null;
    return _FolderNames(artist: artist, album: album);
  }

  /// The first non-null, non-blank (after trimming) value, or null when none.
  static String? _firstNonBlank(List<String?> values) {
    for (final String? value in values) {
      final String? cleaned = _blankToNull(value);
      if (cleaned != null) return cleaned;
    }
    return null;
  }

  /// [value] trimmed, or null when it is null or blank.
  static String? _blankToNull(String? value) {
    if (value == null) return null;
    final String trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

/// A leading track number and the remaining title parsed from a name.
class _NameParts {
  const _NameParts(this.trackNumber, this.title);

  final int? trackNumber;
  final String title;
}

/// The conventional `Artist/Album` folder names derived from a file's path.
class _FolderNames {
  const _FolderNames({this.artist, this.album});

  final String? artist;
  final String? album;
}
