import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/shared/widgets/sync_status_view.dart';

void main() {
  group('syncTimeAgo', () {
    final DateTime now = DateTime(2026, 6, 15, 12);

    test('reads "just now" under three-quarters of a minute', () {
      expect(syncTimeAgo(now, now: now), 'just now');
      expect(
        syncTimeAgo(now.subtract(const Duration(seconds: 44)), now: now),
        'just now',
      );
    });

    test('rounds the first minute up to "1 minute ago"', () {
      expect(
        syncTimeAgo(now.subtract(const Duration(seconds: 45)), now: now),
        '1 minute ago',
      );
      expect(
        syncTimeAgo(now.subtract(const Duration(seconds: 90)), now: now),
        '1 minute ago',
      );
    });

    test('pluralises minutes and hours', () {
      expect(
        syncTimeAgo(now.subtract(const Duration(minutes: 2)), now: now),
        '2 minutes ago',
      );
      expect(
        syncTimeAgo(now.subtract(const Duration(minutes: 59)), now: now),
        '59 minutes ago',
      );
      expect(
        syncTimeAgo(now.subtract(const Duration(hours: 1)), now: now),
        '1 hour ago',
      );
      expect(
        syncTimeAgo(now.subtract(const Duration(hours: 5)), now: now),
        '5 hours ago',
      );
    });

    test('says "yesterday" for a day, then counts days/weeks/months/years', () {
      expect(
        syncTimeAgo(now.subtract(const Duration(hours: 24)), now: now),
        'yesterday',
      );
      expect(
        syncTimeAgo(now.subtract(const Duration(days: 3)), now: now),
        '3 days ago',
      );
      expect(
        syncTimeAgo(now.subtract(const Duration(days: 14)), now: now),
        '2 weeks ago',
      );
      expect(
        syncTimeAgo(now.subtract(const Duration(days: 60)), now: now),
        '2 months ago',
      );
      expect(
        syncTimeAgo(now.subtract(const Duration(days: 400)), now: now),
        '1 year ago',
      );
    });

    test('clamps a future timestamp to "just now"', () {
      expect(
        syncTimeAgo(now.add(const Duration(minutes: 5)), now: now),
        'just now',
      );
    });
  });

  group('SyncStatusView', () {
    final DateTime now = DateTime(2026, 6, 15, 12);

    Future<void> pump(
      WidgetTester tester, {
      required SyncStatusData status,
      VoidCallback? onSync,
      String syncLabel = 'Sync now',
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SyncStatusView(
              status: status,
              onSync: onSync,
              syncLabel: syncLabel,
              now: now,
            ),
          ),
        ),
      );
    }

    FilledButton? syncButton(WidgetTester tester) {
      // FilledButton.tonalIcon builds a private FilledButton subclass, so match
      // on the supertype rather than an exact runtimeType.
      final Finder finder = find.byWidgetPredicate((w) => w is FilledButton);
      if (finder.evaluate().isEmpty) return null;
      return tester.widget<FilledButton>(finder);
    }

    testWidgets('shows "Never synced" with an enabled, labelled button',
        (tester) async {
      await pump(
        tester,
        status: const SyncStatusData.neverSynced(),
        onSync: () {},
        syncLabel: 'Sync library',
      );

      expect(find.text('Never synced'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Sync library'), findsNothing);
      expect(find.text('Sync library'), findsOneWidget);
      expect(syncButton(tester)?.onPressed, isNotNull);
    });

    testWidgets('shows the last successful sync time when synced',
        (tester) async {
      await pump(
        tester,
        status: SyncStatusData.synced(now.subtract(const Duration(minutes: 2))),
        onSync: () {},
      );

      expect(find.text('Synced 2 minutes ago'), findsOneWidget);
    });

    testWidgets('disables the button and reads "Syncing…" while a sync runs',
        (tester) async {
      await pump(
        tester,
        status: const SyncStatusData.syncing(),
        onSync: () {},
      );

      // "Syncing…" appears both as the status headline and the button label.
      expect(find.text('Syncing…'), findsNWidgets(2));
      expect(syncButton(tester)?.onPressed, isNull);
    });

    testWidgets('shows the error and the previous sync time on failure',
        (tester) async {
      await pump(
        tester,
        status: SyncStatusData.failed(
          error: "Couldn't reach your server.",
          lastSyncedAt: now.subtract(const Duration(hours: 3)),
        ),
        onSync: () {},
      );

      expect(find.text('Last sync failed'), findsOneWidget);
      expect(find.text("Couldn't reach your server."), findsOneWidget);
      expect(find.text('Last synced 3 hours ago'), findsOneWidget);
      // The button stays enabled so the user can retry.
      expect(syncButton(tester)?.onPressed, isNotNull);
    });

    testWidgets('shows "Offline" with the last good sync time', (tester) async {
      await pump(
        tester,
        status: SyncStatusData.offline(
          lastSyncedAt: now.subtract(const Duration(days: 1)),
        ),
        onSync: () {},
      );

      expect(find.text('Offline'), findsOneWidget);
      expect(find.text('Last synced yesterday'), findsOneWidget);
    });

    testWidgets('omits the button entirely when onSync is null',
        (tester) async {
      await pump(tester, status: const SyncStatusData.neverSynced());

      expect(syncButton(tester), isNull);
      expect(find.text('Sync now'), findsNothing);
    });

    testWidgets('invokes onSync when the button is tapped', (tester) async {
      int taps = 0;
      await pump(
        tester,
        status: const SyncStatusData.neverSynced(),
        onSync: () => taps++,
        syncLabel: 'Sync library',
      );

      await tester.tap(find.text('Sync library'));
      await tester.pump();

      expect(taps, 1);
    });
  });
}
