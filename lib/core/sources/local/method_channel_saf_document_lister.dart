import 'dart:io';

import 'package:flutter/services.dart';

import 'folder_scan_exception.dart';
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
  Future<List<SafAudioDocument>> listAudioDocuments(String treeUri) async {
    if (!Platform.isAndroid) {
      throw const SafUnsupportedException();
    }

    final List<Object?>? result;
    try {
      result = await _channel.invokeListMethod<Object?>(
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

    if (result == null) {
      return const <SafAudioDocument>[];
    }
    final List<SafAudioDocument> documents = <SafAudioDocument>[];
    for (final Object? entry in result) {
      if (entry is Map) {
        final Object? uri = entry['uri'];
        final Object? name = entry['name'];
        if (uri is String && uri.isNotEmpty && name is String) {
          documents.add(SafAudioDocument(uri: uri, name: name));
        }
      }
    }
    return documents;
  }
}
