import 'package:flutter/material.dart';

import '../../../app/dimens.dart';
import '../bug_report/report_bug_settings_section.dart';
import '../diagnostics/diagnostics_settings_section.dart';
import '../diagnostics/linux_playback_diagnostics_section.dart';
import 'settings_detail_scaffold.dart';

/// The "Diagnostics & support" page of the Settings hub.
///
/// Groups the ways to get help: building a safe, secret-free bug report, and
/// copying or saving a diagnostics snapshot to paste into one. Nothing is
/// generated or sent on its own.
///
/// On Linux a third card sits underneath: the native playback report (#406),
/// which answers the questions the general snapshot cannot — which backend is
/// playing, whether libmpv answered, which output subsystem is in use. It
/// renders nothing off Linux, so the Android page is unchanged.
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
        SizedBox(height: AppSpacing.md),
        LinuxPlaybackDiagnosticsSection(),
      ],
    );
  }
}
