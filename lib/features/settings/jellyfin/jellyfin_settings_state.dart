import '../../../core/sources/jellyfin/jellyfin_exception.dart';

/// Where the Jellyfin connection is in its lifecycle.
enum JellyfinConnectionPhase {
  /// No session and nothing in progress.
  disconnected,

  /// A connection test is running.
  testing,

  /// A connection test just succeeded; not signed in yet.
  tested,

  /// Sign-in is running.
  signingIn,

  /// Signed in — a session exists.
  connected,
}

/// Immutable snapshot the Jellyfin settings UI renders from.
///
/// The screen reads this and never reaches into HTTP, the authenticator, or the
/// session store directly — the controller is the only thing that mutates it.
///
/// Security: this state intentionally holds NO secret. There is no token and no
/// password field; only display-safe values (server URL, username, server name)
/// live here, so nothing sensitive can leak through the widget tree or a
/// state dump.
class JellyfinSettingsState {
  const JellyfinSettingsState({
    this.phase = JellyfinConnectionPhase.disconnected,
    this.baseUrl,
    this.username,
    this.serverName,
    this.serverVersion,
    this.productName,
    this.statusMessage,
    this.errorMessage,
    this.errorKind,
  });

  final JellyfinConnectionPhase phase;

  /// Last connected/tested base URL, used to prefill the field. Not secret.
  final String? baseUrl;

  /// Connected (or last-entered) username, for prefill/display. Not secret.
  final String? username;

  /// Friendly server name from a connection test or the saved session.
  final String? serverName;

  /// Server version string from a connection test or the saved session.
  final String? serverVersion;

  /// Server product name (e.g. "Jellyfin Server"), when reported.
  final String? productName;

  /// A friendly, non-error status line (e.g. "Connected to …").
  final String? statusMessage;

  /// A friendly error line, when the last action failed.
  final String? errorMessage;

  /// The kind of the last failure, kept for the diagnostics report so it can
  /// show a stable, non-secret error category. The friendly [errorMessage] is
  /// already secret-free; the kind is even safer to surface in a bug report.
  final JellyfinErrorKind? errorKind;

  bool get isConnected => phase == JellyfinConnectionPhase.connected;

  /// True while a network action is in flight, so the UI can disable inputs and
  /// show a spinner.
  bool get isBusy =>
      phase == JellyfinConnectionPhase.testing ||
      phase == JellyfinConnectionPhase.signingIn;
}
