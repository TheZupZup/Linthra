import 'dart:io';

import 'package:flutter/services.dart';

import 'local_lyrics_reader.dart';

/// A [LocalLyricsReader] that reads a sidecar lyrics file sitting next to an
/// Android SAF audio document, through the same native `…/saf` method channel
/// the document lister uses. The native side finds the sibling document with the
/// same base name and the requested extension *within the tree the user already
/// granted*, reads its text, and returns it — so it needs no extra storage
/// permission and never touches a raw `/storage/...` path.
///
/// Only `content://` document URIs are its job; a filesystem path (desktop) is
/// [IoLocalLyricsReader]'s, so this returns `null` for those. Off Android, or
/// when the native handler isn't registered, it returns `null` too.
///
/// Best-effort and total: a [MissingPluginException] or [PlatformException]
/// becomes `null` (no lyrics), never a surfaced error — and the native message,
/// which could carry a file detail, is never propagated.
class MethodChannelSafLyricsReader implements LocalLyricsReader {
  const MethodChannelSafLyricsReader();

  // Mirrors MethodChannelSafDocumentLister / MainActivity.kt's SAF_CHANNEL.
  static const MethodChannel _channel =
      MethodChannel('io.github.thezupzup.linthra/saf');

  @override
  Future<String?> readSidecar(String trackUri, String extension) async {
    if (!Platform.isAndroid) return null;
    if (!trackUri.startsWith('content://')) return null;
    try {
      return await _channel.invokeMethod<String>(
        'readSidecarText',
        <String, Object?>{'uri': trackUri, 'extension': extension},
      );
    } on MissingPluginException {
      return null;
    } on PlatformException {
      // The native side couldn't read it; treat as "no lyrics" rather than
      // surfacing a raw platform error (or any file detail it might carry).
      return null;
    }
  }
}
