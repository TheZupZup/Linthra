import 'package:flutter/material.dart';

import '../../app/theme.dart';
import 'now_playing_preview_screen.dart';

/// Dev-only entry point for previewing the Now Playing screen with fake data —
/// no Plex / Jellyfin / Navidrome connection required.
///
/// Run it instead of the normal app:
///
/// ```
/// flutter run -t lib/ui_linthra/preview/now_playing_preview_main.dart
/// ```
///
/// Use the dropdown at the top to flip between sample states (different
/// providers, paused / buffering / error, long titles, missing artwork). Edit
/// the design in `lib/ui_linthra/` and hot-reload to see changes instantly.
///
/// This file is never part of the shipping app (the app's entry point is
/// `lib/main.dart`).
void main() {
  runApp(const _NowPlayingPreviewApp());
}

class _NowPlayingPreviewApp extends StatelessWidget {
  const _NowPlayingPreviewApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Linthra — Now Playing preview',
      debugShowCheckedModeBanner: false,
      // Dark mode is Linthra's primary experience, so the preview matches it.
      theme: AppTheme.dark,
      home: const NowPlayingPreviewScreen(),
    );
  }
}
