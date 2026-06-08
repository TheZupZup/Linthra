import 'dart:io';

import 'package:flutter/services.dart';

import 'saf_permission_probe.dart';

/// A [SafPermissionProbe] backed by the same native Android SAF method channel
/// the document lister uses. It asks the content resolver whether a persisted
/// read grant for the given tree URI is still held.
///
/// This is the only Dart file (besides the lister) that talks to that channel.
/// Off Android, or when the native handler isn't registered, it reports `null`
/// so the diagnostics line is simply omitted instead of guessing.
class MethodChannelSafPermissionProbe implements SafPermissionProbe {
  const MethodChannelSafPermissionProbe();

  // Mirrors MethodChannelSafDocumentLister / MainActivity.kt's SAF_CHANNEL.
  static const MethodChannel _channel =
      MethodChannel('io.github.thezupzup.linthra/saf');

  @override
  Future<bool?> hasPersistedPermission(String treeUri) async {
    if (!Platform.isAndroid) {
      return null;
    }
    try {
      return await _channel.invokeMethod<bool>(
        'hasPersistedPermission',
        <String, Object?>{'treeUri': treeUri},
      );
    } on MissingPluginException {
      return null;
    } on PlatformException {
      // The native side failed to answer; treat as "unknown" rather than
      // surfacing a raw platform error into a diagnostic line.
      return null;
    }
  }
}
