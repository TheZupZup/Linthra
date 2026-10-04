import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';

/// Whether starting playback from a list should also open Now Playing.
///
/// On a phone it should: the mini-player is a thin strip, and the full player
/// is where the song is. On a desktop it should not. The bottom bar already
/// carries the track with its transport, seek and volume, and the list the
/// user just picked from is what they are working in. Opening a window-sized
/// player on every click took them out of the library and cost a click to get
/// back, every time. Now Playing stays one click away there: the bottom bar
/// opens it, and so does its keyboard shortcut.
///
/// Decided by the platform the app presents as, the same way the desktop shell
/// and the playlist drag decide, so a test can ask for either behaviour.
bool opensNowPlayingOnPlay(BuildContext context) {
  switch (Theme.of(context).platform) {
    case TargetPlatform.linux:
    case TargetPlatform.macOS:
    case TargetPlatform.windows:
      return false;
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.fuchsia:
      return true;
  }
}

/// Opens Now Playing after playback was started from a list, where the
/// platform expects that. See [opensNowPlayingOnPlay].
void showNowPlayingAfterPlay(BuildContext context) {
  if (!opensNowPlayingOnPlay(context)) return;
  unawaited(context.push(AppRoutes.player));
}
