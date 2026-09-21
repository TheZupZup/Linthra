import 'package:dbus/dbus.dart';

import '../../models/optical_media.dart';

/// The UDisks2 interfaces Linthra reads, and the properties it reads from
/// them. Nothing else on the bus is touched.
///
/// Spelled out as constants so the exact surface is one short list a reviewer
/// can check against the UDisks2 documentation, rather than string literals
/// scattered through a state machine.
abstract final class UDisks {
  /// The service that answers. Part of `udisks2`, present on essentially every
  /// desktop Linux install, and the thing GNOME Disks, GVfs and every file
  /// manager already use to talk about removable media.
  static const String busName = 'org.freedesktop.UDisks2';

  /// The object manager: one call gives every drive and block device at once.
  static const String managerPath = '/org/freedesktop/UDisks2';

  /// Per-drive properties: what media the drive takes, and what is in it.
  static const String driveInterface = 'org.freedesktop.UDisks2.Drive';

  /// Per-block-device properties. Read for exactly two of them — the kernel
  /// device node and which drive it belongs to — so a drive can be given a
  /// handle a later PR can open.
  static const String blockInterface = 'org.freedesktop.UDisks2.Block';

  /// Present on a block device that is a *partition* of another one. Never
  /// read; its presence alone is what makes [opticalSnapshotFrom] skip a block
  /// so a drive is named by its whole-disc node rather than by a partition of
  /// the disc in it.
  static const String partitionInterface = 'org.freedesktop.UDisks2.Partition';

  /// Media kinds the drive accepts, e.g. `optical_cd`, `optical_dvd`. How an
  /// optical drive is recognised *while it is empty*, when there is no disc to
  /// look at.
  static const String mediaCompatibility = 'MediaCompatibility';

  /// The media currently in the drive, e.g. `optical_cd`, or empty for none.
  static const String media = 'Media';

  /// Whether there is anything in the drive at all.
  static const String mediaAvailable = 'MediaAvailable';

  /// Whether what is in the drive is an optical disc UDisks2 has identified.
  static const String optical = 'Optical';

  /// Total tracks on the disc.
  static const String opticalNumTracks = 'OpticalNumTracks';

  /// CD-DA audio tracks on the disc. **The property this whole feature turns
  /// on**: see [udisksOpticalDiscState].
  static const String opticalNumAudioTracks = 'OpticalNumAudioTracks';

  /// The kernel device node, as a NUL-terminated byte array (`/dev/sr0`).
  static const String device = 'Device';

  /// The object path of the drive a block device belongs to, or `/` for none.
  static const String drive = 'Drive';

  /// The prefix every optical media kind shares in UDisks2's vocabulary.
  static const String opticalMediaPrefix = 'optical_';

  /// The object path UDisks2 uses for "this block device has no drive".
  static const String noDrivePath = '/';
}

/// Every UDisks2 object, keyed by object path, with each object's interfaces
/// and their properties.
///
/// The exact shape `org.freedesktop.DBus.ObjectManager.GetManagedObjects`
/// returns, with object paths flattened to plain strings so nothing above this
/// layer has to hold a D-Bus type just to use a map key.
typedef UDisksObjectTable = Map<String, Map<String, Map<String, DBusValue>>>;

/// The handful of `org.freedesktop.UDisks2.Drive` properties Linthra reads,
/// pulled out of a D-Bus property map into plain Dart values.
///
/// A record rather than a class because it is a decoded row and nothing more:
/// it has no identity, no behaviour, and it never leaves this file's
/// neighbourhood — [udisksOpticalDiscState] turns it into an
/// [OpticalDiscState] and the model takes over from there.
typedef UDisksDriveProperties = ({
  List<String> mediaCompatibility,
  String media,
  bool mediaAvailable,
  bool optical,
  int opticalNumTracks,
  int opticalNumAudioTracks,
});

