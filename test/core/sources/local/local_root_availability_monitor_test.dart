// Music on a removable drive (#415), at the level where the rules live: what a
// configured local folder's availability does as the drive is unplugged and
// plugged back in.
//
// The one promise every test here is about: **temporary unavailability is not
// deletion.** A folder that stops answering keeps its place in the selection and
// keeps its state; only the user removing it removes anything. And a folder is
// only ever asked about at the path the user configured: there is no guessing
// where a drive went.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/local/local_root_availability.dart';
import 'package:linthra/core/sources/local/local_root_availability_monitor.dart';
import 'package:linthra/core/sources/local/local_root_fault.dart';
import 'package:linthra/core/sources/local/local_root_probe.dart';

/// A [LocalRootProbe] backed by a set of paths, so a test can unplug a drive by
/// removing a string.
class _FakeRootProbe implements LocalRootProbe {
  _FakeRootProbe({
    Set<String>? present,
    Set<String>? unanswerable,
    this.fault = LocalRootFault.missing,
  })  : present = present ?? <String>{},
        unanswerable = unanswerable ?? <String>{};

  /// The paths that are reachable right now.
  Set<String> present;

  /// What an absent path reports. A drive that was unplugged and one whose
  /// permissions changed are both "not reachable" to this state machine, and
  /// the kind simply rides along to the UI.
  LocalRootFault fault;

  /// The paths this platform cannot speak for at all (a SAF grant off Android,
  /// a raw path where paths are not read). Answered with null, never a guess.
  Set<String> unanswerable;

  /// Every path this was asked about, in order. What proves the monitor never
  /// looks anywhere but at the configured folder.
  final List<String> asked = <String>[];

  @override
  Future<LocalRootReading?> inspect(String root) async {
    asked.add(root);
    if (unanswerable.contains(root)) return null;
    return present.contains(root)
        ? const LocalRootReading.available()
        : LocalRootReading.blocked(fault);
  }
}

/// A probe that blocks on the first path it is asked about until the test lets
/// it answer, so a second request can arrive mid-round.
class _BlockingRootProbe implements LocalRootProbe {
  _BlockingRootProbe({Set<String>? present}) : present = present ?? <String>{};

  Set<String> present;
  final Completer<void> _firstAnswer = Completer<void>();
  final List<String> asked = <String>[];
  bool _blocked = false;

  /// Completes once the monitor is actually inside the first probe.
  final Completer<void> reached = Completer<void>();

  void release() => _firstAnswer.complete();

  @override
  Future<LocalRootReading?> inspect(String root) async {
    asked.add(root);
    if (!_blocked) {
      _blocked = true;
      if (!reached.isCompleted) reached.complete();
      await _firstAnswer.future;
    }
    return present.contains(root)
        ? const LocalRootReading.available()
        : const LocalRootReading.blocked(LocalRootFault.missing);
  }
}

const String _usb = '/media/usb/Music';
const String _internal = '/home/me/Music';

