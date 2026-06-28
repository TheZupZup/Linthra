import 'dart:io';

import 'package:flutter/services.dart';

import '../../features/appearance/launcher_icon.dart';
import 'launcher_icon_service.dart';

/// A [LauncherIconService] that switches the Android launcher icon by toggling
/// `<activity-alias>` entries through a native method channel.
///
/// Each branding variant has its own alias in `AndroidManifest.xml`, all
/// targeting `.MainActivity`; the native handler (`LauncherIconChannel.kt`)
/// enables the chosen alias and disables the others via
/// `PackageManager.setComponentEnabledSetting(..., DONT_KILL_APP)` — so the
/// running process, the audio foreground service, notifications, and Android
/// Auto are never interrupted.
///
/// Off Android — or when the native handler isn't registered — every call is a
/// safe no-op returning `false`, mirroring how `MethodChannelSafFolderPicker`
/// degrades, so callers never have to guard the platform split.
class AndroidLauncherIconService implements LauncherIconService {
  const AndroidLauncherIconService();

  // Mirrors LauncherIconChannel.kt's CHANNEL name.
  static const MethodChannel _channel =
      MethodChannel('io.github.thezupzup.linthra/launcher_icon');

  @override
  bool get isSupported => Platform.isAndroid;

  @override
  Future<bool> applyVariant(String variantId) async {
    if (!Platform.isAndroid) {
      return false;
    }
    // Resolve through the registry so an unknown id falls back to the default
    // (Classic) alias rather than naming a component that doesn't exist.
    final LauncherIconAlias alias = LauncherIconAliases.byVariantId(variantId);
    try {
      final bool? ok = await _channel.invokeMethod<bool>(
        'setIcon',
        <String, String>{'alias': alias.aliasName},
      );
      return ok ?? false;
    } on MissingPluginException {
      // Native handler not registered (shouldn't happen on a real build); let
      // the caller carry on with the in-app selection.
      return false;
    } on PlatformException {
      // Package-manager hiccup; treat as "not applied" rather than surfacing a
      // raw platform error into the UI.
      return false;
    }
  }
}
