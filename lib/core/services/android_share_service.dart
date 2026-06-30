import 'dart:io';

import 'package:flutter/services.dart';

import 'share_service.dart';

/// A [ShareService] that opens the Android system share sheet through a native
/// method channel.
///
/// The native handler (`ShareChannel.kt`) fires a plain `ACTION_SEND` intent
/// wrapped in a chooser — the standard AOSP share sheet, no Google Play
/// Services and no permission required. The text is the only thing crossing the
/// channel; there is no recipient, account, or tracking.
///
/// Off Android — or when the native handler isn't registered — every call is a
/// safe no-op returning `false`, mirroring how [AndroidLauncherIconService]
/// degrades, so callers never have to guard the platform split.
class AndroidShareService implements ShareService {
  const AndroidShareService();

  // Mirrors ShareChannel.kt's CHANNEL name.
  static const MethodChannel _channel =
      MethodChannel('io.github.thezupzup.linthra/share');

  @override
  bool get isSupported => Platform.isAndroid;

  @override
  Future<bool> share(String text) async {
    if (!Platform.isAndroid) {
      return false;
    }
    try {
      final bool? ok = await _channel.invokeMethod<bool>(
        'shareText',
        <String, String>{'text': text},
      );
      return ok ?? false;
    } on MissingPluginException {
      // Native handler not registered (shouldn't happen on a real build); let
      // the caller carry on without surfacing an error.
      return false;
    } on PlatformException {
      // No activity to host the chooser, or the system declined; treat as "not
      // shared" rather than surfacing a raw platform error into the UI.
      return false;
    }
  }
}
