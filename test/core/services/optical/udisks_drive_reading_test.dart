import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/optical_media.dart';
import 'package:linthra/core/services/optical/udisks_drive_reading.dart';

import 'udisks_fixtures.dart';

void main() {
  group('udisksOpticalDiscState', () {
    OpticalDiscState? stateOf(Map<String, DBusValue> drive) =>
        udisksOpticalDiscState(udisksDrivePropertiesFrom(drive));

    test('a drive with nothing in it is empty, not absent', () {
      expect(stateOf(opticalDriveInterface()), OpticalDiscState.empty);
    });

    test('an audio CD is recognised from its CD-DA track count', () {
      expect(stateOf(audioCdDrive()), OpticalDiscState.audioCd);
    });

    test('one audio track is still an audio CD', () {
      expect(
        stateOf(audioCdDrive(numAudioTracks: 1)),
        OpticalDiscState.audioCd,
      );
    });

    test('a mixed-mode disc with audio and data tracks is an audio CD', () {
      // CD-Extra: audio tracks plus a data session. A music player cares that
      // there are audio tracks, not that there is also a filesystem.
      final Map<String, DBusValue> drive = opticalDriveInterface(
        media: 'optical_cd',
        mediaAvailable: true,
        optical: true,
        numTracks: 11,
        numAudioTracks: 10,
      );
      expect(stateOf(drive), OpticalDiscState.audioCd);
    });

    test('a data CD is not an audio CD, whatever is inside its filesystem', () {
      // The case this whole property exists to get right: a CD full of FLAC
      // files has an ISO 9660 filesystem, zero CD-DA tracks, and must never be
      // mistaken for a disc that can be played track by track.
      expect(stateOf(dataDiscDrive()), OpticalDiscState.otherMedia);
    });

    test('a DVD is other media', () {
      expect(
        stateOf(dataDiscDrive(media: 'optical_dvd')),
        OpticalDiscState.otherMedia,
      );
    });

    test('a blank disc with no tracks at all is other media', () {
      final Map<String, DBusValue> drive = opticalDriveInterface(
        media: 'optical_cd_r',
        mediaAvailable: true,
        optical: true,
      );
      expect(stateOf(drive), OpticalDiscState.otherMedia);
    });

    test('media present but not yet identified reads as unreadable', () {
      // Both the moment after insertion and a disc the drive cannot read. A
      // caller must treat it as transient; detection is event-driven, so the
      // first resolves itself on the next signal.
      expect(stateOf(unidentifiedDiscDrive()), OpticalDiscState.unreadable);
    });

    test('a non-optical drive is not an optical drive', () {
      expect(stateOf(nonOpticalDriveInterface()), isNull);
      expect(
        stateOf(
          nonOpticalDriveInterface(
            mediaCompatibility: const <String>['flash_sd', 'flash_mmc'],
          ),
        ),
        isNull,
      );
    });

    test('an empty property map claims nothing', () {
      // UDisks2 publishes a drive before it has finished probing it, so this
      // is normal traffic. It must not read as a drive, and above all not as
      // a disc.
      expect(stateOf(const <String, DBusValue>{}), isNull);
    });

    test('wrongly typed properties fall back rather than throwing', () {
      final Map<String, DBusValue> drive = <String, DBusValue>{
        UDisks.mediaCompatibility: const DBusString('optical_cd'),
        UDisks.media: const DBusUint32(7),
        UDisks.mediaAvailable: const DBusString('yes'),
        UDisks.optical: const DBusUint32(1),
        UDisks.opticalNumAudioTracks: const DBusString('12'),
      };
      expect(stateOf(drive), isNull);
    });

    test('a drive only Optical vouches for is still an optical drive', () {
      // An enclosure that reports no compatibility list at all.
      final Map<String, DBusValue> drive = <String, DBusValue>{
        UDisks.mediaAvailable: const DBusBoolean(true),
        UDisks.optical: const DBusBoolean(true),
        UDisks.opticalNumAudioTracks: const DBusUint32(9),
      };
      expect(stateOf(drive), OpticalDiscState.audioCd);
    });

    test('track counts are read from other integer spellings too', () {
      final Map<String, DBusValue> drive = <String, DBusValue>{
        UDisks.mediaCompatibility: DBusArray.string(<String>['optical_cd']),
        UDisks.mediaAvailable: const DBusBoolean(true),
        UDisks.optical: const DBusBoolean(true),
        UDisks.opticalNumAudioTracks: const DBusInt32(5),
      };
      expect(stateOf(drive), OpticalDiscState.audioCd);
    });

    test('a negative track count is not a disc with tracks', () {
      final Map<String, DBusValue> drive = <String, DBusValue>{
        UDisks.mediaCompatibility: DBusArray.string(<String>['optical_cd']),
        UDisks.mediaAvailable: const DBusBoolean(true),
        UDisks.optical: const DBusBoolean(true),
        UDisks.opticalNumAudioTracks: const DBusInt32(-1),
      };
      expect(stateOf(drive), OpticalDiscState.otherMedia);
    });
  });

  group('udisksBlockDeviceNode', () {
    test('reads a NUL-terminated device node', () {
      expect(
        udisksBlockDeviceNode(
          blockInterface(device: '/dev/sr0', drivePath: '/drive'),
        ),
        '/dev/sr0',
      );
    });

    test('is null when the property is missing', () {
      expect(udisksBlockDeviceNode(const <String, DBusValue>{}), isNull);
    });

    test('is null for an empty or non-printable node', () {
      expect(
        udisksBlockDeviceNode(<String, DBusValue>{
          UDisks.device: DBusArray.byte(<int>[0]),
        }),
        isNull,
      );
      expect(
        udisksBlockDeviceNode(<String, DBusValue>{
          UDisks.device: DBusArray.byte(<int>[0x2f, 0x07, 0x00]),
        }),
        isNull,
      );
    });

    test('is null when the property is not a byte array', () {
      expect(
        udisksBlockDeviceNode(<String, DBusValue>{
          UDisks.device: const DBusString('/dev/sr0'),
        }),
        isNull,
      );
    });
  });

  group('udisksBlockDrivePath', () {
    test('reads the owning drive', () {
      expect(
        udisksBlockDrivePath(
          blockInterface(device: '/dev/sr0', drivePath: '/drives/cd'),
        ),
        '/drives/cd',
      );
    });

    test('treats UDisks2\'s "no drive" path as no drive', () {
      expect(
        udisksBlockDrivePath(<String, DBusValue>{
          UDisks.drive: DBusObjectPath('/'),
        }),
        isNull,
      );
    });
  });

  group('opticalSnapshotFrom', () {
    test('a machine with no optical drive is a positive finding', () {
      final OpticalMediaSnapshot snapshot = opticalSnapshotFrom(
        <String, Map<String, Map<String, DBusValue>>>{
          '/org/freedesktop/UDisks2/drives/Samsung_SSD':
              <String, Map<String, DBusValue>>{
            UDisks.driveInterface: nonOpticalDriveInterface(),
          },
          '/org/freedesktop/UDisks2/block_devices/nvme0n1':
              <String, Map<String, DBusValue>>{
            UDisks.blockInterface: blockInterface(
              device: '/dev/nvme0n1',
              drivePath: '/org/freedesktop/UDisks2/drives/Samsung_SSD',
            ),
          },
        },
      );

      expect(snapshot.isSupported, isTrue);
      expect(snapshot.hasDrive, isFalse);
      expect(snapshot.drives, isEmpty);
    });

    test('an empty optical drive is reported with its device node', () {
      final OpticalMediaSnapshot snapshot =
          opticalSnapshotFrom(opticalDriveObjects());

      expect(snapshot.drives, <OpticalDrive>[
        const OpticalDrive(id: '/dev/sr0', disc: OpticalDiscState.empty),
      ]);
      expect(snapshot.hasAudioCd, isFalse);
    });

    test('an audio CD is reported against the drive holding it', () {
      final OpticalMediaSnapshot snapshot = opticalSnapshotFrom(
        opticalDriveObjects(drive: audioCdDrive()),
      );

      expect(snapshot.hasAudioCd, isTrue);
      expect(snapshot.audioCdDrives.single.id, '/dev/sr0');
    });

    test('several optical drives are all reported, in a stable order', () {
      // Nothing here assumes one drive, and nothing assumes /dev/sr0: a
      // machine with an internal DVD drive and a USB CD drive has two.
      final UDisksObjectTable objects = mergedObjects(<UDisksObjectTable>[
        opticalDriveObjects(
          drivePath: '/drives/usb',
          blockPath: '/blocks/sr1',
          device: '/dev/sr1',
          drive: audioCdDrive(),
        ),
        opticalDriveObjects(
          drivePath: '/drives/internal',
          blockPath: '/blocks/sr0',
          device: '/dev/sr0',
          drive: dataDiscDrive(),
        ),
      ]);

      final OpticalMediaSnapshot snapshot = opticalSnapshotFrom(objects);

      expect(snapshot.drives, <OpticalDrive>[
        const OpticalDrive(id: '/dev/sr0', disc: OpticalDiscState.otherMedia),
        const OpticalDrive(id: '/dev/sr1', disc: OpticalDiscState.audioCd),
      ]);
      expect(snapshot.audioCdDrives.single.id, '/dev/sr1');
    });

    test('a drive whose block device is not there yet is left out', () {
      // Rather than given a synthesised handle. UDisks2 publishes the block
      // in the same burst, so the next read has it.
      final OpticalMediaSnapshot snapshot = opticalSnapshotFrom(
        <String, Map<String, Map<String, DBusValue>>>{
          '/drives/cd': <String, Map<String, DBusValue>>{
            UDisks.driveInterface: audioCdDrive(),
          },
        },
      );

      expect(snapshot.isSupported, isTrue);
      expect(snapshot.drives, isEmpty);
    });

    test('a partition of the disc does not become the drive handle', () {
      final UDisksObjectTable objects =
          opticalDriveObjects(drive: dataDiscDrive())
            ..['/org/freedesktop/UDisks2/block_devices/sr0p1'] =
                <String, Map<String, DBusValue>>{
              UDisks.blockInterface: blockInterface(
                device: '/dev/sr0p1',
                drivePath: '/org/freedesktop/UDisks2/drives/Optical_Drive',
              ),
              UDisks.partitionInterface: const <String, DBusValue>{},
            };

      expect(opticalSnapshotFrom(objects).drives.single.id, '/dev/sr0');
    });

    test('an object table with nothing in it is no drive, not an error', () {
      final OpticalMediaSnapshot snapshot = opticalSnapshotFrom(
        <String, Map<String, Map<String, DBusValue>>>{},
      );

      expect(snapshot.availability, OpticalMediaAvailability.supported);
      expect(snapshot.drives, isEmpty);
    });

    test('two reads of an unchanged machine compare equal', () {
      // What keeps an event-driven service from republishing itself forever.
      final UDisksObjectTable objects = mergedObjects(<UDisksObjectTable>[
        opticalDriveObjects(
          drivePath: '/drives/b',
          blockPath: '/blocks/sr1',
          device: '/dev/sr1',
        ),
        opticalDriveObjects(
          drivePath: '/drives/a',
          blockPath: '/blocks/sr0',
          device: '/dev/sr0',
          drive: audioCdDrive(),
        ),
      ]);

      expect(opticalSnapshotFrom(objects), opticalSnapshotFrom(objects));
    });
  });
}
