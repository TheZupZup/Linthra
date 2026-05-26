/// Builds the Markdown "Report a bug" document and the GitHub "new issue" URL
/// that prefills it.
///
/// Pure and free of any I/O or plugin: the screen feeds in the user's text, the
/// secret-free diagnostics block (already rendered by `AppDiagnostics.report`),
/// and the optional recent-events block, and gets back a single Markdown string
/// to copy, save, or hand to the browser as a prefilled issue. Nothing here
/// sends, uploads, or logs anything — assembling text and a URL is all it does.
abstract final class BugReport {
  /// The public repository the "Open GitHub issue" action targets. The report
  /// carries no token; the prefilled issue opens in the user's own browser,
  /// where they review and submit it themselves.
  static const String repositoryUrl = 'https://github.com/thezupzup/linthra';

  /// Shown in place of a free-text field the user left blank, so the report's
  /// structure is always present for whoever reads it.
  static const String fieldPlaceholder = '_(add details here)_';

  /// The scaffold offered for "Steps to reproduce" when left blank.
  static const String stepsScaffold = '1. \n2. \n3. ';

  /// Assembles the Markdown bug report.
  ///
  /// [diagnostics] is the secret-free block from `AppDiagnostics.report`.
  /// [recentEvents], when non-null and non-blank, is appended as its own fenced
  /// "Recent app events" section. The four free-text fields fall back to a
  /// neutral placeholder (and steps to a numbered scaffold) when blank.
  static String markdown({
    String summary = '',
    String whatHappened = '',
    String steps = '',
    String expected = '',
    required String diagnostics,
    String? recentEvents,
  }) {
    final StringBuffer buffer = StringBuffer()
      ..writeln('# Linthra bug report')
      ..writeln()
      ..writeln('## Summary')
      ..writeln(_fieldOr(summary, fieldPlaceholder))
      ..writeln()
      ..writeln('## What happened')
      ..writeln(_fieldOr(whatHappened, fieldPlaceholder))
      ..writeln()
      ..writeln('## Steps to reproduce')
      ..writeln(_fieldOr(steps, stepsScaffold))
      ..writeln()
      ..writeln('## Expected behavior')
      ..writeln(_fieldOr(expected, fieldPlaceholder))
      ..writeln()
      ..writeln('## Diagnostics')
      ..writeln('```text')
      ..writeln(diagnostics.trim())
      ..writeln('```');

    final String? events = _nullIfBlank(recentEvents);
    if (events != null) {
      buffer
        ..writeln()
        ..writeln('## Recent app events')
        ..writeln('```text')
        ..writeln(events)
        ..writeln('```');
    }

    return '${buffer.toString().trimRight()}\n';
  }

  /// Builds the GitHub "new issue" URL that prefills [body] (and an optional
  /// [title]) and tags it `bug`. It is opened in the user's browser; they
  /// review and submit. No GitHub token is involved and nothing is posted by the
  /// app.
  static Uri newIssueUrl({required String body, String title = ''}) {
    final String trimmedTitle = title.trim();
    return Uri.parse('$repositoryUrl/issues/new').replace(
      queryParameters: <String, String>{
        'labels': 'bug',
        if (trimmedTitle.isNotEmpty) 'title': trimmedTitle,
        'body': body,
      },
    );
  }

  /// A concise issue title derived from the user's [summary], or a sensible
  /// default when it is blank. Truncated so the URL stays reasonable.
  static String issueTitle(String summary) {
    final String trimmed = summary.trim();
    if (trimmed.isEmpty) return 'Bug report';
    if (trimmed.length <= 72) return trimmed;
    return '${trimmed.substring(0, 69)}...';
  }

  static String _fieldOr(String value, String fallback) {
    final String trimmed = value.trim();
    return trimmed.isEmpty ? fallback : trimmed;
  }

  static String? _nullIfBlank(String? value) {
    if (value == null) return null;
    final String trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
