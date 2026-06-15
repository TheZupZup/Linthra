import 'package:flutter/material.dart';

import '../../../app/dimens.dart';
import '../bug_report/report_bug_settings_section.dart';
import '../diagnostics/diagnostics_settings_section.dart';
import 'settings_detail_scaffold.dart';

/// The "Diagnostics & support" page of the Settings hub.
///
/// Groups the two ways to get help: building a safe, secret-free bug report,
/// and copying or saving a diagnostics snapshot to paste into one. Both are the
/// existing sections, unchanged — nothing is generated or sent on its own.
class DiagnosticsSupportScreen extends StatelessWidget {
  const DiagnosticsSupportScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const SettingsDetailScaffold(
      title: 'Diagnostics & support',
      children: <Widget>[
        ReportBugSettingsSection(),
        SizedBox(height: AppSpacing.md),
        DiagnosticsSettingsSection(),
      ],
    );
  }
}
