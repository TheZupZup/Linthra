import 'package:flutter/widgets.dart';

/// The intents Linthra's keyboard shortcuts dispatch.
///
/// Named intents rather than bare callbacks so the binding stays declarative
/// and, more usefully, so a surface that knows better can *override* one
/// locally. `Actions` is resolved from whatever holds focus upward, so the
/// navigation shell can answer [ToggleQueueIntent] with its own side panel
/// while the app-level fallback opens the queue sheet — with no shortcut code
/// on either side knowing about the other.
///
/// They are also the seam for a non-keyboard caller: a toolbar button or a
/// future command palette can `Actions.invoke` the same intent instead of
/// re-implementing what the shortcut does.

/// Toggle between playing and paused.
class TogglePlayPauseIntent extends Intent {
  const TogglePlayPauseIntent();
}

/// Skip to the next track in the queue.
class SkipToNextIntent extends Intent {
  const SkipToNextIntent();
}

/// Go back to the previous track.
class SkipToPreviousIntent extends Intent {
  const SkipToPreviousIntent();
}

/// Opens the quick-search overlay.
class OpenQuickSearchIntent extends Intent {
  const OpenQuickSearchIntent();
}

/// Go to the Library tab.
class OpenLibraryIntent extends Intent {
  const OpenLibraryIntent();
}

/// Show or hide the queue — the side column on a wide desktop window, the
/// sheet everywhere else.
class ToggleQueueIntent extends Intent {
  const ToggleQueueIntent();
}

/// Open the full-screen Now Playing view.
class OpenNowPlayingIntent extends Intent {
  const OpenNowPlayingIntent();
}

/// Open the keyboard shortcuts help window (#392).
class ShowKeyboardShortcutsIntent extends Intent {
  const ShowKeyboardShortcutsIntent();
}
