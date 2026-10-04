import 'package:flutter/material.dart';

/// Whether the app presents itself as a desktop app here: pointer and
/// keyboard first, with the desktop shell's bottom bar carrying playback.
///
/// Read off the theme's platform, the way the desktop shell and the playlist
/// drag decide, rather than off the host OS. A widget test can then render
/// either presentation by setting `ThemeData.platform`, and a feature widget
/// asks this one question instead of carrying its own platform switch.
bool usesDesktopPresentation(BuildContext context) {
  switch (Theme.of(context).platform) {
    case TargetPlatform.linux:
    case TargetPlatform.macOS:
    case TargetPlatform.windows:
      return true;
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.fuchsia:
      return false;
  }
}
