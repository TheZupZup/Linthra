import 'dart:async';

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/optical_media.dart';
import 'package:linthra/core/services/optical/linux_optical_media_service.dart';
import 'package:linthra/core/services/optical/udisks_drive_reading.dart';
import 'package:linthra/core/services/optical/udisks_object_source.dart';

import 'udisks_fixtures.dart';

/// A [UDisksObjectSource] that answers like UDisks2 without being it.
///
/// The whole point of the seam: every case below — an empty machine, a disc
/// going in and coming out, a refusal, a wedged daemon, a drive that vanishes
/// mid-read — is a scripted answer here, so none of them needs a bus, a drive
/// or a disc, and CI never depends on `/dev/sr0` existing.
class _FakeUDisks implements UDisksObjectSource {
  _FakeUDisks({UDisksObjectTable? objects})
      : table = objects ?? <String, Map<String, Map<String, DBusValue>>>{};

  UDisksObjectTable table;

  /// Thrown instead of answering, when set. How a refusal or a broken bus is
  /// scripted.
  Object? failure;

  /// Never answers at all, the way a wedged daemon does.
  bool hangs = false;

  /// Holds a read open until it is completed, so a test can make something
  /// else happen while a read is genuinely in flight.
  Completer<void>? gate;

  /// Run just before each read answers. The hook the "it changed while we
  /// were looking" cases use.
  void Function()? onRead;

  int reads = 0;
  int closeCalls = 0;

  final StreamController<void> events = StreamController<void>.broadcast();

  @override
  Future<UDisksObjectTable> objects() async {
    reads++;
    // Captured before anything else runs: a read answers with the machine as
    // it was when it was taken, which is what makes "it changed while we were
    // looking" a real race here rather than a rehearsed one.
    final UDisksObjectTable answer = table;
    onRead?.call();
    if (hangs) return Completer<UDisksObjectTable>().future;
    final Completer<void>? gate = this.gate;
    if (gate != null) {
      this.gate = null;
      await gate.future;
    }
    final Object? failure = this.failure;
    if (failure != null) throw failure;
    return answer;
  }

  /// Announces a change, unless the source is already closed — which is what
  /// the host doing something right after Linthra shut down looks like.
  void emit() {
    if (!events.isClosed) events.add(null);
  }

  @override
  Stream<void> get changes => events.stream;

  @override
  Future<void> close() async {
    closeCalls++;
    await events.close();
  }
}

/// Lets the settle timer fire and the read that follows it complete.
Future<void> _settle() => pumpEventQueue();

