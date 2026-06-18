/// Builds the plain-text "app info" block the Support card's "Copy app info"
/// action puts on the clipboard — a short, paste-ready diagnostic a Google Play
/// closed tester can drop into a bug report.
///
/// Pure and plugin-free: it only formats the values it is handed into text, so
/// it does no I/O and is trivial to unit test. The Support card reads the live
/// app version (and, on Android, the OS version) and passes them in. By
/// construction the block carries no personal data, server URL, auth token,
/// username, file path, or library name — only the app version and, when known,
/// the Android OS version, followed by blank fill-in prompts the tester
/// completes themselves.
///
/// Fields with no safe, already-available source on this build — the build
/// number (the Android-only `versionCode`, intentionally absent from AppInfo),
/// the device model, and the install source — are left as blank prompts rather
/// than guessed or backed by a new dependency. The tester fills those in if they
/// can.
abstract final class AppInfoReport {
  /// The header line that opens the block, so a pasted report is recognisable.
  static const String header = 'Linthra app info';

  /// The music-source prompt, listing the sources Linthra can play from so the
  /// tester just indicates which they were using. Mirrors the wording of the
  /// "Report a bug" email template.
  static const String musicSourceOptions =
      'Local / Jellyfin / Navidrome / Subsonic';

  /// Assembles the block. [linthraVersion] is filled in from the app's existing
  /// version source; [androidVersion] is filled when known (Android only) and
  /// left as a blank prompt otherwise. A trailing newline lets the tester start
  /// typing on a fresh line after the final prompt.
  static String build({
    required String linthraVersion,
    String? androidVersion,
  }) {
    final List<String> lines = <String>[
      header,
      '',
      _field('Linthra version', linthraVersion),
      _field('Build number'),
      _field('Android version', androidVersion),
      _field('Device model'),
      _field('Install source'),
      _field('Music source used', musicSourceOptions),
      _field('Issue summary'),
    ];
    return '${lines.join('\n')}\n';
  }

  /// One `Label: value` line, or a blank `Label:` prompt when [value] is null or
  /// empty — so an unknown field reads as a clean fill-in, never `Label: ` with
  /// a dangling space.
  static String _field(String label, [String? value]) =>
      (value == null || value.isEmpty) ? '$label:' : '$label: $value';
}
