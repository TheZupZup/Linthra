import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dimens.dart';
import '../../../app/text_file_saver_provider.dart';
import '../../../core/diagnostics/app_diagnostics.dart';
import '../../../core/services/text_file_saver.dart';
import 'diagnostics_collector.dart';

/// The Diagnostics card on the Settings screen.
///
/// Lets a user copy (or save) a secret-free snapshot of the app's state to paste
/// into a bug report. The text is assembled by [DiagnosticsCollector] and, by
/// construction, carries no password, token, `Authorization` header, or full
/// authenticated URL — only host-only addresses, counts, and feature flags.
class DiagnosticsSettingsSection extends ConsumerStatefulWidget {
  const DiagnosticsSettingsSection({super.key});

  @override
  ConsumerState<DiagnosticsSettingsSection> createState() =>
      _DiagnosticsSettingsSectionState();
}

class _DiagnosticsSettingsSectionState
    extends ConsumerState<DiagnosticsSettingsSection> {
  bool _busy = false;

  Future<void> _copy() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final String report = await ref.read(diagnosticsReportBuilderProvider)();
      await Clipboard.setData(ClipboardData(text: report));
      _showSnack('Diagnostics copied (no passwords, tokens, or URLs).');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final String report = await ref.read(diagnosticsReportBuilderProvider)();
      final TextFileSaveResult result =
          await ref.read(textFileSaverProvider).save(
                suggestedName: 'linthra-diagnostics.txt',
                contents: report,
                dialogTitle: 'Save diagnostics',
              );
      switch (result) {
        case TextFileSaved(:final String path):
          // Show only the redacted basename, never the directories to it.
          _showSnack('Saved to ${AppDiagnostics.redactPath(path)}.');
        case TextFileSaveCancelled():
          // The save dialog was closed: nothing happened, nothing to say.
          break;
        case TextFileSaveFailed():
          _showSnack("Couldn't save diagnostics. Try Copy instead.");
      }
    } catch (_) {
      _showSnack("Couldn't save diagnostics. Try Copy instead.");
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
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.bug_report_outlined,
                    color: theme.colorScheme.primary),
                const SizedBox(width: AppSpacing.sm),
                Text('Diagnostics', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Copy a safe snapshot of the app to paste into a bug report. It '
              'never includes your password, tokens, or full server URLs — just '
              'versions, connection state, server host, counts, and feature '
              'status.',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _busy ? null : _copy,
                    icon: const Icon(Icons.copy_outlined),
                    label: const Text('Copy diagnostics'),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _save,
                    icon: const Icon(Icons.save_alt_outlined),
                    label: const Text('Save diagnostics'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
