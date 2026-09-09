/// The application-level actions a desktop shell can ask Linthra to perform.
///
/// These are the two MPRIS root-interface methods (`Raise` and `Quit`), named
/// as an interface of their own so `MprisPlayerObject` can offer them without
/// knowing anything about GTK windows, and so a platform that cannot do them
/// simply passes nothing.
abstract interface class DesktopApplicationActions {
  /// Brings the window back to the front, showing it again if a close hid it.
  Future<void> raise();

  /// Releases everything Linthra owns and ends the process.
  Future<void> quit();
}
