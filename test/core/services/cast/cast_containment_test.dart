import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/cast_state.dart';
import 'package:linthra/core/services/cast/cast_containment.dart';
import 'package:linthra/core/services/cast/chromecast_cast_transport.dart';

/// The fail-closed half of the Cast security containment.
///
/// Production binds an inert service, so these paths are unreachable in a
/// shipped build — which is the point of testing them. They are the safety net
/// under the wiring: if the provider is ever reverted, injected around, or
/// restored early, the transport itself must still refuse to reach a device.
///
/// **A known gap.** The third layer — the session handle's own refusal — has no
/// test here: the handle is private and only [ChromecastCastTransport.connect]
/// hands one out, so a test cannot obtain one while contained. That layer is
/// therefore covered only by reading the code and by the marker check in
/// `scripts/check_cast_containment.py`, which is a source-pattern tripwire
/// rather than proof. It is a backstop behind two layers that *are* exercised
/// here and in test/app/production_cast_containment_test.dart, not the thing
/// containment rests on.
void main() {
  group('CastContainment', () {
    test('is active, and is a compile-time constant with no runtime switch',
        () {
      // A settable flag would be a second production path with none of the
      // review restoring casting requires. If this fails, casting was restored
      // — which must happen in a reviewed change that also authenticates the
      // receiver (see docs/features/cast.md), together with scripts/check_cast_containment.py.
      expect(CastContainment.isActive, isTrue);
    });

    test('the user-facing message explains the situation without leaking it',
        () {
      final String message = CastContainment.userMessage.toLowerCase();

      // Says casting is temporarily off, and reassures about the rest.
      expect(message, contains('casting'));
      expect(message, contains('temporarily'));

      // Carries nothing about the weakness itself: that stays private until
      // coordinated disclosure.
      for (final String leak in <String>[
        'token',
        'credential',
        'vulnerab',
        'exploit',
        'attack',
        'cve',
        'ghsa',
        'advisory',
      ]) {
        expect(message, isNot(contains(leak)), reason: 'leaks "$leak"');
      }
    });

    test('the contained state is unavailable and carries the message', () {
      expect(CastContainment.state.isAvailable, isFalse);
      expect(CastContainment.state.message, CastContainment.userMessage);
      expect(CastContainment.state.devices, isEmpty);
      expect(CastContainment.state.connectedDevice, isNull);
      expect(CastContainment.state.isCasting, isFalse);
    });
  });

  group('ChromecastCastTransport (contained)', () {
    test('refuses to discover receivers', () async {
      await expectLater(
        ChromecastCastTransport().discover(const Duration(seconds: 1)),
        throwsA(isA<CastContainmentError>()),
      );
    });

    test('refuses to connect, even to a device it was handed directly',
        () async {
      // Bypasses discovery entirely, the way a reverted provider or a stray
      // injection would: the refusal must not depend on discovery running.
      await expectLater(
        ChromecastCastTransport().connect(
          const CastDevice(id: 'receiver-1', name: 'Living room'),
        ),
        throwsA(isA<CastContainmentError>()),
      );
    });

    test('repeated attempts keep failing (no first-call-only guard)', () async {
      final ChromecastCastTransport transport = ChromecastCastTransport();
      for (int attempt = 0; attempt < 3; attempt++) {
        await expectLater(
          transport.discover(const Duration(milliseconds: 1)),
          throwsA(isA<CastContainmentError>()),
        );
        await expectLater(
          transport.connect(const CastDevice(id: 'r', name: 'Receiver')),
          throwsA(isA<CastContainmentError>()),
        );
      }
    });

    test('the refusal names no security detail', () {
      final Object error = CastContainmentError('a media handoff');
      final String text = error.toString().toLowerCase();

      expect(text, contains('contained'));
      for (final String leak in <String>[
        'token',
        'credential',
        'vulnerab',
        'ghsa',
        'advisory',
      ]) {
        expect(text, isNot(contains(leak)), reason: 'leaks "$leak"');
      }
    });
  });
}
