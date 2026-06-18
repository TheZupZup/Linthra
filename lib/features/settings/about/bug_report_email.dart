/// Builds the prefilled `mailto:` link behind the Support card's "Report a bug"
/// action — the low-friction path for Google Play closed testers to send a
/// useful report.
///
/// Pure and plugin-free: it only assembles a [Uri], so it is trivial to unit
/// test and does no I/O. The Support card hands the link to the shared external
/// link launcher, which opens the user's own mail app at a draft addressed to
/// support, with the subject and a fill-in body already in place. Nothing is
/// sent — the tester reviews the draft and sends it themselves.
abstract final class BugReportEmail {
  /// Where tester bug reports go (the support inbox documented in PRIVACY.md
  /// and shown by the Support card's "Email support" row).
  static const String recipient = 'support@linthra.ca';

  /// A fixed, recognisable subject so reports are easy to spot and triage.
  static const String subject = 'Linthra bug report';

  /// The fill-in template the tester sees in the draft body. Blank lines invite
  /// a short answer under each prompt; the device/version/source lines nudge
  /// testers to include the details that make a report actionable.
  static const String body = 'Hi Linthra team,\n'
      '\n'
      'I found an issue while testing Linthra.\n'
      '\n'
      'What happened:\n'
      '\n'
      '\n'
      'What I expected:\n'
      '\n'
      '\n'
      'Steps to reproduce:\n'
      '1.\n'
      '2.\n'
      '3.\n'
      '\n'
      'Device:\n'
      'Android version:\n'
      'Linthra version:\n'
      'Music source: Local / Jellyfin / Navidrome / Subsonic\n'
      'Additional notes:\n';

  /// The `mailto:` link that opens a prefilled draft to [recipient].
  ///
  /// [subject] and [body] are percent-encoded with [Uri.encodeComponent]
  /// (spaces become `%20`, newlines `%0A`) and assembled into the query by
  /// hand, then parsed back into a [Uri]. Encoding the values ourselves — rather
  /// than via `Uri(queryParameters: …)`, which uses `+` for spaces that some
  /// mail apps render literally — keeps the draft reading exactly as written.
  static Uri mailtoUri() {
    final String query = 'subject=${Uri.encodeComponent(subject)}'
        '&body=${Uri.encodeComponent(body)}';
    return Uri.parse('mailto:$recipient?$query');
  }
}
