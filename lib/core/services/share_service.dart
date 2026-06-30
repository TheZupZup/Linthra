/// Hands a short piece of text to the platform's native share sheet.
///
/// This is the seam the About page's "Share Linthra" action drives so a tap
/// opens the system share sheet (Android `ACTION_SEND`) with an invite the user
/// can send wherever they like. It is intentionally tiny and best-effort,
/// mirroring [LauncherIconService]: implementations must never throw into the
/// UI, and on a platform or device without a share sheet the no-op binding
/// ([isSupported] == false) keeps the rest of the page working unchanged.
///
/// It carries no recipient, no account, and no tracking — only the text the
/// caller passes. Every share is an explicit user tap; nothing is sent on its
/// own.
abstract interface class ShareService {
  /// Whether a native share sheet is available here. `false` off Android (and
  /// in tests), so the UI can hide the "Share Linthra" entry rather than offer
  /// an action that can't run.
  bool get isSupported;

  /// Opens the system share sheet for [text].
  ///
  /// Returns `true` when the sheet was presented, `false` otherwise.
  /// Implementations must swallow platform errors and return `false` rather
  /// than throwing, so a failed or unsupported share can never break the page.
  Future<bool> share(String text);
}
