import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../models/track.dart';
import '../../native/native_local_track.dart';
import 'cue_sheet.dart';
import 'cue_track_uri.dart';
import 'local_audio_metadata.dart';
import 'saf_document_lister.dart';

/// Builds a [Track] from an on-device source — a local file path or an Android
/// SAF document — merging any audio tags the source read over a clean
/// filename/folder fallback.
///
/// The rules run in the Rust core (native/linthra_core/src/scan/mapper.rs)
/// when the build carries it, and in the `…InDart` methods otherwise.
abstract final class LocalTrackMapper {
  static Track fromPath(
    String path, {
    LocalAudioMetadata? metadata,
    String? scanRoot,
  }) {
    final NativeMappedTrack? native = NativeLocalTrack.map(
      source: NativeTrackSource.path,
      path: path,
      scanRoot: scanRoot,
      tags: _tags(metadata),
    );
    if (native == null) {
      return fromPathInDart(path, metadata: metadata, scanRoot: scanRoot);
    }
    return _fromNative(native, id: path, metadata: metadata);
  }

  /// [fromPath] without the Rust core: the reference rules.
  @visibleForTesting
  static Track fromPathInDart(
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

  static Track fromSafDocument(SafAudioDocument document) {
    final NativeMappedTrack? native = NativeLocalTrack.map(
      source: NativeTrackSource.document,
      path: document.name,
      tags: _tags(document.metadata),
    );
    if (native == null) return fromSafDocumentInDart(document);
    return _fromNative(native, id: document.uri, metadata: document.metadata);
  }

  /// [fromSafDocument] without the Rust core: the reference rules.
  @visibleForTesting
  static Track fromSafDocumentInDart(SafAudioDocument document) {
    return _build(
      id: document.uri,
      uri: document.uri,
      nameWithoutExtension: p.basenameWithoutExtension(document.name),
      metadata: document.metadata,
    );
  }

  static Track fromCueTrack(
    CueSheetTrack cueTrack, {
    required String cuePath,
    required LocalAudioMetadata? metadata,
    required String scanRoot,
    int? cueSheetSizeBytes,
    int? cueSheetModifiedAtMs,
  }) {
    final NativeMappedTrack? native = NativeLocalTrack.map(
      source: NativeTrackSource.cue,
      path: cueTrack.audioPath,
      scanRoot: scanRoot,
      tags: _tags(metadata),
      cue: (
        number: cueTrack.number,
        startUs: cueTrack.start.inMicroseconds,
        endUs: cueTrack.end?.inMicroseconds,
        title: cueTrack.title,
        performer: cueTrack.performer,
        album: cueTrack.album,
        albumPerformer: cueTrack.albumPerformer,
      ),
    );
    if (native == null) {
      return fromCueTrackInDart(
        cueTrack,
        cuePath: cuePath,
        metadata: metadata,
        scanRoot: scanRoot,
        cueSheetSizeBytes: cueSheetSizeBytes,
        cueSheetModifiedAtMs: cueSheetModifiedAtMs,
      );
    }
    final int? cueEndUs = native.cueEndUs;
    return _fromNative(
      native,
      id: CueTrackUri.forTrack(
        audioPath: cueTrack.audioPath,
        cuePath: cuePath,
        trackNumber: cueTrack.number,
      ),
      metadata: metadata,
    ).copyWith(
      cueStart: cueTrack.start,
      cueEnd: cueEndUs == null ? null : Duration(microseconds: cueEndUs),
      cueSheetSizeBytes: cueSheetSizeBytes,
      cueSheetModifiedAtMs: cueSheetModifiedAtMs,
    );
  }

  /// [fromCueTrack] without the Rust core: the reference rules.
  @visibleForTesting
  static Track fromCueTrackInDart(
    CueSheetTrack cueTrack, {
    required String cuePath,
    required LocalAudioMetadata? metadata,
    required String scanRoot,
    int? cueSheetSizeBytes,
    int? cueSheetModifiedAtMs,
  }) {
    final String uri = CueTrackUri.forTrack(
      audioPath: cueTrack.audioPath,
      cuePath: cuePath,
      trackNumber: cueTrack.number,
    );
    final Duration? possibleEnd = cueTrack.end ?? metadata?.duration;
    final Duration? end = possibleEnd != null && possibleEnd > cueTrack.start
        ? possibleEnd
        : null;
    final Duration duration = end == null || end <= cueTrack.start
        ? Duration.zero
        : end - cueTrack.start;
    return Track(
      id: uri,
      uri: uri,
      title: _firstNonBlank(<String?>[
            cueTrack.title,
            'Track ${cueTrack.number.toString().padLeft(2, '0')}',
          ]) ??
          'Track ${cueTrack.number}',
      artistName: _firstNonBlank(<String?>[
        cueTrack.performer,
        cueTrack.albumPerformer,
        metadata?.albumArtist,
        metadata?.artist,
        _folderNamesFor(cueTrack.audioPath, scanRoot).artist,
      ]),
      albumName: _firstNonBlank(<String?>[
        cueTrack.album,
        metadata?.album,
        _folderNamesFor(cueTrack.audioPath, scanRoot).album,
      ]),
      albumId: _blankToNull(metadata?.albumId),
      albumArtistName: _firstNonBlank(<String?>[
        cueTrack.albumPerformer,
        metadata?.albumArtist,
      ]),
      trackNumber: cueTrack.number,
      duration: duration,
      cueStart: cueTrack.start,
      cueEnd: end,
      cueSheetSizeBytes: cueSheetSizeBytes,
      cueSheetModifiedAtMs: cueSheetModifiedAtMs,
      artworkUri: metadata?.artworkUri,
    );
  }

  static NativeTrackTags? _tags(LocalAudioMetadata? metadata) =>
      metadata == null
          ? null
          : (
              title: metadata.title,
              artist: metadata.artist,
              album: metadata.album,
              albumArtist: metadata.albumArtist,
              albumId: metadata.albumId,
              trackNumber: metadata.trackNumber,
              durationUs: metadata.duration?.inMicroseconds,
            );

  static Track _fromNative(
    NativeMappedTrack native, {
    required String id,
    LocalAudioMetadata? metadata,
  }) =>
      Track(
        id: id,
        uri: id,
        title: native.title,
        artistName: native.artist,
        albumName: native.album,
        albumId: native.albumId,
        albumArtistName: native.albumArtist,
        trackNumber: native.trackNumber,
        duration: Duration(microseconds: native.durationUs),
        artworkUri: metadata?.artworkUri,
      );

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
      albumId: _blankToNull(metadata?.albumId),
      albumArtistName: _blankToNull(metadata?.albumArtist),
      trackNumber: metadata?.trackNumber ?? parts.trackNumber,
      duration: metadata?.duration ?? Duration.zero,
      artworkUri: metadata?.artworkUri,
    );
  }

  static _NameParts _parseName(String nameWithoutExtension) {
    final String trimmed = nameWithoutExtension.trim();
    final RegExpMatch? match = _leadingTrackNumber.firstMatch(trimmed);
    if (match != null) {
      final String rest = match.group(2)!.trim();
      if (rest.isNotEmpty) {
        return _NameParts(int.tryParse(match.group(1)!), rest);
      }
    }
    return _NameParts(null, trimmed.isEmpty ? nameWithoutExtension : trimmed);
  }

  static final RegExp _leadingTrackNumber =
      RegExp(r'^(\d{1,3})[\s._\-)\]]+(.+)$');

  static _FolderNames _folderNamesFor(String path, String? scanRoot) {
    if (scanRoot == null || scanRoot.isEmpty) return const _FolderNames();
    final String root = p.normalize(scanRoot);
    final String full = p.normalize(path);
    if (!p.isWithin(root, full)) return const _FolderNames();
    final List<String> segments = p.split(p.relative(full, from: root));
    final List<String> folders = segments.sublist(0, segments.length - 1);
    final String? album =
        folders.isNotEmpty ? _blankToNull(folders.last) : null;
    final String? artist =
        folders.length >= 2 ? _blankToNull(folders[folders.length - 2]) : null;
    return _FolderNames(artist: artist, album: album);
  }

  static String? _firstNonBlank(List<String?> values) {
    for (final String? value in values) {
      final String? cleaned = _blankToNull(value);
      if (cleaned != null) return cleaned;
    }
    return null;
  }

  static String? _blankToNull(String? value) {
    if (value == null) return null;
    final String trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

class _NameParts {
  const _NameParts(this.trackNumber, this.title);

  final int? trackNumber;
  final String title;
}

class _FolderNames {
  const _FolderNames({this.artist, this.album});

  final String? artist;
  final String? album;
}