void main() {
  group('LinuxOpticalMediaService', () {
    const Duration fastSettle = Duration.zero;

    LinuxOpticalMediaService serviceFor(
      _FakeUDisks udisks, {
      bool sandboxed = false,
      Duration? callDeadline,
    }) =>
        LinuxOpticalMediaService(
          source: udisks,
          sandboxed: sandboxed,
          settleDelay: fastSettle,
          callDeadline:
              callDeadline ?? LinuxOpticalMediaService.defaultCallDeadline,
        );

    test('a machine with no optical drive answers "supported, none"', () async {
      final _FakeUDisks udisks = _FakeUDisks();
      final LinuxOpticalMediaService service = serviceFor(udisks);
      addTearDown(service.dispose);

      final OpticalMediaSnapshot snapshot = await service.inspect();

      expect(service.isSupported, isTrue);
      expect(snapshot, const OpticalMediaSnapshot.noDrive());
      expect(snapshot.hasDrive, isFalse);
    });

    test('an empty drive is reported as a drive, not as no drive', () async {
      final _FakeUDisks udisks = _FakeUDisks(objects: opticalDriveObjects());
      final LinuxOpticalMediaService service = serviceFor(udisks);
      addTearDown(service.dispose);

      final OpticalMediaSnapshot snapshot = await service.inspect();

      expect(snapshot.hasDrive, isTrue);
      expect(snapshot.drives.single.disc, OpticalDiscState.empty);
    });

    test('an audio CD already in the drive is found by the first look',
        () async {
      final _FakeUDisks udisks =
          _FakeUDisks(objects: opticalDriveObjects(drive: audioCdDrive()));
      final LinuxOpticalMediaService service = serviceFor(udisks);
      addTearDown(service.dispose);

      expect((await service.inspect()).hasAudioCd, isTrue);
    });

    test('inserting a disc is published without anything polling', () async {
      final _FakeUDisks udisks = _FakeUDisks(objects: opticalDriveObjects());
      final LinuxOpticalMediaService service = serviceFor(udisks);
      addTearDown(service.dispose);

      final List<OpticalMediaSnapshot> seen = <OpticalMediaSnapshot>[];
      final StreamSubscription<OpticalMediaSnapshot> subscription =
          service.changes.listen(seen.add);
      addTearDown(subscription.cancel);

      await service.inspect();
      await _settle();
      expect(seen.single.drives.single.disc, OpticalDiscState.empty);

      // Nothing has looked again yet: no timer is armed, so no read happens
      // until the host says something.
      final int readsBefore = udisks.reads;
      await _settle();
      expect(udisks.reads, readsBefore);

      udisks.table = opticalDriveObjects(drive: audioCdDrive());
      udisks.emit();
      await _settle();

      expect(seen, hasLength(2));
      expect(seen.last.hasAudioCd, isTrue);
      expect(seen.last.drives.single.id, '/dev/sr0');
    });

    test('ejecting a disc is published and removes nothing else', () async {
      final _FakeUDisks udisks =
          _FakeUDisks(objects: opticalDriveObjects(drive: audioCdDrive()));
      final LinuxOpticalMediaService service = serviceFor(udisks);
      addTearDown(service.dispose);

      final List<OpticalMediaSnapshot> seen = <OpticalMediaSnapshot>[];
      final StreamSubscription<OpticalMediaSnapshot> subscription =
          service.changes.listen(seen.add);
      addTearDown(subscription.cancel);

      await service.inspect();
      udisks.table = opticalDriveObjects();
      udisks.emit();
      await _settle();

      // The disc is gone; the drive is not, and neither is anything else.
      expect(seen.last.drives.single.disc, OpticalDiscState.empty);
      expect(seen.last.hasDrive, isTrue);
      expect(seen.last.hasAudioCd, isFalse);
    });

    test('a USB drive being unplugged leaves a valid, empty answer', () async {
      final _FakeUDisks udisks =
          _FakeUDisks(objects: opticalDriveObjects(drive: audioCdDrive()));
      final LinuxOpticalMediaService service = serviceFor(udisks);
      addTearDown(service.dispose);

      await service.inspect();
      udisks.table = <String, Map<String, Map<String, DBusValue>>>{};
      udisks.emit();
      await _settle();

      expect(await service.inspect(), const OpticalMediaSnapshot.noDrive());
    });

    test('a disc being identified publishes one transition, not two', () async {
      // UDisks2 has nothing to say about a disc until cdrom_id has identified
      // it: MediaAvailable and Optical both come from ID_CDROM_MEDIA, so the
      // drive reads as empty right up to the moment it reads as an audio CD.
      // The settle delay is what keeps that from becoming a flicker.
      final _FakeUDisks udisks = _FakeUDisks(objects: opticalDriveObjects());
      final LinuxOpticalMediaService service = serviceFor(udisks);
      addTearDown(service.dispose);

      final List<OpticalMediaSnapshot> seen = <OpticalMediaSnapshot>[];
      final StreamSubscription<OpticalMediaSnapshot> subscription =
          service.changes.listen(seen.add);
      addTearDown(subscription.cancel);

      await service.inspect();
      await _settle();
      expect(seen.single.drives.single.disc, OpticalDiscState.empty);

      // The tray closes and udev fires before the disc has been identified.
      udisks.emit();
      await _settle();
      expect(seen, hasLength(1), reason: 'nothing changed yet');

      udisks.table = opticalDriveObjects(drive: audioCdDrive());
      udisks.emit();
      await _settle();
      expect(seen, hasLength(2));
      expect(seen.last.drives.single.disc, OpticalDiscState.audioCd);
    });

    test('an event that changes nothing publishes nothing', () async {
      final _FakeUDisks udisks =
          _FakeUDisks(objects: opticalDriveObjects(drive: audioCdDrive()));
      final LinuxOpticalMediaService service = serviceFor(udisks);
      addTearDown(service.dispose);

      final List<OpticalMediaSnapshot> seen = <OpticalMediaSnapshot>[];
      final StreamSubscription<OpticalMediaSnapshot> subscription =
          service.changes.listen(seen.add);
      addTearDown(subscription.cancel);

      await service.inspect();
      udisks.emit();
      await _settle();
      udisks.emit();
      await _settle();

      expect(seen, hasLength(1));
    });

    test('rapid insert and remove ends on the machine\'s real state', () async {
      final _FakeUDisks udisks = _FakeUDisks(objects: opticalDriveObjects());
      final LinuxOpticalMediaService service = serviceFor(udisks);
      addTearDown(service.dispose);

      final List<OpticalMediaSnapshot> seen = <OpticalMediaSnapshot>[];
      final StreamSubscription<OpticalMediaSnapshot> subscription =
          service.changes.listen(seen.add);
      addTearDown(subscription.cancel);

      await service.inspect();

      udisks.table = opticalDriveObjects(drive: audioCdDrive());
      udisks.emit();
      udisks.table = opticalDriveObjects();
      udisks.emit();
      udisks.table = opticalDriveObjects(drive: dataDiscDrive());
      udisks.emit();
      await _settle();
      await _settle();

      expect(seen.last.drives.single.disc, OpticalDiscState.otherMedia);
      expect(await service.inspect(), seen.last);
    });

    test('a drive that disappears mid-read does not strand the service',
        () async {
      final _FakeUDisks udisks =
          _FakeUDisks(objects: opticalDriveObjects(drive: audioCdDrive()));
      final LinuxOpticalMediaService service = serviceFor(udisks);
      addTearDown(service.dispose);

      final List<OpticalMediaSnapshot> seen = <OpticalMediaSnapshot>[];
      final StreamSubscription<OpticalMediaSnapshot> subscription =
          service.changes.listen(seen.add);
      addTearDown(subscription.cancel);

      await service.inspect();

      // The drive is pulled out while the read it triggered is in flight. The
      // read in flight owes one more, so the answer that lands is the one
      // describing the machine as it now is.
      udisks.onRead = () {
        udisks.onRead = null;
        udisks.table = <String, Map<String, Map<String, DBusValue>>>{};
        udisks.emit();
      };
      udisks.emit();
      await _settle();
      await _settle();

      expect(seen.last, const OpticalMediaSnapshot.noDrive());
    });

    test('a refusal is permission denied, not an error', () async {
      final _FakeUDisks udisks = _FakeUDisks()
        ..failure = DBusAccessDeniedException(
          DBusMethodErrorResponse('org.freedesktop.DBus.Error.AccessDenied'),
        );
      final LinuxOpticalMediaService service = serviceFor(udisks);
      addTearDown(service.dispose);

      expect(
        await service.inspect(),
        const OpticalMediaSnapshot.permissionDenied(),
      );
    });

    test('a polkit NotAuthorized refusal is permission denied too', () async {
      final _FakeUDisks udisks = _FakeUDisks()
        ..failure = DBusMethodResponseException(
          DBusMethodErrorResponse(
            'org.freedesktop.UDisks2.Error.NotAuthorizedCanObtain',
          ),
        );
      final LinuxOpticalMediaService service = serviceFor(udisks);
      addTearDown(service.dispose);

      expect(
        (await service.inspect()).availability,
        OpticalMediaAvailability.permissionDenied,
      );
    });

    test('a host with no UDisks2 is unsupported, not broken', () async {
      final _FakeUDisks udisks = _FakeUDisks()
        ..failure = DBusServiceUnknownException(
          DBusMethodErrorResponse('org.freedesktop.DBus.Error.ServiceUnknown'),
        );
      final LinuxOpticalMediaService service = serviceFor(udisks);
      addTearDown(service.dispose);

      expect(
        await service.inspect(),
        const OpticalMediaSnapshot.unsupported(),
      );
    });

    test('any other failure is an error, and never an exception', () async {
      final _FakeUDisks udisks = _FakeUDisks()
        ..failure = StateError('the bus went away');
      final LinuxOpticalMediaService service = serviceFor(udisks);
      addTearDown(service.dispose);

      expect(await service.inspect(), const OpticalMediaSnapshot.error());
    });

    test('a daemon that never answers is given up on', () async {
      final _FakeUDisks udisks = _FakeUDisks()..hangs = true;
      final LinuxOpticalMediaService service = serviceFor(
        udisks,
        callDeadline: const Duration(milliseconds: 10),
      );
      addTearDown(service.dispose);

      expect(await service.inspect(), const OpticalMediaSnapshot.error());

      // And the service still works afterwards: a wedged read must not leave
      // it believing one is in flight forever.
      udisks
        ..hangs = false
        ..table = opticalDriveObjects(drive: audioCdDrive());
      expect((await service.inspect()).hasAudioCd, isTrue);
    });

    test('a failed look reports no drives rather than stale ones', () async {
      final _FakeUDisks udisks =
          _FakeUDisks(objects: opticalDriveObjects(drive: audioCdDrive()));
      final LinuxOpticalMediaService service = serviceFor(udisks);
      addTearDown(service.dispose);

      expect((await service.inspect()).hasAudioCd, isTrue);

      udisks.failure = StateError('the bus went away');
      final OpticalMediaSnapshot snapshot = await service.inspect();

      expect(snapshot.drives, isEmpty);
      expect(snapshot.availability, OpticalMediaAvailability.error);
    });

    test('inside the Flatpak it reports unsupported and never looks', () async {
      final _FakeUDisks udisks =
          _FakeUDisks(objects: opticalDriveObjects(drive: audioCdDrive()));
      final LinuxOpticalMediaService service =
          serviceFor(udisks, sandboxed: true);
      addTearDown(service.dispose);

      expect(service.isSupported, isFalse);
      expect(await service.inspect(), const OpticalMediaSnapshot.unsupported());
      // No connection is opened for a question the sandbox cannot ask.
      expect(udisks.reads, 0);

      // And nothing is left waiting on events that can never come.
      expect(await service.changes.isEmpty, isTrue);
      expect(udisks.reads, 0);
    });

    test('nothing is read until something listens or asks', () async {
      final _FakeUDisks udisks = _FakeUDisks(objects: opticalDriveObjects());
      final LinuxOpticalMediaService service = serviceFor(udisks);
      addTearDown(service.dispose);

      await _settle();
      expect(udisks.reads, 0);
    });

    test('a change during a read is not lost with it', () async {
      final _FakeUDisks udisks = _FakeUDisks(objects: opticalDriveObjects());
      final LinuxOpticalMediaService service = serviceFor(udisks);
      addTearDown(service.dispose);

      final List<OpticalMediaSnapshot> seen = <OpticalMediaSnapshot>[];
      final StreamSubscription<OpticalMediaSnapshot> subscription =
          service.changes.listen(seen.add);
      addTearDown(subscription.cancel);

      await service.inspect();

      // A read is held open, and the disc goes in while it is in flight. The
      // read that is running already answered for the machine as it was, so
      // dropping the event would leave Linthra permanently one disc behind.
      final Completer<void> held = Completer<void>();
      udisks.gate = held;
      udisks.emit();
      await _settle();

      udisks.table = opticalDriveObjects(drive: audioCdDrive());
      udisks.emit();
      await _settle();
      held.complete();
      await _settle();

      expect(seen.last.hasAudioCd, isTrue);
    });

    test('dispose closes the source and is safe to call twice', () async {
      final _FakeUDisks udisks = _FakeUDisks(objects: opticalDriveObjects());
      final LinuxOpticalMediaService service = serviceFor(udisks);

      final StreamSubscription<OpticalMediaSnapshot> subscription =
          service.changes.listen((_) {});
      await service.inspect();

      await service.dispose();
      await service.dispose();
      await subscription.cancel();

      expect(udisks.closeCalls, 1);
      expect(
        await service.inspect(),
        const OpticalMediaSnapshot.unsupported(),
      );
    });

    test('an event after dispose reads nothing', () async {
      final _FakeUDisks udisks = _FakeUDisks(objects: opticalDriveObjects());
      final LinuxOpticalMediaService service = serviceFor(udisks);

      service.changes.listen((_) {});
      await service.inspect();
      final int reads = udisks.reads;
      await service.dispose();

      await _settle();
      expect(udisks.reads, reads);
    });
  });
}
