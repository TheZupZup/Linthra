import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/audio_cd.dart';
import 'package:linthra/core/models/optical_media.dart';
import 'package:linthra/core/services/optical/cdrom_toc_source.dart';
import 'package:linthra/core/services/optical/linux_audio_cd_toc_service.dart';

import 'cd_toc_fixtures.dart';

/// A [CdromTocSource] that answers from a script instead of from a drive.
class FakeCdromTocSource implements CdromTocSource {
  FakeCdromTocSource({
    this.toc,
    this.failure,
    this.hang = false,
    this.crash = false,
    this.supported = true,
  });

  final RawCdToc? toc;
  final CdromTocFailure? failure;
  final bool hang;
  final bool crash;
  final bool supported;

  final List<String> reads = <String>[];

  @override
  bool get isSupported => supported;

  @override
  Future<RawCdToc> readToc(String deviceNode) async {
    reads.add(deviceNode);
    if (hang) return Completer<RawCdToc>().future;
    if (crash) throw StateError('a source that broke its own contract');
    if (failure != null) throw CdromTocException(failure!);
    return toc!;
  }
}

OpticalDrive driveWithCd([String id = '/dev/sr0']) =>
    OpticalDrive(id: id, disc: OpticalDiscState.audioCd);

void main() {
  group('a readable audio CD', () {
    test('is described track by track', () async {
      final LinuxAudioCdTocService service = LinuxAudioCdTocService(
        source: FakeCdromTocSource(toc: sevenTrackAudioCd()),
        sandboxed: false,
      );

      final AudioCdInspection inspection = await service.inspect(driveWithCd());

      expect(inspection.status, AudioCdInspectionStatus.success);
      expect(inspection.disc!.tracks, hasLength(7));
      expect(inspection.disc!.driveId, '/dev/sr0');
      expect(inspection.disc!.discId, isNotNull);
    });

    test('is read from the drive it was asked about', () async {
      final FakeCdromTocSource source =
          FakeCdromTocSource(toc: sevenTrackAudioCd());
      final LinuxAudioCdTocService service =
          LinuxAudioCdTocService(source: source, sandboxed: false);

      await service.inspect(driveWithCd('/dev/sr2'));

      expect(source.reads, <String>['/dev/sr2']);
    });

    test('several drives are inspected independently', () async {
      final LinuxAudioCdTocService first = LinuxAudioCdTocService(
        source: FakeCdromTocSource(toc: sevenTrackAudioCd()),
        sandboxed: false,
      );
      final LinuxAudioCdTocService second = LinuxAudioCdTocService(
        source: FakeCdromTocSource(toc: singleTrackCd()),
        sandboxed: false,
      );

      final AudioCdInspection one =
          await first.inspect(driveWithCd('/dev/sr0'));
      final AudioCdInspection two =
          await second.inspect(driveWithCd('/dev/sr1'));

      expect(one.disc!.tracks, hasLength(7));
      expect(one.disc!.driveId, '/dev/sr0');
      expect(two.disc!.tracks, hasLength(1));
      expect(two.disc!.driveId, '/dev/sr1');
      expect(one.disc!.discId, isNot(two.disc!.discId));
    });

    test('a drive the snapshot called empty is still read', () async {
      // Detection cannot tell a damaged disc from an empty tray; only reading
      // the disc can, so the snapshot's state is not a veto.
      final FakeCdromTocSource source =
          FakeCdromTocSource(toc: sevenTrackAudioCd());
      final LinuxAudioCdTocService service =
          LinuxAudioCdTocService(source: source, sandboxed: false);

      final AudioCdInspection inspection = await service.inspect(
        const OpticalDrive(id: '/dev/sr0', disc: OpticalDiscState.empty),
      );

      expect(source.reads, <String>['/dev/sr0']);
      expect(inspection.status, AudioCdInspectionStatus.success);
    });
  });

  group('every failure is a value', () {
    Future<AudioCdInspectionStatus> statusFor(CdromTocFailure failure) async {
      final LinuxAudioCdTocService service = LinuxAudioCdTocService(
        source: FakeCdromTocSource(failure: failure),
        sandboxed: false,
      );
      return (await service.inspect(driveWithCd())).status;
    }

    test('an empty drive reports no disc', () async {
      expect(
        await statusFor(CdromTocFailure.noDisc),
        AudioCdInspectionStatus.noDisc,
      );
    });

    test('a disc removed during the read reports a changed disc', () async {
      expect(
        await statusFor(CdromTocFailure.discChanged),
        AudioCdInspectionStatus.discChanged,
      );
    });

    test('a drive that vanished reports an unavailable drive', () async {
      expect(
        await statusFor(CdromTocFailure.driveUnavailable),
        AudioCdInspectionStatus.driveUnavailable,
      );
    });

    test('a refused open reports permission denied', () async {
      expect(
        await statusFor(CdromTocFailure.permissionDenied),
        AudioCdInspectionStatus.permissionDenied,
      );
    });

    test('a disc that cannot be read reports unreadable', () async {
      expect(
        await statusFor(CdromTocFailure.unreadable),
        AudioCdInspectionStatus.unreadable,
      );
    });

    test('a backend that is not there reports unsupported', () async {
      expect(
        await statusFor(CdromTocFailure.unsupported),
        AudioCdInspectionStatus.unsupported,
      );
    });

    test('no failure ever carries a disc', () async {
      for (final CdromTocFailure failure in CdromTocFailure.values) {
        final LinuxAudioCdTocService service = LinuxAudioCdTocService(
          source: FakeCdromTocSource(failure: failure),
          sandboxed: false,
        );
        expect((await service.inspect(driveWithCd())).disc, isNull);
      }
    });

    test('a drive that never answers is given up on, not waited on', () async {
      final LinuxAudioCdTocService service = LinuxAudioCdTocService(
        source: FakeCdromTocSource(hang: true),
        sandboxed: false,
        readDeadline: const Duration(milliseconds: 20),
      );

      expect(
        (await service.inspect(driveWithCd())).status,
        AudioCdInspectionStatus.unreadable,
      );
    });

    test('a source that throws something else does not reach the caller',
        () async {
      final LinuxAudioCdTocService service = LinuxAudioCdTocService(
        source: FakeCdromTocSource(crash: true),
        sandboxed: false,
      );

      expect(
        (await service.inspect(driveWithCd())).status,
        AudioCdInspectionStatus.unreadable,
      );
    });
  });

  group('what the disc turns out to be', () {
    test('a data-only disc is not an audio CD', () async {
      final LinuxAudioCdTocService service = LinuxAudioCdTocService(
        source: FakeCdromTocSource(
          toc: tocOf(
            tracks: <RawCdTocTrack>[tocTrack(1, 0, data: true)],
            leadOutLba: 300000,
          ),
        ),
        sandboxed: false,
      );

      expect(
        (await service.inspect(driveWithCd())).status,
        AudioCdInspectionStatus.notAudioCd,
      );
    });

    test('a table of contents that contradicts itself is unreadable', () async {
      final LinuxAudioCdTocService service = LinuxAudioCdTocService(
        source: FakeCdromTocSource(
          toc: tocOf(
            tracks: <RawCdTocTrack>[tocTrack(1, 9000)],
            leadOutLba: 100,
          ),
        ),
        sandboxed: false,
      );

      expect(
        (await service.inspect(driveWithCd())).status,
        AudioCdInspectionStatus.unreadable,
      );
    });
  });

  group('what this build can do', () {
    test('a Flatpak build reads nothing and says so', () async {
      final FakeCdromTocSource source =
          FakeCdromTocSource(toc: sevenTrackAudioCd());
      final LinuxAudioCdTocService service =
          LinuxAudioCdTocService(source: source, sandboxed: true);

      expect(service.isSupported, isFalse);
      expect(
        (await service.inspect(driveWithCd())).status,
        AudioCdInspectionStatus.unsupported,
      );
      expect(source.reads, isEmpty);
    });

    test('a source that cannot read makes the service unsupported', () async {
      final LinuxAudioCdTocService service = LinuxAudioCdTocService(
        source: FakeCdromTocSource(supported: false),
        sandboxed: false,
      );

      expect(service.isSupported, isFalse);
      expect(
        (await service.inspect(driveWithCd())).status,
        AudioCdInspectionStatus.unsupported,
      );
    });

    test('a drive handle that is not an optical device node is refused',
        () async {
      final FakeCdromTocSource source =
          FakeCdromTocSource(toc: sevenTrackAudioCd());
      final LinuxAudioCdTocService service =
          LinuxAudioCdTocService(source: source, sandboxed: false);

      for (final String id in <String>[
        '/dev/sda',
        '/dev/sr0; rm -rf /',
        '/dev/../etc/passwd',
        'sr0',
        '',
        '/dev/sr',
      ]) {
        expect(
          (await service.inspect(OpticalDrive(
            id: id,
            disc: OpticalDiscState.audioCd,
          )))
              .status,
          AudioCdInspectionStatus.driveUnavailable,
          reason: id,
        );
      }
      expect(source.reads, isEmpty);
    });
  });
}
