/// Answers one diagnostic question: does the app still hold a *persisted* SAF
/// read grant for a previously picked `content://` tree URI?
///
/// On Android the folder chooser's grant is what lets a scan read the selected
/// tree after a restart. If it was never persisted (or was revoked), scanning a
/// removable SD card silently turns up nothing. Surfacing the grant's presence
/// in diagnostics tells a "no music found" report apart from a permission loss.
///
/// Kept behind an interface so the diagnostics collector stays testable without
/// a device or platform channel: the production binding is
/// `MethodChannelSafPermissionProbe` (Android only); elsewhere the unsupported
/// binding reports `null` ("not determinable here").
abstract interface class SafPermissionProbe {
  /// Whether a persisted read grant for [treeUri] is currently held.
  ///
  /// Returns `null` when the answer can't be determined on this platform (off
  /// Android, or the native handler isn't registered) — never a guess.
  Future<bool?> hasPersistedPermission(String treeUri);
}

/// The default [SafPermissionProbe] for platforms without the native SAF channel
/// (desktop, tests): it always reports `null`, so diagnostics simply omit the
/// persisted-permission line rather than implying an answer it can't know.
class UnsupportedSafPermissionProbe implements SafPermissionProbe {
  const UnsupportedSafPermissionProbe();

  @override
  Future<bool?> hasPersistedPermission(String treeUri) async => null;
}
