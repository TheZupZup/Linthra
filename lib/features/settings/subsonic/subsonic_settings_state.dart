import '../../../core/sources/subsonic/subsonic_exception.dart';

/// Where the Subsonic/Navidrome connection is in its lifecycle.
enum SubsonicConnectionPhase {
  /// No session and nothing in progress.
  disconnected,

  /// A connection test is running.
  testing,

  /// A connection test just succeeded (server reachable, credentials accepted);
  /// not signed in / persisted yet.
  tested,

  /// Sign-in is running.
  signingIn,

  /// Signed in — a session exists.
  connected,
}

/// Immutable snapshot the Subsonic settings UI renders from.
///
/// The screen reads this and never reaches into HTTP, the authenticator, or the
/// session store directly — the controller is the only thing that mutates it.
///
/// Security: this state intentionally holds NO secret. There is no token, salt,
/// or password field; only display-safe values (server URL, username, server
/// product/version) live here, so nothing sensitive can leak through the widget
/// tree or a state dump.
class SubsonicSettingsState {
  const SubsonicSettingsState({
    this.phase = SubsonicConnectionPhase.disconnected,
    this.baseUrl,
    this.username,
    this.serverType,
    this.serverVersion,
    this.apiVersion,
    this.statusMessage,
    this.errorMessage,
    this.errorKind,
  });

  final SubsonicConnectionPhase phase;

  /// Last connected/tested base URL, used to prefill the field. Not secret.
  final String? baseUrl;

  /// Connected (or last-entered) username, for prefill/display. Not secret.
  final String? username;

  /// Server product (e.g. `navidrome`) from a test or the saved session.
  final String? serverType;

  /// Server version (OpenSubsonic `serverVersion`), when reported.
  final String? serverVersion;

  /// Subsonic API version the server speaks, when reported.
  final String? apiVersion;

  /// A friendly, non-error status line (e.g. "Connected to …").
  final String? statusMessage;

  /// A friendly error line, when the last action failed.
  final String? errorMessage;

  /// The kind of the last failure, kept for the UI to branch on. The friendly
  /// [errorMessage] is already secret-free.
  final SubsonicErrorKind? errorKind;

  bool get isConnected => phase == SubsonicConnectionPhase.connected;

  /// True while a network action is in flight, so the UI can disable inputs and
  /// show a spinner.
  bool get isBusy =>
      phase == SubsonicConnectionPhase.testing ||
      phase == SubsonicConnectionPhase.signingIn;

  /// A friendly product label for display, title-casing the reported [serverType]
  /// (e.g. "Navidrome") or falling back to "Subsonic".
  String get productLabel {
    final String? t = serverType;
    if (t == null || t.isEmpty) return 'Subsonic';
    return t[0].toUpperCase() + t.substring(1);
  }
}
