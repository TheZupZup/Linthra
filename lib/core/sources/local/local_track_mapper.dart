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
/// The rules run in the Rust core (native/linthra_core/src/scan/mapper.rs).
abstract final class LocalTrackMapper {
  static Track fromPath(
    String path, {
    LocalAudioMetadata? metadata,
    String? scanRoot,
  }) {
    final NativeMappedTrack native = NativeLocalTrack.map(
      source: NativeTrackSource.path,
      path: path,
      scanRoot: scanRoot,
      tags: _tags(metadata),
    );
    return _fromNative(native, id: path, metadata: metadata);
  }

  static Track fromSafDocument(SafAudioDocument document) {
    final NativeMappedTrack native = NativeLocalTrack.map(
      source: NativeTrackSource.document,
      path: document.name,
      tags: _tags(document.metadata),
    );
    return _fromNative(native, id: document.uri, metadata: document.metadata);
  }

  static Track fromCueTrack(
    CueSheetTrack cueTrack, {
    required String cuePath,
    required LocalAudioMetadata? metadata,
    required String scanRoot,
    int? cueSheetSizeBytes,
    int? cueSheetModifiedAtMs,
  }) {
    final NativeMappedTrack native = NativeLocalTrack.map(
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
}
