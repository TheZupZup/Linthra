/// What the desktop said about Linthra running on with its window closed
/// (#754).
///
/// Inside a Flatpak, xdg-desktop-portal watches for apps that have no window
/// open, and with the app's `background` permission set to "no" it kills them
/// (SIGKILL) a few seconds after the window goes. "Keep playing" hides the
/// window while music plays, so before relying on that Linthra asks the
/// Background portal, and if the answer is no, closing the window quits the
/// normal way instead.
enum BackgroundPermission {
  /// Allowed, or nothing on this desktop watches for apps without a window.
  allowed,

  /// The desktop said no: a hidden Linthra would be killed mid-song.
  denied,

  /// No answer (yet), or the question couldn't be put. Hiding the window goes
  /// on as it did before Linthra asked.
  unknown,
}

/// Puts the question to the desktop. See [BackgroundPermission].
abstract interface class BackgroundPermissionRequester {
  /// Asks whether Linthra may keep running with no window open. Never throws.
  Future<BackgroundPermission> request();
}
