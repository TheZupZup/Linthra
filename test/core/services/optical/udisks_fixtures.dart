/// Deterministic UDisks2 object tables, in the exact shape
/// `GetManagedObjects` returns.
///
/// Every optical test in this directory builds its world from these, so no
/// test needs a drive, a disc, a bus or a machine that has ever seen one. The
/// property values are the ones a real UDisks2 publishes: the shapes were
/// taken from `busctl introspect org.freedesktop.UDisks2 …` on a machine with
/// a SATA DVD drive, which is why `Device` is a NUL-terminated byte array
/// rather than a string and why the track counts are `u`.
library;

import 'package:dbus/dbus.dart';
import 'package:linthra/core/services/optical/udisks_drive_reading.dart';

/// A `Drive` interface for an optical drive.
///
/// The defaults describe the ordinary resting state: a CD/DVD drive with
/// nothing in it.
Map<String, DBusValue> opticalDriveInterface({
  List<String> mediaCompatibility = const <String>['optical_cd', 'optical_dvd'],
  String media = '',
  bool mediaAvailable = false,
  bool optical = false,
  int numTracks = 0,
  int numAudioTracks = 0,
}) {
  return <String, DBusValue>{
    UDisks.mediaCompatibility: DBusArray.string(mediaCompatibility),
    UDisks.media: DBusString(media),
    UDisks.mediaAvailable: DBusBoolean(mediaAvailable),
    UDisks.optical: DBusBoolean(optical),
    UDisks.opticalNumTracks: DBusUint32(numTracks),
    UDisks.opticalNumAudioTracks: DBusUint32(numAudioTracks),
  };
}

/// A `Drive` interface for something that is not optical at all: the internal
/// SSD, a USB stick, an SD card.
Map<String, DBusValue> nonOpticalDriveInterface({
  List<String> mediaCompatibility = const <String>[],
  bool mediaAvailable = true,
}) =>
    opticalDriveInterface(
      mediaCompatibility: mediaCompatibility,
      mediaAvailable: mediaAvailable,
    );

/// A `Block` interface naming its device node and the drive it belongs to.
Map<String, DBusValue> blockInterface({
  required String device,
  required String drivePath,
}) {
  return <String, DBusValue>{
    // UDisks2 publishes the node NUL-terminated, and code that forgets the
    // terminator produces a device path that looks right and opens nothing.
    UDisks.device: DBusArray.byte(<int>[...device.codeUnits, 0]),
    UDisks.drive: DBusObjectPath(drivePath),
  };
}

/// One drive object plus its block object, the pair UDisks2 publishes for a
/// real drive.
UDisksObjectTable opticalDriveObjects({
  String drivePath = '/org/freedesktop/UDisks2/drives/Optical_Drive',
  String blockPath = '/org/freedesktop/UDisks2/block_devices/sr0',
  String device = '/dev/sr0',
  Map<String, DBusValue>? drive,
}) {
  return <String, Map<String, Map<String, DBusValue>>>{
    drivePath: <String, Map<String, DBusValue>>{
      UDisks.driveInterface: drive ?? opticalDriveInterface(),
    },
    blockPath: <String, Map<String, DBusValue>>{
      UDisks.blockInterface:
          blockInterface(device: device, drivePath: drivePath),
    },
  };
}

/// A drive holding a CD-DA disc with [numAudioTracks] audio tracks.
Map<String, DBusValue> audioCdDrive({int numAudioTracks = 12}) =>
    opticalDriveInterface(
      media: 'optical_cd',
      mediaAvailable: true,
      optical: true,
      numTracks: numAudioTracks,
      numAudioTracks: numAudioTracks,
    );

/// A drive holding a data disc: an ISO 9660 CD or a DVD. No audio tracks, no
/// matter what files are on it.
Map<String, DBusValue> dataDiscDrive({String media = 'optical_cd'}) =>
    opticalDriveInterface(
      media: media,
      mediaAvailable: true,
      optical: true,
      numTracks: 1,
    );

/// A drive with something in it that UDisks2 has not identified yet — the
/// moment just after a disc is inserted, and also a disc the drive cannot
/// read.
Map<String, DBusValue> unidentifiedDiscDrive() =>
    opticalDriveInterface(mediaAvailable: true);

/// Merges [tables] into one, for a machine with more than one drive.
UDisksObjectTable mergedObjects(List<UDisksObjectTable> tables) {
  return <String, Map<String, Map<String, DBusValue>>>{
    for (final UDisksObjectTable table in tables) ...table,
  };
}
