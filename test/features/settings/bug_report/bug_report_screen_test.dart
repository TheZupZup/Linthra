import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/diagnostics/app_diagnostics.dart';
import 'package:linthra/core/models/cache_size.dart';
import 'package:linthra/core/services/external_link_launcher.dart';
import 'package:linthra/features/settings/bug_report/bug_report_providers.dart';
import 'package:linthra/features/settings/bug_report/bug_report_screen.dart';

/// A fixed, secret-free snapshot the screen renders from. The Jellyfin host is
/// deliberately a full authenticated URL to prove `hostOnly` still reduces it.
const BugReportDiagnostics _bundle = BugReportDiagnostics(
  data: AppDiagnosticsData(
    appVersion: '0.1.0-test',
    jellyfinState: 'connected',
    jellyfinHost: 'https://user:pass@music.example.com/jellyfin?api_key=secret',
    cacheUsedBytes: 2 * CacheSize.bytesPerGb,
    cacheLimitBytes: 4 * CacheSize.bytesPerGb,
    playbackOutput: 'local',
    playbackStatus: 'playing',
    currentTrackIdHash: 'id#1a2b3c',
  ),
  recentEventLines: <String>[
    'lifecycle: resumed',
    'output: local',
    'error: load',
  ],
);

class _FakeLinkLauncher implements ExternalLinkLauncher {
  _FakeLinkLauncher({this.result = true});

  final bool result;
  Uri? opened;

  @override
  Future<bool> open(Uri url) async {
    opened = url;
    return result;
  }
}

Future<_FakeLinkLauncher> _pumpScreen(
  WidgetTester tester, {
  bool launchResult = true,
}) async {
  // A tall surface so the whole scrolling form is laid out and every action is
  // hittable without scrolling.
  tester.view.physicalSize = const Size(1080, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final _FakeLinkLauncher launcher = _FakeLinkLauncher(result: launchResult);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        bugReportDiagnosticsProvider.overrideWith((ref) async => _bundle),
        externalLinkLauncherProvider.overrideWithValue(launcher),
      ],
      child: const MaterialApp(home: BugReportScreen()),
    ),
  );
  // Resolve the (overridden) diagnostics future so the form replaces the
  // loading spinner.
  await tester.pump();
  await tester.pump();
  return launcher;
}

void _mockClipboard(WidgetTester tester, List<MethodCall> sink) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (MethodCall call) async {
      if (call.method == 'Clipboard.setData') sink.add(call);
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null),
  );
}

void main() {
  group('BugReportScreen', () {
    testWidgets('shows the explanation, privacy note, actions, and preview',
        (tester) async {
      await _pumpScreen(tester);

      expect(
        find.textContaining('safe diagnostic report to help fix bugs'),
        findsOneWidget,
      );
      expect(
        find.textContaining('generated on your device'),
        findsOneWidget,
      );
      expect(find.text('Open GitHub issue'), findsOneWidget);
      expect(find.text('Copy bug report'), findsOneWidget);
      expect(find.text('Share bug report'), findsOneWidget);
      expect(find.text('Save report file'), findsOneWidget);

      // The live preview shows the assembled, host-only report.
      expect(find.textContaining('# Linthra bug report'), findsOneWidget);
      expect(find.textContaining('App version: 0.1.0-test'), findsOneWidget);
      expect(find.textContaining('Jellyfin host: music.example.com'),
          findsOneWidget);
    });

    testWidgets('Copy puts the secret-free markdown report on the clipboard',
        (tester) async {
      final List<MethodCall> calls = <MethodCall>[];
      _mockClipboard(tester, calls);

      await _pumpScreen(tester);
      await tester.tap(find.text('Copy bug report'));
      await tester.pump();
      await tester.pump();

      expect(calls, hasLength(1));
      final Map<dynamic, dynamic> args =
          calls.single.arguments as Map<dynamic, dynamic>;
      final String copied = args['text'] as String;
      expect(copied, contains('# Linthra bug report'));
      expect(copied, contains('## Diagnostics'));
      expect(copied, contains('Jellyfin host: music.example.com'));
      // Nothing sensitive from the full authenticated URL survives.
      expect(copied, isNot(contains('api_key')));
      expect(copied, isNot(contains('secret')));
      expect(copied, isNot(contains('pass@')));

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('Open GitHub issue launches a prefilled issues/new URL',
        (tester) async {
      final _FakeLinkLauncher launcher = await _pumpScreen(tester);

      await tester.tap(find.text('Open GitHub issue'));
      await tester.pump();
      await tester.pump();

      final Uri? opened = launcher.opened;
      expect(opened, isNotNull);
      expect(opened!.host, 'github.com');
      expect(opened.path, '/thezupzup/linthra/issues/new');
      expect(opened.queryParameters['labels'], 'bug');
      final String body = opened.queryParameters['body']!;
      expect(body, contains('# Linthra bug report'));
      expect(body, isNot(contains('api_key')));

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('falls back to copying the link when the browser won\'t open',
        (tester) async {
      final List<MethodCall> calls = <MethodCall>[];
      _mockClipboard(tester, calls);

      await _pumpScreen(tester, launchResult: false);
      await tester.tap(find.text('Open GitHub issue'));
      await tester.pump();
      await tester.pump();

      expect(calls, hasLength(1));
      final Map<dynamic, dynamic> args =
          calls.single.arguments as Map<dynamic, dynamic>;
      expect(args['text'] as String, contains('github.com'));

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('turning off "Include cache state" drops the cache line',
        (tester) async {
      await _pumpScreen(tester);
      expect(find.textContaining('Cache: 2 GB of 4 GB'), findsOneWidget);

      await tester.tap(find.text('Include cache state'));
      await tester.pump();

      expect(find.textContaining('Cache: 2 GB of 4 GB'), findsNothing);
    });

    testWidgets('recent events appear and can be excluded', (tester) async {
      await _pumpScreen(tester);
      expect(find.textContaining('## Recent app events'), findsOneWidget);
      expect(find.textContaining('lifecycle: resumed'), findsOneWidget);

      await tester.tap(find.text('Include recent app events'));
      await tester.pump();

      expect(find.textContaining('## Recent app events'), findsNothing);
    });
  });
}
