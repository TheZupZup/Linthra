import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/catalog/track_availability.dart';
import 'package:linthra/core/sources/source_availability.dart';

/// The resolver is where every combination of "what this device has" and "what
/// the server is doing" becomes one answer, including the combinations that are
/// hard to stage on screen (a rejected session with no copy, a probe still in
/// flight over a row that is already saved). Pinning them here keeps the widget
/// tests about pixels and the a11y labels rather than about state algebra.
void main() {
  TrackAvailabilityStatus resolve({
    bool isRemote = true,
    bool hasOfflineCopy = false,
    bool isExplicitDownload = false,
    SourceAvailability availability = SourceAvailability.available,
  }) {
    return resolveTrackAvailability(
      isRemote: isRemote,
      hasOfflineCopy: hasOfflineCopy,
      isExplicitDownload: isExplicitDownload,
      availability: availability,
    );
  }

  group('resolveTrackAvailability: on-device music', () {
    test('never has anything to report, whatever a server is doing', () {
      for (final SourceAvailability availability in SourceAvailability.values) {
        expect(
          resolve(isRemote: false, availability: availability),
          TrackAvailabilityStatus.none,
          reason: 'a file on this device has no server to be away from, so a '
              'server elsewhere has no business putting a glyph on its row',
        );
      }
    });
  });

  group('resolveTrackAvailability: the ordinary case stays quiet', () {
    test('a server-backed track on an answering server says nothing', () {
      expect(
        resolve(),
        TrackAvailabilityStatus.none,
        reason: 'an indicator lit on every ordinary row is one nobody reads',
      );
    });

    test('an unconfigured source is not a fault', () {
      expect(
        resolve(availability: SourceAvailability.notConfigured),
        TrackAvailabilityStatus.none,
        reason:
            'no server configured means no tracks from it, not a broken one',
      );
    });
  });

  group('resolveTrackAvailability: saved copies', () {
    test('an explicit download on an answering server reads as downloaded', () {
      expect(
        resolve(hasOfflineCopy: true, isExplicitDownload: true),
        TrackAvailabilityStatus.downloaded,
      );
    });

    test('a prefetched copy reads as cached, never as a download', () {
      expect(
        resolve(hasOfflineCopy: true),
        TrackAvailabilityStatus.cached,
        reason: 'the user never asked for it, and it can be evicted underneath '
            'them — calling it "Downloaded" would promise more than it can keep',
      );
    });

    test('a saved copy outranks a server that is away', () {
      for (final bool explicit in <bool>[true, false]) {
        for (final SourceAvailability down in <SourceAvailability>[
          SourceAvailability.unreachable,
          SourceAvailability.authenticationError,
        ]) {
          expect(
            resolve(
              hasOfflineCopy: true,
              isExplicitDownload: explicit,
              availability: down,
            ),
            TrackAvailabilityStatus.offlineCopy,
            reason: 'the server being down stops being the interesting fact '
                'once the row plays anyway; what matters is that it does',
          );
        }
      }
    });

    test('a saved copy outranks a probe still in flight', () {
      expect(
        resolve(
          hasOfflineCopy: true,
          isExplicitDownload: true,
          availability: SourceAvailability.checking,
        ),
        TrackAvailabilityStatus.downloaded,
        reason: 'we already know this plays; a pending probe adds nothing',
      );
    });
  });

  group('resolveTrackAvailability: no copy, so the server is the only way', () {
    test('an unreachable server reads as unavailable', () {
      expect(
        resolve(availability: SourceAvailability.unreachable),
        TrackAvailabilityStatus.unreachable,
      );
    });

    test('a rejected session reads differently from an unreachable server', () {
      expect(
        resolve(availability: SourceAvailability.authenticationError),
        TrackAvailabilityStatus.sessionRejected,
        reason: 'the fix is signing in again, not moving closer to the server',
      );
    });

    test('a probe in flight reads as checking, never as a failure', () {
      expect(
        resolve(availability: SourceAvailability.checking),
        TrackAvailabilityStatus.checking,
        reason: 'a slow answer is not a negative one, and the library is shown '
            'optimistically while we wait',
      );
    });
  });
}
