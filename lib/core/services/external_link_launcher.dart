import 'package:url_launcher/url_launcher.dart' as url_launcher;

/// Opens an external link — typically the user's browser — for the app.
///
/// The single seam between the app and `url_launcher`, so feature code depends
/// only on this interface and never imports the plugin directly. That keeps
/// widget tests plugin-free (they inject a fake) and matches how the rest of the
/// app wraps its platform plugins. The only caller today is the "Report a bug"
/// flow's "Open GitHub issue" action, which hands the browser a prefilled — but
/// unsubmitted — issue. Every launch is an explicit user tap; nothing opens on
/// its own.
abstract interface class ExternalLinkLauncher {
  /// Opens [url] in an external application (the browser). Returns true when the
  /// platform accepted the request, false otherwise. Never throws for an
  /// unlaunchable URL — the caller falls back (e.g. copies the link instead).
  Future<bool> open(Uri url);
}

/// The production [ExternalLinkLauncher], backed by `url_launcher`.
///
/// Launches in an external application so a prefilled GitHub issue opens in the
/// real browser, not an in-app webview. Any plugin failure is swallowed and
/// reported as `false` so the caller can fall back gracefully.
class UrlLauncherExternalLinkLauncher implements ExternalLinkLauncher {
  const UrlLauncherExternalLinkLauncher();

  @override
  Future<bool> open(Uri url) async {
    try {
      return await url_launcher.launchUrl(
        url,
        mode: url_launcher.LaunchMode.externalApplication,
      );
    } catch (_) {
      return false;
    }
  }
}
