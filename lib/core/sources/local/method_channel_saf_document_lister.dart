import 'dart:io';

import 'package:flutter/services.dart';

import 'folder_scan_exception.dart';
import 'local_audio_metadata.dart';
import 'saf_document_lister.dart';

/// A [SafDocumentLister] backed by a platform method channel into native
/// Android, which walks the picked SAF tree with the content resolver
/// (`DocumentsContract`) and returns the audio documents it finds.
///
/// This is the only Dart file that talks to the native SAF channel. Everything
/// above it depends on [SafDocumentLister], so the scan flow stays testable
/// with a fake and the UI never sees a platform channel.
///
/// On any non-Android platform, or when the native handler isn't registered
/// ([MissingPluginException]), it throws [SafUnsupportedException] so the
/// caller falls back to filesystem path resolution. A real native failure
/// becomes a [FolderScanException] with a friendly message — never a raw one.
class MethodChannelSafDocumentLister implements SafDocumentLister {
  const MethodChannelSafDocumentLister();

  static const String _channelName = 'io.github.thezupzup.linthra/saf';
  static const MethodChannel _channel = MethodChannel(_channelName);

  @override
  Future<SafScanResult> listAudioDocuments(String treeUri) async {
    if (!Platform.isAndroid) {
      throw const SafUnsupportedException();
    }

    final Map<Object?, Object?>? result;
    try {
      result = await _channel.invokeMapMethod<Object?, Object?>(
        'listAudioDocuments',
        <String, Object?>{'treeUri': treeUri},
      );
    } on MissingPluginException {
      throw const SafUnsupportedException();
    } on PlatformException {
      // The native side ran but failed (revoked grant, provider error). Surface
      // a friendly, secret-free message rather than the raw platform exception.
      throw FolderScanException(
        "Couldn't read this folder through Android's Storage Access Framework. "
        'Try selecting it again, or pick a different folder.',
        folder: treeUri,
      );
    }

    return parseScanResult(result);
  }

  /// Parses the native `listAudioDocuments` reply into a [SafScanResult].
  ///
  /// Pure and public so the parsing — the part with real logic — is unit-testable
  /// without a device or platform channel. Deliberately tolerant: a null reply,
  /// a malformed entry, or a missing count never throws; counts fall back so an
  /// older native build that only returned documents still scans.
  static SafScanResult parseScanResult(Map<Object?, Object?>? result) {
    if (result == null) {
      return const SafScanResult();
    }
    final List<SafAudioDocument> documents = <SafAudioDocument>[];
    final Object? rawDocuments = result['documents'];
    if (rawDocuments is List) {
      for (final Object? entry in rawDocuments) {
        if (entry is Map) {
          final Object? uri = entry['uri'];
          final Object? name = entry['name'];
          final Object? mime = entry['mime'];
          if (uri is String && uri.isNotEmpty && name is String) {
            documents.add(SafAudioDocument(
              uri: uri,
              name: name,
              mimeType: mime is String ? mime : null,
              metadata: parseMetadata(entry),
            ));
          }
        }
      }
    }
    final Object? filesVisited = result['filesVisited'];
    final Object? foldersVisited = result['foldersVisited'];
    final Object? readFailures = result['readFailures'];
    return SafScanResult(
      documents: documents,
      // Fall back to the document count if the native side is an older build
      // that didn't report a visited total, so the scan still works.
      filesVisited: filesVisited is int ? filesVisited : documents.length,
      foldersVisited: foldersVisited is int ? foldersVisited : 0,
      readFailures: readFailures is int ? readFailures : 0,
    );
  }

  /// Builds the [LocalAudioMetadata] for one document [entry] from the optional
  /// tag fields the native walk attached (`title`, `artist`, `albumArtist`,
  /// `album`, `track`, `durationMs`), or null when none are present — an older
  /// native build, or a file the platform could not read tags from.
  ///
  /// Pure and tolerant so it is unit-testable and never throws on a malformed or
  /// partial reply: a non-string text field, a `track` like `"3/12"`, and a
  /// `durationMs` sent as either an int or a numeric string are all handled, and
  /// a blank or unparseable value simply drops to null (the mapper then falls
  /// back to the file name).
  static LocalAudioMetadata? parseMetadata(Map<Object?, Object?> entry) {
    final String? title = _string(entry['title']);
    final String? artist = _string(entry['artist']);
    final String? albumArtist = _string(entry['albumArtist']);
    final String? album = _string(entry['album']);
    final int? trackNumber = _trackNumber(entry['track']);
    final Duration? duration = _durationMs(entry['durationMs']);
    if (title == null &&
        artist == null &&
        albumArtist == null &&
        album == null &&
        trackNumber == null &&
        duration == null) {
      return null;
    }
    return LocalAudioMetadata(
      title: title,
      artist: artist,
      albumArtist: albumArtist,
      album: album,
      trackNumber: trackNumber,
      duration: duration,
    );
  }

  /// A non-blank trimmed string, or null for anything else (absent, non-string,
  /// or blank).
  static String? _string(Object? value) {
    if (value is! String) return null;
    final String trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// The leading integer of a track field, which a tagger may store as `"3"` or
  /// `"3/12"` (track/total). Non-positive or unparseable values are null.
  static int? _trackNumber(Object? value) {
    if (value is int) return value > 0 ? value : null;
    if (value is! String) return null;
    final RegExpMatch? match = RegExp(r'\d+').firstMatch(value);
    if (match == null) return null;
    final int? parsed = int.tryParse(match.group(0)!);
    return (parsed != null && parsed > 0) ? parsed : null;
  }

  /// A duration from a milliseconds value sent as an int or a numeric string.
  /// Zero/negative/unparseable maps to null (unknown), so the mapper leaves the
  /// duration at zero rather than inventing one.
  static Duration? _durationMs(Object? value) {
    int? ms;
    if (value is int) {
      ms = value;
    } else if (value is String) {
      ms = int.tryParse(value.trim());
    }
    if (ms == null || ms <= 0) return null;
    return Duration(milliseconds: ms);
  }
}
