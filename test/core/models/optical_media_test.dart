import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/optical_media.dart';

void main() {
  const OpticalDrive emptyDrive =
      OpticalDrive(id: '/dev/sr0', disc: OpticalDiscState.empty);
  const OpticalDrive cdDrive =
      OpticalDrive(id: '/dev/sr0', disc: OpticalDiscState.audioCd);
  const OpticalDrive secondCdDrive =
      OpticalDrive(id: '/dev/sr1', disc: OpticalDiscState.audioCd);

  group('OpticalDrive', () {
    test('is equal by identity and disc together', () {
      expect(cdDrive,
          const OpticalDrive(id: '/dev/sr0', disc: OpticalDiscState.audioCd));
      expect(
          cdDrive.hashCode,
          const OpticalDrive(id: '/dev/sr0', disc: OpticalDiscState.audioCd)
              .hashCode);
      expect(cdDrive, isNot(emptyDrive));
      expect(cdDrive, isNot(secondCdDrive));
    });

    test('only an audio CD counts as one', () {
      expect(cdDrive.hasAudioCd, isTrue);
      expect(emptyDrive.hasAudioCd, isFalse);
      expect(
        const OpticalDrive(id: '/dev/sr0', disc: OpticalDiscState.otherMedia)
            .hasAudioCd,
        isFalse,
      );
    });

    test('changing the disc keeps the drive', () {
      expect(emptyDrive.withDisc(OpticalDiscState.audioCd), cdDrive);
    });

    test('describes itself with the handle and the disc, and nothing else', () {
      // A drive's model, serial and firmware are all things the platform can
      // hand over and nothing above needs. Anything of the sort added to this
      // model would be in bug reports the next day.
      expect(cdDrive.toString(), 'OpticalDrive(/dev/sr0, audioCd)');
    });
  });

  group('OpticalMediaSnapshot', () {
    test('"no drive" is a supported answer, not a failure', () {
      const OpticalMediaSnapshot snapshot = OpticalMediaSnapshot.noDrive();

      expect(snapshot.availability, OpticalMediaAvailability.supported);
      expect(snapshot.isSupported, isTrue);
      expect(snapshot.hasDrive, isFalse);
      expect(snapshot.hasAudioCd, isFalse);
    });

    test('unsupported, permission denied and error are all distinguishable',
        () {
      expect(
        const OpticalMediaSnapshot.unsupported().availability,
        OpticalMediaAvailability.unsupported,
      );
      expect(
        const OpticalMediaSnapshot.permissionDenied().availability,
        OpticalMediaAvailability.permissionDenied,
      );
      expect(
        const OpticalMediaSnapshot.error().availability,
        OpticalMediaAvailability.error,
      );
      expect(
        <OpticalMediaSnapshot>{
          const OpticalMediaSnapshot.unsupported(),
          const OpticalMediaSnapshot.permissionDenied(),
          const OpticalMediaSnapshot.error(),
          const OpticalMediaSnapshot.noDrive(),
        },
        hasLength(4),
      );
    });

    test('none of the failure states reports being supported', () {
      expect(const OpticalMediaSnapshot.unsupported().isSupported, isFalse);
      expect(
        const OpticalMediaSnapshot.permissionDenied().isSupported,
        isFalse,
      );
      expect(const OpticalMediaSnapshot.error().isSupported, isFalse);
    });

    test('audio CDs are picked out of a machine with several drives', () {
      final OpticalMediaSnapshot snapshot = OpticalMediaSnapshot(
        availability: OpticalMediaAvailability.supported,
        drives: <OpticalDrive>[emptyDrive, secondCdDrive],
      );

      expect(snapshot.hasDrive, isTrue);
      expect(snapshot.hasAudioCd, isTrue);
      expect(snapshot.audioCdDrives, <OpticalDrive>[secondCdDrive]);
    });

    test('two snapshots of the same machine are equal', () {
      final OpticalMediaSnapshot a = OpticalMediaSnapshot(
        availability: OpticalMediaAvailability.supported,
        drives: <OpticalDrive>[emptyDrive, secondCdDrive],
      );
      final OpticalMediaSnapshot b = OpticalMediaSnapshot(
        availability: OpticalMediaAvailability.supported,
        drives: <OpticalDrive>[emptyDrive, secondCdDrive],
      );

      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('a disc that changed makes a different snapshot', () {
      final OpticalMediaSnapshot before = OpticalMediaSnapshot(
        availability: OpticalMediaAvailability.supported,
        drives: <OpticalDrive>[emptyDrive],
      );
      final OpticalMediaSnapshot after = OpticalMediaSnapshot(
        availability: OpticalMediaAvailability.supported,
        drives: <OpticalDrive>[cdDrive],
      );

      expect(before, isNot(after));
    });

    test('a published snapshot cannot be rewritten through its drive list', () {
      // The list handed in is copied, not held. A caller that kept a
      // reference could otherwise sort, clear or append through it and
      // silently move an already-published value's hashCode -- and make a
      // later real state compare equal to it, so the change is never
      // announced.
      final List<OpticalDrive> mine = <OpticalDrive>[cdDrive];
      final OpticalMediaSnapshot snapshot = OpticalMediaSnapshot(
        availability: OpticalMediaAvailability.supported,
        drives: mine,
      );
      final int before = snapshot.hashCode;

      mine
        ..clear()
        ..add(emptyDrive);

      expect(snapshot.drives, <OpticalDrive>[cdDrive]);
      expect(snapshot.hashCode, before);
      expect(snapshot.hasAudioCd, isTrue);
    });

    test('the drive list cannot be mutated through the snapshot either', () {
      final OpticalMediaSnapshot snapshot = OpticalMediaSnapshot(
        availability: OpticalMediaAvailability.supported,
        drives: <OpticalDrive>[cdDrive],
      );

      expect(() => snapshot.drives.add(emptyDrive), throwsUnsupportedError);
      expect(() => snapshot.drives.clear(), throwsUnsupportedError);
    });

    test('drive order is part of the value', () {
      // Which is why the Linux reading sorts: an unsorted snapshot would
      // republish itself every time the platform enumerated differently.
      final OpticalMediaSnapshot a = OpticalMediaSnapshot(
        availability: OpticalMediaAvailability.supported,
        drives: <OpticalDrive>[emptyDrive, secondCdDrive],
      );
      final OpticalMediaSnapshot b = OpticalMediaSnapshot(
        availability: OpticalMediaAvailability.supported,
        drives: <OpticalDrive>[secondCdDrive, emptyDrive],
      );

      expect(a, isNot(b));
    });
  });
}
