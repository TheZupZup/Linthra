import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../../app/dimens.dart';
import '../../../core/diagnostics/app_diagnostics.dart';
import '../../../core/diagnostics/bug_report.dart';
import 'bug_report_providers.dart';

/// The "Report a bug" screen.
///
/// Generates a high-quality, secret-free Markdown bug report entirely on the
/// device. The user fills in a short summary / steps, reviews the live preview,
/// then chooses to copy it, save it, or open a prefilled GitHub issue in their
/// browser. Nothing is sent anywhere automatically: there is no backend, no
/// GitHub token, and no upload to Claude/OpenAI/Anthropic or any third party.
class BugReportScreen extends ConsumerStatefulWidget {
  const BugReportScreen({super.key});

  @override
  ConsumerState<BugReportScreen> createState() => _BugReportScreenState();
}

class _BugReportScreenState extends ConsumerState<BugReportScreen> {
  final TextEditingController _summary = TextEditingController();
  final TextEditingController _whatHappened = TextEditingController();
  final TextEditingController _steps =
      TextEditingController(text: BugReport.stepsScaffold);
  final TextEditingController _expected = TextEditingController();

  bool _includeRecentEvents = true;
  bool _includePlayback = true;
  bool _includeCache = true;
  bool _busy = false;

  @override
  void dispose() {
    _summary.dispose();
    _whatHappened.dispose();
    _steps.dispose();
    _expected.dispose();
    super.dispose();
  }

  /// Builds the current Markdown report from the collected [bundle] and the live
  /// field/toggle state. Pure and synchronous, so the preview updates instantly.
  String _composeReport(BugReportDiagnostics bundle) {
    final String diagnostics = AppDiagnostics.report(
      bundle.data,
      includePlayback: _includePlayback,
      includeCache: _includeCache,
    );
    final bool withEvents = _includeRecentEvents && bundle.hasRecentEvents;
    return BugReport.markdown(
      summary: _summary.text,
      whatHappened: _whatHappened.text,
      steps: _steps.text,
      expected: _expected.text,
      diagnostics: diagnostics,
      recentEvents: withEvents ? bundle.recentEventLines.join('\n') : null,
    );
  }

  Future<void> _copy(BugReportDiagnostics bundle) async {
    await Clipboard.setData(ClipboardData(text: _composeReport(bundle)));
    _showSnack('Bug report copied. Review it before sharing.');
  }

  Future<void> _share(BugReportDiagnostics bundle) async {
    // No share-sheet plugin is bundled, so "Share" copies the report and tells
    // the user they can paste it wherever they like. Nothing is sent for them.
    await Clipboard.setData(ClipboardData(text: _composeReport(bundle)));
    _showSnack('Bug report copied — paste it into an email, chat, or issue.');
  }

