import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/services/optical/method_channel_cdrom_toc_source.dart';

/// Holds the two halves of the optical-TOC channel (#631) to the same strings.
///
/// The channel is a pair of names on each side of one wire, and a rename on
/// either side is *silent*: the runner keeps answering on a name nothing calls,
/// Dart keeps calling a name nothing answers, and every disc quietly reports
/// "this build cannot read discs". Nothing fails to build, and nobody notices
/// until somebody puts a CD in.
///
/// `scripts/check_linux_runner.py` does the same job for Linthra's other two
/// Linux channels. This test is the same check for this one, kept here because
/// it can be written against the Dart constants directly.
void main() {
  final File runner = File('linux/runner/optical_toc_channel.cc');
  final File registration = File('linux/runner/my_application.cc');
  final File build = File('linux/runner/CMakeLists.txt');

  String source() {
    expect(
      runner.existsSync(),
      isTrue,
      reason: '${runner.path} is the native half of the optical TOC channel',
    );
    return runner.readAsStringSync();
  }

  void expectConstant(String name, String value) {
    expect(
      source(),
      contains('$name =\n    "$value";'),
      reason: 'the runner must define $name as "$value"',
    );
  }

  group('the channel names agree', () {
    test('the channel itself', () {
      expectConstant(
        'kChannelName',
        MethodChannelCdromTocSource.channelName,
      );
    });

    test('the method and its argument', () {
      expect(
        source(),
        contains(
          'kReadTocMethod = "${MethodChannelCdromTocSource.readTocMethod}"',
        ),
      );
      expect(
        source(),
        contains(
          'kDeviceArgument = "${MethodChannelCdromTocSource.deviceArgument}"',
        ),
      );
    });

    test('every reply key Dart reads', () {
      final Map<String, String> keys = <String, String>{
        'kFirstTrackKey': MethodChannelCdromTocSource.firstTrackKey,
        'kLastTrackKey': MethodChannelCdromTocSource.lastTrackKey,
        'kLeadOutKey': MethodChannelCdromTocSource.leadOutKey,
        'kTracksKey': MethodChannelCdromTocSource.tracksKey,
        'kTrackNumberKey': MethodChannelCdromTocSource.trackNumberKey,
        'kTrackLbaKey': MethodChannelCdromTocSource.trackLbaKey,
        'kTrackControlKey': MethodChannelCdromTocSource.trackControlKey,
        'kCdTextKey': MethodChannelCdromTocSource.cdTextKey,
      };
      for (final MapEntry<String, String> key in keys.entries) {
        expect(
          source(),
          contains('${key.key} = "${key.value}"'),
          reason: '${key.key} must be "${key.value}"',
        );
      }
    });

    test('every error code Dart maps', () {
      final Map<String, String> codes = <String, String>{
        'kNoDiscError': MethodChannelCdromTocSource.noDiscError,
        'kDiscChangedError': MethodChannelCdromTocSource.discChangedError,
        'kUnreadableError': MethodChannelCdromTocSource.unreadableError,
        'kDriveUnavailableError':
            MethodChannelCdromTocSource.driveUnavailableError,
        'kPermissionDeniedError':
            MethodChannelCdromTocSource.permissionDeniedError,
      };
      for (final MapEntry<String, String> code in codes.entries) {
        expect(
          source(),
          contains('${code.key} = "${code.value}"'),
          reason: '${code.key} must be "${code.value}"',
        );
      }
    });
  });

  group('the runner actually carries the channel', () {
    test('it is compiled into the binary', () {
      expect(
        build.readAsStringSync(),
        contains('"optical_toc_channel.cc"'),
        reason: 'a source file nothing compiles registers no channel',
      );
    });

    test('it is registered on the engine and torn down again', () {
      final String application = registration.readAsStringSync();
      expect(
        application,
        contains('optical_toc_channel_new('),
        reason: 'my_application.cc must register the channel',
      );
      expect(
        application,
        contains('optical_toc_channel_free'),
        reason: 'my_application.cc must free the channel',
      );
    });
  });

  group('the runner stays read-only', () {
    // The channel exists to read a table of contents. Nothing about that needs
    // to move a tray, lock a drive, start playback or open anything for
    // writing, and an ioctl that did would be a capability this feature never
    // asked for.
    test('it issues no write, eject, lock or play ioctl', () {
      final String code = source();
      for (final String forbidden in <String>[
        'CDROMEJECT',
        'CDROMCLOSETRAY',
        'CDROM_LOCKDOOR',
        'CDROMPLAYMSF',
        'CDROMPLAYTRKIND',
        'CDROMSTART',
        'CDROMSTOP',
        'CDROM_SEND_PACKET',
        'O_RDWR',
        'O_WRONLY',
      ]) {
        expect(
          code,
          isNot(contains(forbidden)),
          reason: 'the optical TOC channel must never use $forbidden',
        );
      }
    });

    test('it opens the device read-only and non-blocking', () {
      // O_NONBLOCK is not an optimisation: without it, opening a CD-ROM
      // blocks until a disc is present and can make the kernel close the tray.
      expect(source(), contains('O_RDONLY | O_NONBLOCK | O_CLOEXEC'));
    });

    test('it reads the table of contents through the kernel\'s own ioctls', () {
      expect(source(), contains('CDROMREADTOCHDR'));
      expect(source(), contains('CDROMREADTOCENTRY'));
      expect(source(), contains('CDROM_LEADOUT'));
    });
  });

  group('the runner is careful about what it reports', () {
    // These four are the bugs a review found in the first cut of this file.
    // None of them can be reached from a Dart test — there is no drive — so
    // the shape of each fix is asserted here instead of nowhere.

    test('only a definite empty tray is reported as no disc', () {
      // `CDS_NO_INFO` is what a drive with no status query answers, and
      // `CDS_DRIVE_NOT_READY` is a drive spinning up or fighting a damaged
      // disc. Collapsing either into "no disc" would hide a disc the user is
      // holding the case of.
      final String code = source();
      expect(code, contains('CDS_NO_DISC'));
      expect(code, contains('CDS_TRAY_OPEN'));
      expect(
        code,
        isNot(contains('return status == CDS_DISC_OK;')),
        reason: 'the drive status must not collapse to a single boolean',
      );
    });

    test('a short SG_IO transfer is cut back to what arrived', () {
      // Otherwise the zero tail of the buffer reaches Dart as fabricated
      // CD-Text packs.
      expect(source(), contains('io.resid'));
      expect(source(), contains('buffer.resize('));
    });

    test('the disc-change check compares the whole table of contents', () {
      // Two discs can share a track range and a lead-out; only the full TOC
      // proves the disc in the drive is still the one that was read.
      expect(source(), contains('bool SameDisc('));
      expect(source(), contains('a.tracks[i].lba != b.tracks[i].lba'));
      expect(source(), contains('a.tracks[i].control != b.tracks[i].control'));
    });

    test('a malformed answer is never classified by a stale errno', () {
      // The TOC helpers fail two ways — an ioctl the kernel refused, and an
      // answer that makes no sense — and only the first leaves anything in
      // `errno`. A bare bool made the caller reach for `errno` either way,
      // which on a reused worker thread classifies a malformed disc by
      // whatever unrelated syscall failed on that thread last.
      final String code = source();
      expect(code, contains('const char* ReadTocHeader('));
      expect(code, contains('const char* ReadTocEntry('));
      expect(code, contains('const char* ReadWholeToc('));
      // Every surviving `ErrorForErrno(errno)` sits immediately after a
      // syscall that just failed. What must not come back is the TOC read's
      // outcome being re-derived from errno instead of carried.
      expect(
        code,
        contains('if (const char* error = ReadWholeToc(fd, &toc)) {'),
      );
      expect(code, contains('result = Failure(error);'));
      expect(
        code,
        contains('if (first < 1 || last < first || last > 99) '
            'return kUnreadableError;'),
        reason: 'a nonsensical header is unreadable, not whatever errno held',
      );
    });

    test('a drive can only have one read in flight', () {
      // A Dart deadline cannot abort an ioctl, so without this each retry
      // would strand another worker thread and descriptor.
      expect(source(), contains('class DeviceClaim'));
      expect(source(), contains('ReadsInFlight()'));
      expect(source(), contains('if (!claim.held())'));
    });
  });
}
