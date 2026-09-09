/// What closing the desktop window does (issue #401).
///
/// Desktop-only: on Android the window is an Activity the platform owns, and
/// closing it never meant "quit the app" in the first place. Linthra ships
/// [quit] as the default so the behaviour out of the box is the one it has
/// always had (closing the window ends the app), and [keepPlaying] is an
/// explicit opt-in, never a surprise background process.
enum DesktopCloseBehavior {
  /// Closing the window quits Linthra: playback stops and every resource the
  /// app owns is released.
  quit,

  /// Closing the window hides it and leaves playback running, with the desktop
  /// media controls (MPRIS) still live. Only takes effect while audio is
  /// actually playing. See `DesktopClosePolicy`, which is what keeps a closed
  /// window from leaving a silent, invisible process behind.
  keepPlaying;

  /// The behaviour a fresh install gets, and the one a missing or unreadable
  /// stored value falls back to.
  static const DesktopCloseBehavior defaultBehavior = DesktopCloseBehavior.quit;

  /// The user-facing name of this choice, in Settings.
  String get label {
    switch (this) {
      case DesktopCloseBehavior.quit:
        return 'Quit Linthra';
      case DesktopCloseBehavior.keepPlaying:
        return 'Keep playing in the background';
    }
  }

  /// A one-line description of what this choice does, shown under [label].
  String get description {
    switch (this) {
      case DesktopCloseBehavior.quit:
        return 'Playback stops and the app closes.';
      case DesktopCloseBehavior.keepPlaying:
        return 'The window hides while music keeps playing. Linthra quits on '
            'its own once the queue ends.';
    }
  }

  /// The stable string written to storage. Deliberately not `Enum.name` or the
  /// index: renaming or reordering the enum must not silently change what a
  /// previously stored preference means.
  String get storageValue {
    switch (this) {
      case DesktopCloseBehavior.quit:
        return 'quit';
      case DesktopCloseBehavior.keepPlaying:
        return 'keep_playing';
    }
  }

  /// Reads back [storageValue]. Anything unrecognised (an older or newer
  /// build's value, a corrupted entry) resolves to [defaultBehavior] rather
  /// than throwing on startup.
  static DesktopCloseBehavior fromStorage(String? value) {
    for (final DesktopCloseBehavior behavior in DesktopCloseBehavior.values) {
      if (behavior.storageValue == value) return behavior;
    }
    return defaultBehavior;
  }
}