  Future<void> _openIssue(BugReportDiagnostics bundle) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final Uri url = BugReport.newIssueUrl(
        body: _composeReport(bundle),
        title: BugReport.issueTitle(_summary.text),
      );
      final bool opened =
          await ref.read(externalLinkLauncherProvider).open(url);
      if (opened) {
        _showSnack(
            'Opening a prefilled issue — review and submit it yourself.');
      } else {
        await Clipboard.setData(ClipboardData(text: url.toString()));
        _showSnack("Couldn't open the browser — issue link copied instead.");
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save(BugReportDiagnostics bundle) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final String report = _composeReport(bundle);
      final Directory dir = await getApplicationDocumentsDirectory();
      final File file = File('${dir.path}/linthra-bug-report.md');
      await file.writeAsString(report, flush: true);
      // Show only the redacted basename — never the private app directory path.
      _showSnack('Saved to ${AppDiagnostics.redactPath(file.path)}.');
    } catch (_) {
      _showSnack("Couldn't save the report. Try Copy instead.");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<BugReportDiagnostics> snapshot =
        ref.watch(bugReportDiagnosticsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Report a bug')),
      body: snapshot.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object error, StackTrace _) => const Center(
          child: Padding(
            padding: EdgeInsets.all(AppSpacing.lg),
            child: Text(
              "Couldn't gather diagnostics right now. You can still open an "
              'issue from the project README.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
        data: (BugReportDiagnostics bundle) => _form(context, bundle),
      ),
    );
  }

  Widget _form(BuildContext context, BugReportDiagnostics bundle) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final String report = _composeReport(bundle);

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        Text(
          'Linthra can generate a safe diagnostic report to help fix bugs.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: AppSpacing.sm),
        _PrivacyNote(muted: muted),
        const SizedBox(height: AppSpacing.md),
        _field(
          controller: _summary,
          label: 'Summary',
          hint: 'A one-line summary of the problem',
        ),
        const SizedBox(height: AppSpacing.md),
        _field(
          controller: _whatHappened,
          label: 'What happened',
          hint: 'What did you do, and what went wrong?',
          maxLines: 3,
        ),
        const SizedBox(height: AppSpacing.md),
        _field(
          controller: _steps,
          label: 'Steps to reproduce',
          hint: '1. …\n2. …\n3. …',
          maxLines: 4,
        ),
        const SizedBox(height: AppSpacing.md),
        _field(
          controller: _expected,
          label: 'Expected behavior',
          hint: 'What did you expect to happen?',
          maxLines: 2,
        ),
        const SizedBox(height: AppSpacing.md),
        _IncludeOptions(
          includePlayback: _includePlayback,
          includeCache: _includeCache,
          includeRecentEvents: _includeRecentEvents,
          hasRecentEvents: bundle.hasRecentEvents,
          onPlaybackChanged: (bool v) => setState(() => _includePlayback = v),
          onCacheChanged: (bool v) => setState(() => _includeCache = v),
          onRecentEventsChanged: (bool v) =>
              setState(() => _includeRecentEvents = v),
        ),
        const SizedBox(height: AppSpacing.md),
        _PreviewCard(report: report),
        const SizedBox(height: AppSpacing.md),
        _actions(bundle),
      ],
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required String hint,
    int maxLines = 1,
  }) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      textInputAction: maxLines > 1 ? TextInputAction.newline : null,
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
        alignLabelWithHint: maxLines > 1,
      ),
    );
  }

  Widget _actions(BugReportDiagnostics bundle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: _busy ? null : () => _openIssue(bundle),
          icon: const Icon(Icons.open_in_new),
          label: const Text('Open GitHub issue'),
        ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: _busy ? null : () => _copy(bundle),
                icon: const Icon(Icons.copy_outlined),
                label: const Text('Copy bug report'),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _busy ? null : () => _share(bundle),
                icon: const Icon(Icons.ios_share),
                label: const Text('Share bug report'),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        OutlinedButton.icon(
          onPressed: _busy ? null : () => _save(bundle),
          icon: const Icon(Icons.save_alt_outlined),
          label: const Text('Save report file'),
        ),
      ],
    );
  }
}

/// The on-device privacy reassurance shown above the form.
class _PrivacyNote extends StatelessWidget {
  const _PrivacyNote({required this.muted});

  final Color muted;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.lock_outline, size: 18, color: muted),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            'The report is generated on your device. Review it before sharing — '
            'nothing is sent anywhere automatically.',
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ),
      ],
    );
  }
}

/// The three "Include in the report" toggles.
class _IncludeOptions extends StatelessWidget {
  const _IncludeOptions({
    required this.includePlayback,
    required this.includeCache,
    required this.includeRecentEvents,
    required this.hasRecentEvents,
    required this.onPlaybackChanged,
    required this.onCacheChanged,
    required this.onRecentEventsChanged,
  });

  final bool includePlayback;
  final bool includeCache;
  final bool includeRecentEvents;
  final bool hasRecentEvents;
  final ValueChanged<bool> onPlaybackChanged;
  final ValueChanged<bool> onCacheChanged;
  final ValueChanged<bool> onRecentEventsChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Column(
          children: [
            SwitchListTile(
              value: includePlayback,
              onChanged: onPlaybackChanged,
              title: const Text('Include playback state'),
              subtitle: const Text('Output, status, and a hashed track tag.'),
            ),
            SwitchListTile(
              value: includeCache,
              onChanged: onCacheChanged,
              title: const Text('Include cache state'),
              subtitle:
                  const Text('How much offline cache is used of the limit.'),
            ),
            SwitchListTile(
              value: includeRecentEvents,
              onChanged: onRecentEventsChanged,
              title: const Text('Include recent app events'),
              subtitle: Text(
                hasRecentEvents
                    ? 'The last few secret-free app events (lifecycle, '
                        'playback).'
                    : 'No recent events recorded yet.',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A read-only preview of exactly what will be copied, saved, or prefilled.
class _PreviewCard extends StatelessWidget {
  const _PreviewCard({required this.report});

  final String report;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.description_outlined,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: AppSpacing.sm),
                Text('Preview', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'This is exactly what will be copied, saved, or prefilled.',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: AppSpacing.sm),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 320),
              padding: const EdgeInsets.all(AppSpacing.sm),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(AppRadii.sm),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  report,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    height: 1.4,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
