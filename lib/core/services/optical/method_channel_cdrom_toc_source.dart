import 'package:flutter/services.dart';

import '../../platform/host_platform.dart';
import 'cdrom_toc_source.dart';

/// Reads a disc's table of contents through Linthra's own Linux runner
/// channel (`linux/runner/optical_toc_channel.cc`).
///
/// ## Why the runner, and why the kernel's own ioctls
///
/// Reading a CD-DA table of contents means asking the drive, and on Linux the
/// only things that can ask are the kernel and a library that wraps it. The
/// kernel's answer is `CDROMREADTOCHDR` and `CDROMREADTOCENTRY` — two ioctls
/// that have been in `<linux/cdrom.h>` and stable for the whole life of the
/// interface, documented in `Documentation/userspace-api/ioctl/cdrom.rst`, and
/// available on every Linux Linthra runs on with no package to install. The
/// runner issues them on a worker thread, on a read-only file descriptor it
/// opened `O_NONBLOCK` so the drive is never woken into closing its own tray,
/// and hands the raw numbers back here. It calls nothing that writes, ejects,
/// locks or plays.
///
/// What it deliberately is not:
///
///  * **`dart:ffi` into libc or libcdio.** Linthra's own security guard
///    (`scripts/check_pr_security_surface.py`) rejects runtime FFI and dynamic
///    library loading outright, by a rule that approval cannot clear — see
///    `docs/pr-security-guard.md`. That is a deliberate property of this
///    codebase, not an obstacle to route around.
///  * **libcdio or libdiscid.** A native library, a build-system change on
///    every target, a licence to audit and a `.so` whose soname has moved
///    three times, to wrap two ioctls Linthra can issue itself. Reading their
///    *algorithms* — which is what `cd_disc_id.dart` does — costs none of
///    that.
///  * **Parsing `cd-info`, `cdparanoia` or `udevadm`.** Scraping
///    human-readable output from a subprocess, which the same guard blocks and
///    which a music player should not be doing anyway.
///
/// ## The platform half is the thin one
///
/// Everything with a rule in it — which tracks are playable, where each one
/// ends, what the CD-Text says, what the disc's identity is — happens in Dart,
/// over the plain numbers and raw bytes this class carries. The runner decides
/// nothing, which is what makes the feature testable without a drive.
class MethodChannelCdromTocSource implements CdromTocSource {
  const MethodChannelCdromTocSource({
    MethodChannel channel = _defaultChannel,
    HostPlatform? host,
  })  : _channel = channel,
        _host = host;

  /// Mirrors `kChannelName` in `linux/runner/optical_toc_channel.cc`;
  /// `test/tooling/optical_toc_channel_contract_test.dart` holds the two to
  /// the same string.
  static const String channelName =
      'io.github.thezupzup.linthra/linux_optical_toc';

  /// Mirrors `kReadTocMethod` and `kDeviceArgument` in the runner.
  static const String readTocMethod = 'readToc';
  static const String deviceArgument = 'device';

  /// The runner's error codes, mirrored. Anything else it could ever send is
  /// treated as [CdromTocFailure.unreadable], so a runner that grows a code
  /// this build has not heard of degrades to "that disc could not be read"
  /// rather than to an exception.
  static const String noDiscError = 'no_disc';
  static const String discChangedError = 'disc_changed';
  static const String unreadableError = 'unreadable';
  static const String driveUnavailableError = 'drive_unavailable';
  static const String permissionDeniedError = 'permission_denied';

  /// Reply keys, mirrored from the runner.
  static const String firstTrackKey = 'firstTrack';
  static const String lastTrackKey = 'lastTrack';
  static const String leadOutKey = 'leadOutLba';
  static const String tracksKey = 'tracks';
  static const String trackNumberKey = 'number';
  static const String trackLbaKey = 'lba';
  static const String trackControlKey = 'control';
  static const String cdTextKey = 'cdText';

  static const MethodChannel _defaultChannel = MethodChannel(channelName);

  final MethodChannel _channel;
  final HostPlatform? _host;

  @override
  bool get isSupported => (_host ?? HostPlatform.current) == HostPlatform.linux;

  @override
  Future<RawCdToc> readToc(String deviceNode) async {
    if (!isSupported) {
      throw const CdromTocException(
        CdromTocFailure.unsupported,
        'only the Linux runner registers the optical TOC channel',
      );
    }
    if (!isPlausibleOpticalDeviceNode(deviceNode)) {
      throw const CdromTocException(
        CdromTocFailure.driveUnavailable,
        'not an optical device node',
      );
    }

    final Map<Object?, Object?>? reply;
    try {
      reply = await _channel.invokeMethod<Map<Object?, Object?>>(
        readTocMethod,
        <String, Object?>{deviceArgument: deviceNode},
      );
    } on MissingPluginException {
      // A build whose runner predates the channel, or a `flutter test` host.
      // "This build cannot read discs" rather than "that disc is broken".
      throw const CdromTocException(
        CdromTocFailure.unsupported,
        'the Linux runner did not register the optical TOC channel',
      );
    } on PlatformException catch (error) {
      throw CdromTocException(_failureFor(error.code), error.code);
    }

    if (reply == null) {
      throw const CdromTocException(
        CdromTocFailure.unreadable,
        'empty reply',
      );
    }
    return _tocFrom(reply);
  }

  static CdromTocFailure _failureFor(String code) {
    switch (code) {
      case noDiscError:
        return CdromTocFailure.noDisc;
      case discChangedError:
        return CdromTocFailure.discChanged;
      case driveUnavailableError:
        return CdromTocFailure.driveUnavailable;
      case permissionDeniedError:
        return CdromTocFailure.permissionDenied;
      case unreadableError:
      default:
        return CdromTocFailure.unreadable;
    }
  }

  /// Decodes the runner's reply, refusing anything that is not exactly the
  /// shape agreed on.
  ///
  /// Strict rather than forgiving. A missing or wrongly-typed field means the
  /// two halves of this build disagree, and the one thing that must not happen
  /// then is a plausible-looking track list computed from a default: a
  /// lead-out that silently reads as zero would make every track on the disc
  /// zero-length. Refusing produces "that disc could not be read", which is
  /// wrong in a way somebody notices.
  static RawCdToc _tocFrom(Map<Object?, Object?> reply) {
    final Object? entries = reply[tracksKey];
    if (entries is! List<Object?>) {
      throw const CdromTocException(CdromTocFailure.unreadable, 'no tracks');
    }
    final List<RawCdTocTrack> tracks = <RawCdTocTrack>[];
    for (final Object? entry in entries) {
      if (entry is! Map<Object?, Object?>) {
        throw const CdromTocException(
          CdromTocFailure.unreadable,
          'malformed track entry',
        );
      }
      tracks.add(
        RawCdTocTrack(
          number: _int(entry[trackNumberKey], trackNumberKey),
          startLba: _int(entry[trackLbaKey], trackLbaKey),
          control: _int(entry[trackControlKey], trackControlKey),
        ),
      );
    }
    final Object? cdText = reply[cdTextKey];
    return RawCdToc(
      firstTrack: _int(reply[firstTrackKey], firstTrackKey),
      lastTrack: _int(reply[lastTrackKey], lastTrackKey),
      leadOutLba: _int(reply[leadOutKey], leadOutKey),
      cdText: cdText is Uint8List ? cdText : null,
      tracks: tracks,
    );
  }

  static int _int(Object? value, String field) {
    if (value is int) return value;
    throw CdromTocException(CdromTocFailure.unreadable, 'bad field: $field');
  }
}