/// Decodes a `Drive` property map, tolerating everything a property map can
/// legitimately be missing.
///
/// Defensive by design, and not out of superstition: UDisks2 publishes a drive
/// object before it has finished probing the medium in it, `PropertiesChanged`
/// carries only the properties that moved, and a distribution may be running a
/// version older or newer than the one this was written against. A missing
/// property is therefore normal traffic, not corruption. Every absent or
/// wrongly-typed value falls back to the reading that claims the least —
/// no media, not optical, no tracks — so an incomplete map can only ever make
/// Linthra say "nothing here", never invent a disc.
UDisksDriveProperties udisksDrivePropertiesFrom(
  Map<String, DBusValue> properties,
) {
  return (
    mediaCompatibility: _stringList(properties[UDisks.mediaCompatibility]),
    media: _string(properties[UDisks.media]),
    mediaAvailable: _boolean(properties[UDisks.mediaAvailable]),
    optical: _boolean(properties[UDisks.optical]),
    opticalNumTracks: _unsigned(properties[UDisks.opticalNumTracks]),
    opticalNumAudioTracks: _unsigned(properties[UDisks.opticalNumAudioTracks]),
  );
}

/// Whether these properties describe an optical drive at all.
///
/// Three independent signals, because no single one holds for every drive:
///
///  * `MediaCompatibility` lists what the drive *accepts*, so it identifies an
///    empty drive — the common case, and the one a "you have a CD drive"
///    message depends on.
///  * `Media` names what is in the drive right now, which covers a drive whose
///    enclosure reports no compatibility list at all (cheap USB caddies do
///    this).
///  * `Optical` is UDisks2's own verdict on the medium, and is the last word
///    when the other two are silent.
///
/// A hard disk, a USB stick and an SD card answer no to all three, which is
/// the point: nothing here treats an ordinary removable drive as optical media
/// and drags it into a CD source.
bool isUDisksOpticalDrive(UDisksDriveProperties properties) {
  if (properties.optical) return true;
  if (properties.media.startsWith(UDisks.opticalMediaPrefix)) return true;
  return properties.mediaCompatibility
      .any((String kind) => kind.startsWith(UDisks.opticalMediaPrefix));
}

/// What is in this optical drive, or `null` when it is not an optical drive.
///
/// **This is where an audio CD is told apart from a disc that merely holds
/// audio files.** `OpticalNumAudioTracks` counts CD-DA tracks in the disc's
/// table of contents, which the drive reads off the disc itself. It is
/// non-zero only for a real Red Book audio disc: a data CD full of FLAC files
/// has an ISO 9660 filesystem and zero audio tracks, and reads here as
/// [OpticalDiscState.otherMedia] no matter what is inside that filesystem.
/// Nothing in this path looks at a mount point, a directory listing or a file
/// extension, so a mounted disc of MP3s can never be mistaken for CD-DA and a
/// CD-DA disc — which has no filesystem to mount — is never missed for want of
/// one.
///
/// The ordering of the checks is the whole rule:
///
///  1. nothing in the drive at all → [OpticalDiscState.empty];
///  2. something in the drive that UDisks2 has not identified as an optical
///     disc → [OpticalDiscState.unreadable], which covers both a disc still
///     being probed and one the drive cannot read;
///  3. at least one audio track → [OpticalDiscState.audioCd], including
///     mixed-mode discs that also carry a data session;
///  4. anything else → [OpticalDiscState.otherMedia]: a data CD, a DVD, a
///     Blu-ray, or a blank disc with no tracks at all.
OpticalDiscState? udisksOpticalDiscState(UDisksDriveProperties properties) {
  if (!isUDisksOpticalDrive(properties)) return null;
  if (!properties.mediaAvailable) return OpticalDiscState.empty;
  if (!properties.optical) return OpticalDiscState.unreadable;
  if (properties.opticalNumAudioTracks > 0) return OpticalDiscState.audioCd;
  return OpticalDiscState.otherMedia;
}

/// The kernel device node from a `Block` property map (`/dev/sr0`), or `null`
/// when it is absent or unusable.
///
/// UDisks2 publishes it as a NUL-terminated byte array rather than a string,
/// because a device node is bytes to the kernel. The trailing NUL is dropped
/// and the rest read as ASCII; a node containing anything but printable ASCII
/// is rejected rather than guessed at, since the only thing this value is ever
/// used for is being handed back to the system.
String? udisksBlockDeviceNode(Map<String, DBusValue> properties) {
  final DBusValue? value = properties[UDisks.device];
  if (value is! DBusArray || value.childSignature.value != 'y') return null;
  final List<int> bytes = value
      .asByteArray()
      .takeWhile((int byte) => byte != 0)
      .toList(growable: false);
  if (bytes.isEmpty) return null;
  if (bytes.any((int byte) => byte < 0x20 || byte > 0x7e)) return null;
  return String.fromCharCodes(bytes);
}

