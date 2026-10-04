import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../shared/layout/desktop_presentation.dart';

/// Whether starting playback from a list should also open Now Playing.
///
/// On a phone it should: the mini-player is a thin strip, and the full player
/// is where the song is. On a desktop it should not. The bottom bar already
/// carries the track with its transport, seek and volume, and the list the
/// user just picked from is what they are working in. Opening a window-sized
/// player on every click took them out of the library and cost a click to get
/// back, every time. Now Playing stays one click away there: the bottom bar
/// opens it, and so does its keyboard shortcut.
bool opensNowPlayingOnPlay(BuildContext context) =>
    !usesDesktopPresentation(context);

/// Opens Now Playing after playback was started from a list, where the
/// platform expects that. See [opensNowPlayingOnPlay].
void showNowPlayingAfterPlay(BuildContext context) {
  if (!opensNowPlayingOnPlay(context)) return;
  unawaited(context.push(AppRoutes.player));
}