void main() {
  group('LocalRootAvailabilityMonitor', () {
    test('a folder is found by the spelling the user stored it as', () async {
      // States are keyed canonically; a stored selection is whatever was
      // written. A folder saved with a trailing separator asking about itself
      // must not come back "nothing is wrong with it" while its drive is out,
      // because that is a broken folder rendered as a healthy one with no way
      // to fix it.
      final probe = _FakeRootProbe();
      final monitor = LocalRootAvailabilityMonitor(probe: probe);
      addTearDown(monitor.dispose);
      await monitor.syncRoots(<String>['$_usb/']);

      final LocalLibraryAvailability availability = monitor.availability;

      expect(availability.isUnavailable('$_usb/'), isTrue);
      expect(availability.faultFor('$_usb/'), LocalRootFault.missing);
      expect(availability.isUnavailable(_usb), isTrue);
      expect(availability.isAvailable('$_usb/'), isFalse);
    });

    test('a recheck that lands mid-round still waits for its own answer',
        () async {
      // Retry reads the answer the moment this future completes. If a poll
      // round happened to be in flight, the request is handed to that round,
      // and returning early would have Retry read the state from *before* it
      // asked: a user who just plugged their drive back in would be told it is
      // still gone.
      final probe = _BlockingRootProbe();
      final monitor = LocalRootAvailabilityMonitor(probe: probe);
      addTearDown(monitor.dispose);

      final Future<void> sync = monitor.syncRoots(<String>[_usb]);
      await probe.reached.future;

      // The drive comes back while that first probe is still blocked.
      probe.present.add(_usb);
      bool settled = false;
      final Future<void> retry =
          monitor.recheck(_usb).then((_) => settled = true);
      expect(settled, isFalse);

      probe.release();
      await sync;
      await retry;

      expect(settled, isTrue);
      // Asked twice: the blocked round, then the requeued recheck.
      expect(probe.asked, <String>[_usb, _usb]);
      expect(monitor.availability.isAvailable(_usb), isTrue);
      expect(monitor.availability.faultFor(_usb), isNull);
    });

    test('a configured folder that is there reads as available', () async {
      final probe = _FakeRootProbe(present: <String>{_usb});
      final monitor = LocalRootAvailabilityMonitor(probe: probe);
      addTearDown(monitor.dispose);

      await monitor.syncRoots(<String>[_usb]);

      expect(monitor.availability.isAvailable(_usb), isTrue);
      expect(monitor.availability.hasUnavailableRoots, isFalse);
      expect(monitor.availability.stateFor(_usb)?.lastCheckedAt, isNotNull);
      expect(monitor.availability.stateFor(_usb)?.lastAvailableAt, isNotNull);
    });

    test('nothing is known before a probe answers', () async {
      // "We have not looked" must never present as "it is gone": that is the
      // state a library would be blanked, or a catalog erased, on.
      final probe = _FakeRootProbe();
      final monitor = LocalRootAvailabilityMonitor(probe: probe);
      addTearDown(monitor.dispose);

      final Future<void> pending = monitor.syncRoots(<String>[_usb]);

      expect(monitor.availability.stateFor(_usb)?.isChecking, isTrue);
      expect(monitor.availability.isUnavailable(_usb), isFalse);
      await pending;
    });

    test('a folder that goes away becomes unavailable and keeps its place',
        () async {
      final probe = _FakeRootProbe(present: <String>{_usb});
      final monitor = LocalRootAvailabilityMonitor(probe: probe);
      addTearDown(monitor.dispose);
      await monitor.syncRoots(<String>[_usb]);

      probe.present = <String>{};
      await monitor.recheck(_usb);

      final LocalRootState? state = monitor.availability.stateFor(_usb);
      expect(state?.isUnavailable, isTrue);
      expect(
        state?.root,
        _usb,
        reason: 'the folder is still the one the user configured',
      );
      expect(
        state?.lastAvailableAt,
        isNotNull,
        reason: 'a folder that was there a moment ago is not a folder that '
            'never was',
      );
      expect(monitor.trackedRoots, <String>[_usb]);
    });

    test('one folder going away says nothing about the others', () async {
      final probe = _FakeRootProbe(present: <String>{_usb, _internal});
      final monitor = LocalRootAvailabilityMonitor(probe: probe);
      addTearDown(monitor.dispose);
      await monitor.syncRoots(<String>[_internal, _usb]);

      probe.present = <String>{_internal};
      await monitor.recheck(_usb);

      expect(monitor.availability.isAvailable(_internal), isTrue);
      expect(monitor.availability.unavailableRoots, <String>{_usb});
    });

    test('a folder that comes back at the same path announces itself once',
        () async {
      final probe = _FakeRootProbe();
      final List<List<String>> returned = <List<String>>[];
      final monitor = LocalRootAvailabilityMonitor(
        probe: probe,
        onRootsReturned: (List<String> roots) async => returned.add(roots),
      );
      addTearDown(monitor.dispose);

      await monitor.syncRoots(<String>[_usb]);
      expect(
        returned,
        isEmpty,
        reason: 'a folder that was never reachable has not reconnected',
      );

      probe.present = <String>{_usb};
      await monitor.refresh();
      expect(returned, <List<String>>[
        <String>[_usb]
      ]);

      // Still there on the next look: the folder is available, not returning.
      await monitor.refresh();
      expect(returned, hasLength(1));
      expect(monitor.availability.isAvailable(_usb), isTrue);
    });

    test('a drive that turns up at a different path stays unavailable',
        () async {
      // The limitation, made explicit. Linthra cannot prove that the folder now
      // mounted at another path is the same hardware, and adopting it would
      // point a configured library at somebody else's files. So the configured
      // path stays configured, stays unavailable, and the user chooses.
      final probe = _FakeRootProbe(present: <String>{_usb});
      final List<List<String>> returned = <List<String>>[];
      final monitor = LocalRootAvailabilityMonitor(
        probe: probe,
        onRootsReturned: (List<String> roots) async => returned.add(roots),
      );
      addTearDown(monitor.dispose);
      await monitor.syncRoots(<String>[_usb]);

      // The same disk, remounted somewhere else by the automounter.
      probe.present = <String>{'/run/media/me/MUSIC/Music'};
      await monitor.refresh();

      expect(monitor.availability.isUnavailable(_usb), isTrue);
      expect(returned, isEmpty);
      expect(
        probe.asked.toSet(),
        <String>{_usb},
        reason: 'only the configured path is ever asked about',
      );
      expect(monitor.trackedRoots, <String>[_usb]);
    });

    test('a folder absent at startup is not mistaken for a reconnect',
        () async {
      // Starting with the drive unplugged: the folder is away, nothing is
      // refreshed, and plugging it in later is the reconnect.
      final probe = _FakeRootProbe();
      final List<List<String>> returned = <List<String>>[];
      final monitor = LocalRootAvailabilityMonitor(
        probe: probe,
        onRootsReturned: (List<String> roots) async => returned.add(roots),
      );
      addTearDown(monitor.dispose);

      await monitor.syncRoots(<String>[_usb]);

      expect(monitor.availability.isUnavailable(_usb), isTrue);
      expect(monitor.availability.stateFor(_usb)?.lastAvailableAt, isNull);
      expect(returned, isEmpty);
    });

    test('adding a folder does not forget that another one is away', () async {
      // Rebuilding availability when the selection changes would make the next
      // probe of the absent folder look like a reconnect and rescan for nothing.
      final probe = _FakeRootProbe(present: <String>{_internal});
      final List<List<String>> returned = <List<String>>[];
      final monitor = LocalRootAvailabilityMonitor(
        probe: probe,
        onRootsReturned: (List<String> roots) async => returned.add(roots),
      );
      addTearDown(monitor.dispose);
      await monitor.syncRoots(<String>[_usb]);
      expect(monitor.availability.isUnavailable(_usb), isTrue);
      probe.asked.clear();

      await monitor.syncRoots(<String>[_usb, _internal]);

      expect(monitor.availability.isUnavailable(_usb), isTrue);
      expect(monitor.availability.isAvailable(_internal), isTrue);
      expect(
        probe.asked,
        <String>[_internal],
        reason: 'only the folder nothing is known about is probed',
      );
      expect(returned, isEmpty);
    });

    test('removing a folder drops only that folder', () async {
      // Explicit removal is the other half of the contract: it is the one thing
      // that really does forget a folder, and it forgets nothing else.
      final probe = _FakeRootProbe(present: <String>{_internal});
      final monitor = LocalRootAvailabilityMonitor(probe: probe);
      addTearDown(monitor.dispose);
      await monitor.syncRoots(<String>[_usb, _internal]);
      expect(monitor.trackedRoots, <String>[_usb, _internal]);

      await monitor.syncRoots(<String>[_internal]);

      expect(monitor.trackedRoots, <String>[_internal]);
      expect(monitor.availability.stateFor(_usb), isNull);
      expect(monitor.availability.isAvailable(_internal), isTrue);
    });

    test('a folder nothing here can answer for is left untracked', () async {
      // Not "gone": unanswerable. Calling a SAF grant Linthra cannot see lost
      // would be a guess, and this never guesses.
      final probe = _FakeRootProbe(unanswerable: <String>{_usb});
      final monitor = LocalRootAvailabilityMonitor(probe: probe);
      addTearDown(monitor.dispose);

      await monitor.syncRoots(<String>[_usb]);

      expect(monitor.availability.stateFor(_usb), isNull);
      expect(monitor.availability.hasUnavailableRoots, isFalse);
    });

    group('what a scan reports', () {
      test('a folder a scan could not read settles as unavailable', () async {
        final probe = _FakeRootProbe(present: <String>{_usb, _internal});
        final List<List<String>> returned = <List<String>>[];
        final monitor = LocalRootAvailabilityMonitor(
          probe: probe,
          onRootsReturned: (List<String> roots) async => returned.add(roots),
        );
        addTearDown(monitor.dispose);
        await monitor.syncRoots(<String>[_usb, _internal]);

        monitor.noteScanOutcome(
          readRoots: <String>[_internal],
          unreadableRoots: <String, LocalRootFault>{
            _usb: LocalRootFault.missing,
          },
        );

        expect(monitor.availability.isUnavailable(_usb), isTrue);
        expect(monitor.availability.isAvailable(_internal), isTrue);
        expect(returned, isEmpty);
      });

      test('a folder a scan did read never asks for a second scan', () async {
        // The scan that reported this is the refresh. Announcing a reconnect
        // here would scan the same folder twice for one reconnect.
        final probe = _FakeRootProbe();
        final List<List<String>> returned = <List<String>>[];
        final monitor = LocalRootAvailabilityMonitor(
          probe: probe,
          onRootsReturned: (List<String> roots) async => returned.add(roots),
        );
        addTearDown(monitor.dispose);
        await monitor.syncRoots(<String>[_usb]);
        expect(monitor.availability.isUnavailable(_usb), isTrue);

        monitor.noteScanOutcome(
          readRoots: <String>[_usb],
          unreadableRoots: const <String, LocalRootFault>{},
        );

        expect(monitor.availability.isAvailable(_usb), isTrue);
        expect(returned, isEmpty);
      });

      test('a folder that is no longer selected cannot be resurrected',
          () async {
        final probe = _FakeRootProbe(present: <String>{_internal});
        final monitor = LocalRootAvailabilityMonitor(probe: probe);
        addTearDown(monitor.dispose);
        await monitor.syncRoots(<String>[_internal]);

        monitor.noteScanOutcome(
          readRoots: <String>[_usb],
          unreadableRoots: const <String, LocalRootFault>{},
        );

        expect(monitor.availability.stateFor(_usb), isNull);
      });
    });

    group('why a folder is away', () {
      test('rides along with the state, per folder', () async {
        // Availability answers "is it reachable?"; this is the follow-up the
        // user actually needs, and it is kept per folder because two drives can
        // be away for two different reasons at once (#414).
        final probe = _FakeRootProbe(
          present: <String>{_internal},
          fault: LocalRootFault.permissionDenied,
        );
        final monitor = LocalRootAvailabilityMonitor(probe: probe);
        addTearDown(monitor.dispose);

        await monitor.syncRoots(<String>[_usb, _internal]);

        expect(
          monitor.availability.faultFor(_usb),
          LocalRootFault.permissionDenied,
        );
        expect(monitor.availability.faultFor(_internal), isNull);
        expect(monitor.availability.faults, <String, LocalRootFault>{
          _usb: LocalRootFault.permissionDenied,
        });
      });

      test('a scan hands over what it learned rather than a bare "no"',
          () async {
        // The scan walked the folder, so it knows more than a probe can, and
        // it knows *which* problem it hit, which is the thing the recovery UI
        // branches on.
        final probe = _FakeRootProbe(present: <String>{_usb, _internal});
        final monitor = LocalRootAvailabilityMonitor(probe: probe);
        addTearDown(monitor.dispose);
        await monitor.syncRoots(<String>[_usb, _internal]);

        monitor.noteScanOutcome(
          readRoots: <String>[_internal],
          unreadableRoots: <String, LocalRootFault>{
            _usb: LocalRootFault.unavailable,
          },
        );

        expect(
          monitor.availability.faultFor(_usb),
          LocalRootFault.unavailable,
        );
      });

      test('a folder that comes back stops having one', () async {
        final probe = _FakeRootProbe(fault: LocalRootFault.missing);
        final monitor = LocalRootAvailabilityMonitor(probe: probe);
        addTearDown(monitor.dispose);
        await monitor.syncRoots(<String>[_usb]);
        expect(monitor.availability.faultFor(_usb), LocalRootFault.missing);

        probe.present = <String>{_usb};
        await monitor.refresh();

        expect(monitor.availability.faultFor(_usb), isNull);
        expect(monitor.availability.faults, isEmpty);
      });

      test('a folder nothing has answered for yet has no fault to show',
          () async {
        // "We have not looked" must never be presented as a diagnosis.
        final probe = _FakeRootProbe(present: <String>{_usb});
        final monitor = LocalRootAvailabilityMonitor(probe: probe);
        addTearDown(monitor.dispose);

        expect(
          const LocalRootState.checking(_usb).fault,
          isNull,
        );
        expect(monitor.availability.faults, isEmpty);
      });
    });

    group('the return-trip poll', () {
      test('is armed only while some folder is away', () async {
        final probe = _FakeRootProbe(present: <String>{_usb});
        final monitor = LocalRootAvailabilityMonitor(
          probe: probe,
          pollInterval: const Duration(milliseconds: 10),
        );
        addTearDown(monitor.dispose);

        await monitor.syncRoots(<String>[_usb]);
        expect(
          monitor.isPolling,
          isFalse,
          reason: 'a library that is all there carries no timer, and never '
              'wakes a drive on a schedule',
        );

        probe.present = <String>{};
        await monitor.recheck(_usb);
        expect(monitor.isPolling, isTrue);

        probe.present = <String>{_usb};
        await monitor.refresh();
        expect(monitor.isPolling, isFalse);
      });

      test('notices a drive plugged back in with nothing else happening',
          () async {
        final probe = _FakeRootProbe();
        final List<List<String>> returned = <List<String>>[];
        final monitor = LocalRootAvailabilityMonitor(
          probe: probe,
          pollInterval: const Duration(milliseconds: 10),
          onRootsReturned: (List<String> roots) async => returned.add(roots),
        );
        addTearDown(monitor.dispose);
        await monitor.syncRoots(<String>[_usb]);
        expect(monitor.isPolling, isTrue);

        probe.present = <String>{_usb};
        await Future<void>.delayed(const Duration(milliseconds: 60));

        expect(monitor.availability.isAvailable(_usb), isTrue);
        expect(returned, <List<String>>[
          <String>[_usb]
        ]);
      });

      test('asks only about the folders that are away', () async {
        final probe = _FakeRootProbe(present: <String>{_internal});
        final monitor = LocalRootAvailabilityMonitor(
          probe: probe,
          pollInterval: const Duration(milliseconds: 10),
        );
        addTearDown(monitor.dispose);
        await monitor.syncRoots(<String>[_usb, _internal]);
        probe.asked.clear();

        await Future<void>.delayed(const Duration(milliseconds: 40));

        expect(probe.asked, isNotEmpty);
        expect(probe.asked.toSet(), <String>{_usb});
      });

      test('stands down while the app is not on screen', () async {
        final probe = _FakeRootProbe();
        final monitor = LocalRootAvailabilityMonitor(
          probe: probe,
          pollInterval: const Duration(milliseconds: 10),
        );
        addTearDown(monitor.dispose);
        await monitor.syncRoots(<String>[_usb]);
        expect(monitor.isPolling, isTrue);

        monitor.setPollingEnabled(false);
        expect(monitor.isPolling, isFalse);
        probe.asked.clear();
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(probe.asked, isEmpty);

        monitor.setPollingEnabled(true);
        expect(monitor.isPolling, isTrue);
      });
    });

    test('every change is published, and nothing is after dispose', () async {
      final probe = _FakeRootProbe(present: <String>{_usb});
      final List<LocalLibraryAvailability> published =
          <LocalLibraryAvailability>[];
      final monitor = LocalRootAvailabilityMonitor(
        probe: probe,
        pollInterval: const Duration(milliseconds: 10),
        onChanged: published.add,
      );

      await monitor.syncRoots(<String>[_usb]);
      expect(published, isNotEmpty);
      expect(published.last.isAvailable(_usb), isTrue);

      await monitor.dispose();
      published.clear();
      probe.present = <String>{};
      await monitor.recheck(_usb);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(published, isEmpty);
      expect(monitor.isPolling, isFalse);
    });
  });
}