/// The object path of the drive a block device belongs to, or `null` when it
/// belongs to none. UDisks2 spells "none" as `/`.
String? udisksBlockDrivePath(Map<String, DBusValue> properties) {
  final DBusValue? value = properties[UDisks.drive];
  if (value is! DBusObjectPath) return null;
  final String path = value.value;
  if (path.isEmpty || path == UDisks.noDrivePath) return null;
  return path;
}

List<String> _stringList(DBusValue? value) {
  if (value is! DBusArray || value.childSignature.value != 's') {
    return const <String>[];
  }
  return value.asStringArray().toList(growable: false);
}

String _string(DBusValue? value) => value is DBusString ? value.value : '';

bool _boolean(DBusValue? value) => value is DBusBoolean && value.value;

/// UDisks2 declares the track counts as `u` (uint32). A signed or 64-bit
/// spelling from some other implementation of the same interface is accepted
/// too, because the number is all that matters and refusing it would mean
/// reporting "no tracks" for a disc that has them.
int _unsigned(DBusValue? value) {
  if (value is DBusUint32) return value.value;
  if (value is DBusUint64) return value.value;
  if (value is DBusInt32) return value.value < 0 ? 0 : value.value;
  if (value is DBusInt64) return value.value < 0 ? 0 : value.value;
  return 0;
}

/// Turns one whole read of UDisks2's object tree into Linthra's answer.
///
/// The pure half of Linux optical detection: a map in, an
/// [OpticalMediaSnapshot] out, no bus, no disc, no clock. Everything about how
/// a CD drive is recognised and what counts as an audio CD is decided here or
/// in [udisksOpticalDiscState], which is why those two functions carry the
/// fixture tests rather than the connection above them.
///
/// Two joins make up the whole of it:
///
///  * a **drive** object carries the disc state but no device node, and
///  * a **block** object carries the device node and names the drive it
///    belongs to.
///
/// A drive with no block object is left out rather than given a synthesised
/// handle. There would be nothing for a later PR to open, and inventing an
/// identity for a drive Linthra cannot address is worse than briefly not
/// listing it: UDisks2 publishes the block device in the same burst of events,
/// so the very next read has it.
///
/// A block that is a partition is skipped, so a drive is identified by
/// `/dev/sr0` rather than by a partition of whatever disc happens to be in it
/// today. When a drive still has several candidate blocks, the lexicographi-
/// cally smallest node wins — an arbitrary rule, chosen only so that two reads
/// of an unchanged machine produce equal snapshots instead of flapping.
///
/// The result is sorted by [OpticalDrive.id] for the same reason: object-map
/// iteration order is not a promise anyone made, and a snapshot that differs
/// only in drive order would republish itself forever.
OpticalMediaSnapshot opticalSnapshotFrom(UDisksObjectTable objects) {
  final Map<String, OpticalDiscState> discs = <String, OpticalDiscState>{};
  final Map<String, String> devices = <String, String>{};

  for (final MapEntry<String, Map<String, Map<String, DBusValue>>> object
      in objects.entries) {
    final Map<String, DBusValue>? drive = object.value[UDisks.driveInterface];
    if (drive != null) {
      final OpticalDiscState? state =
          udisksOpticalDiscState(udisksDrivePropertiesFrom(drive));
      if (state != null) discs[object.key] = state;
    }

    final Map<String, DBusValue>? block = object.value[UDisks.blockInterface];
    if (block == null) continue;
    if (object.value.containsKey(UDisks.partitionInterface)) continue;
    final String? drivePath = udisksBlockDrivePath(block);
    final String? device = udisksBlockDeviceNode(block);
    if (drivePath == null || device == null) continue;
    final String? claimed = devices[drivePath];
    if (claimed == null || device.compareTo(claimed) < 0) {
      devices[drivePath] = device;
    }
  }

  final List<OpticalDrive> drives = <OpticalDrive>[
    for (final MapEntry<String, OpticalDiscState> disc in discs.entries)
      if (devices[disc.key] case final String device)
        OpticalDrive(id: device, disc: disc.value),
  ]..sort((OpticalDrive a, OpticalDrive b) => a.id.compareTo(b.id));

  return OpticalMediaSnapshot(
    availability: OpticalMediaAvailability.supported,
    drives: drives,
  );
}
