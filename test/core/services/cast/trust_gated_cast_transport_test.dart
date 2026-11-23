import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/cast_media.dart';
import 'package:linthra/core/models/cast_playback_status.dart';
import 'package:linthra/core/models/cast_state.dart';
import 'package:linthra/core/models/cast_volume.dart';
import 'package:linthra/core/services/cast/cast_containment.dart';
import 'package:linthra/core/services/cast/cast_receiver_pinning.dart';
import 'package:linthra/core/services/cast/cast_receiver_trust.dart';
import 'package:linthra/core/services/cast/cast_transport.dart';
import 'package:linthra/core/services/cast/trust_gated_cast_transport.dart';

/// The receiver-trust boundary: no verified identity, no session, no media
/// ([#575](https://github.com/TheZupZup/Linthra/issues/575)).
///
/// Casting is still withheld from production — nothing here restores it, and the
/// shipped authenticator refuses every receiver. What these tests are for is the
/// half of the restoration that can be proved without a device: that the failure
/// cases a real handshake will hit (a refusal, a device answering for another
/// device, a check that never finishes, a session that dies mid-handshake) all
/// end the same way, with the session closed and nothing handed over.
///
/// Interoperability with real receivers is the other half, and it cannot be
/// faked here: it needs supported hardware and the reviewed implementation. The
/// scenarios for it are in docs/design/cast-receiver-trust.md and, in detail, the
/// private advisory.
void main() {
  const CastDevice speaker = CastDevice(id: 'speaker-1', name: 'Kitchen');
  const CastDevice other = CastDevice(id: 'speaker-2', name: 'Bedroom');

  final CastMedia media = CastMedia(
    url: Uri.parse('https://example.test/stream?api_key=secret-token'),
    contentType: 'audio/mpeg',
    title: 'Track',
  );

  TrustGatedCastTransport gate(
    _FakeTransport transport, {
    CastReceiverAuthenticator? authenticator,
    CastReceiverPinStore? pins,
    Duration timeout = const Duration(milliseconds: 50),
    Duration pinTimeout = const Duration(milliseconds: 50),
    Duration cleanupTimeout = const Duration(milliseconds: 50),
  }) {
    return TrustGatedCastTransport(
      delegate: transport,
      authenticator: authenticator ?? _AcceptingAuthenticator(),
      pins: pins,
      authenticationTimeout: timeout,
      pinTimeout: pinTimeout,
      cleanupTimeout: cleanupTimeout,
    );
  }

  group('a receiver that proves itself', () {
    test('gets a session, and media reaches it', () async {
      final _FakeTransport transport = _FakeTransport();

      final CastSessionHandle session = await gate(transport).connect(speaker);
      await session.loadMedia(media);

      expect(transport.session.loaded, <CastMedia>[media]);
      expect(transport.session.closed, isFalse);
      expect(await session.readyStream.first, isTrue);
    });

    test('every other command still reaches the receiver', () async {
      final _FakeTransport transport = _FakeTransport();

      final CastSessionHandle session = await gate(transport).connect(speaker);
      await session.play();
      await session.pause();
      await session.seek(const Duration(seconds: 12));
      await session.setVolume(0.4);
      await session.setMuted(true);
      await session.requestStatus();

      expect(transport.session.playCount, 1);
      expect(transport.session.pauseCount, 1);
      expect(transport.session.seeks, <Duration>[const Duration(seconds: 12)]);
      expect(transport.session.volumes, <double>[0.4]);
      expect(transport.session.mutes, <bool>[true]);
      expect(transport.session.statusRequests, 1);
    });
  });

  group('a receiver that does not prove itself', () {
    Future<CastReceiverTrustException> refusal(
      _FakeTransport transport, {
      required CastReceiverAuthenticator authenticator,
    }) async {
      try {
        await gate(transport, authenticator: authenticator).connect(speaker);
      } on CastReceiverTrustException catch (error) {
        return error;
      }
      fail('connect() returned a session for an unverified receiver.');
    }

    test('the shipped authenticator refuses every device', () async {
      final _FakeTransport transport = _FakeTransport();

      final CastReceiverTrustException error = await refusal(
        transport,
        authenticator: const UnverifiedCastReceiverAuthenticator(),
      );

      expect(error.kind, CastTrustFailureKind.unsupported);
      expect(transport.session.closed, isTrue);
      expect(transport.session.loaded, isEmpty);
    });

    test('a rejected handshake closes the session and loads nothing', () async {
      final _FakeTransport transport = _FakeTransport();

      final CastReceiverTrustException error = await refusal(
        transport,
        authenticator: const _RefusingAuthenticator(),
      );

      expect(error.kind, CastTrustFailureKind.rejected);
      expect(transport.session.closed, isTrue);
      expect(transport.session.loaded, isEmpty);
    });

    test('a device that authenticates as another device is refused', () async {
      final _FakeTransport transport = _FakeTransport();

      // The receiver proves an identity — just not the one the user picked.
      final CastReceiverTrustException error = await refusal(
        transport,
        authenticator: _AcceptingAuthenticator(as: other),
      );

      expect(error.kind, CastTrustFailureKind.identityMismatch);
      expect(transport.session.closed, isTrue);
      expect(transport.session.loaded, isEmpty);
    });

    test('a proof made over another connection is refused', () async {
      final _FakeTransport transport = _FakeTransport();

      // The right device, authenticated somewhere else. Cast's device
      // authentication is a property of a connection, so a proof from another
      // one says nothing about the socket the stream would go to.
      final CastReceiverTrustException error = await refusal(
        transport,
        authenticator: _AcceptingAuthenticator(over: _FakeHandle()),
      );

      expect(error.kind, CastTrustFailureKind.identityMismatch);
      expect(transport.session.closed, isTrue);
      expect(transport.session.loaded, isEmpty);
    });

    test('a session that drops mid-handshake is an unfinished check', () async {
      final _FakeTransport transport = _FakeTransport();

      // Ready, then not: the receiver went away while it was being checked.
      // (A `false` before the first `true` is only "not ready yet" — the
      // receiver's media app is still launching — and must not fail the check.)
      final Future<CastSessionHandle> connecting = gate(
        transport,
        authenticator: _HangingAuthenticator(),
        timeout: const Duration(seconds: 30),
      ).connect(speaker);
      await pumpEventQueue();
      transport.session.drop();

      await expectLater(
        connecting,
        throwsA(isA<CastReceiverTrustException>().having(
          (CastReceiverTrustException e) => e.kind,
          'kind',
          CastTrustFailureKind.incomplete,
        )),
      );
      expect(transport.session.loaded, isEmpty);
    });

    test('an authentication that never finishes expires', () async {
      final _FakeTransport transport = _FakeTransport();

      final CastReceiverTrustException error = await refusal(
        transport,
        authenticator: _HangingAuthenticator(),
      );

      expect(error.kind, CastTrustFailureKind.incomplete);
      expect(transport.session.closed, isTrue);
      expect(transport.session.loaded, isEmpty);
    });

    test('a session that dies mid-handshake is an unfinished check', () async {
      final _FakeTransport transport = _FakeTransport();
      final _HangingAuthenticator hanging = _HangingAuthenticator();

      // Long timeout: the refusal must come from the session ending, not from
      // the clock running out.
      final Future<CastSessionHandle> connecting = gate(
        transport,
        authenticator: hanging,
        timeout: const Duration(seconds: 30),
      ).connect(speaker);
      await pumpEventQueue();
      transport.session.end();

      await expectLater(
        connecting,
        throwsA(isA<CastReceiverTrustException>().having(
          (CastReceiverTrustException e) => e.kind,
          'kind',
          CastTrustFailureKind.incomplete,
        )),
      );
      expect(transport.session.loaded, isEmpty);
    });

    test('an authenticator that throws before returning a future is refused',
        () async {
      // A method satisfying the interface may throw synchronously. That has to
      // land on the same refusal, and the same cleanup, as any other failure.
      final _FakeTransport transport = _FakeTransport();

      final CastReceiverTrustException error = await refusal(
        transport,
        authenticator: const _SynchronouslyThrowingAuthenticator(),
      );

      expect(error.kind, CastTrustFailureKind.rejected);
      expect(transport.session.closed, isTrue);
      expect(transport.session.loaded, isEmpty);
    });

    test('a typed failure keeps its kind but not its words', () async {
      // An authenticator could build its message from something the receiver
      // said. The gate owns the wording, so only the kind survives.
      final _FakeTransport transport = _FakeTransport();

      final CastReceiverTrustException error = await refusal(
        transport,
        authenticator: const _LeakyAuthenticator(),
      );

      expect(error.kind, CastTrustFailureKind.rejected);
      expect(error.message, isNot(contains('sha256:de:ad:be:ef')));
      expect(error.message, isNot(contains('CN=Some Receiver')));
      expect(transport.session.closed, isTrue);
    });

    test('an authenticator that throws something else is still a refusal',
        () async {
      final _FakeTransport transport = _FakeTransport();

      final CastReceiverTrustException error = await refusal(
        transport,
        authenticator: const _ExplodingAuthenticator(),
      );

      expect(error.kind, CastTrustFailureKind.rejected);
      // The thrown detail does not become user-facing copy: a handshake error
      // can carry anything, including material from the receiver.
      expect(error.message, isNot(contains('challenge')));
      expect(error.message, isNot(contains('nonce-')));
    });

    test('a subscription that will not cancel still lets the refusal out',
        () async {
      // Cancelling a subscription can wait on the stream's own teardown. If the
      // delegate stalls there, the refusal must still come back rather than
      // leaving the caller connecting forever.
      final _FakeTransport transport = _FakeTransport()
        ..session.cancelHangs = true;

      final CastReceiverTrustException error = await refusal(
        transport,
        authenticator: const _RefusingAuthenticator(),
      );

      expect(error.kind, CastTrustFailureKind.rejected);
      expect(transport.session.loaded, isEmpty);
    });

    test('a receiver that will not close at all still gets refused', () async {
      // Cleanup is best-effort on a path that has already failed: a receiver
      // that accepts the close and then goes quiet must not leave the caller
      // stuck in "connecting" on a session that failed its check.
      final _FakeTransport transport = _FakeTransport()
        ..session.closeHangs = true;

      final CastReceiverTrustException error = await refusal(
        transport,
        authenticator: const _RefusingAuthenticator(),
      );

      expect(error.kind, CastTrustFailureKind.rejected);
      expect(transport.session.loaded, isEmpty);
    });

    test('a close that throws before returning still gets refused', () async {
      // An implementation may throw before it ever returns a future. Cleanup
      // started outside the guarded region would replace the refusal the caller
      // is already carrying.
      final _FakeTransport transport = _FakeTransport()
        ..session.closeThrowsSynchronously = true;

      final CastReceiverTrustException error = await refusal(
        transport,
        authenticator: const _RefusingAuthenticator(),
      );

      expect(error.kind, CastTrustFailureKind.rejected);
      expect(transport.session.loaded, isEmpty);
    });

    test('a receiver that will not close cleanly still gets refused', () async {
      final _FakeTransport transport = _FakeTransport()
        ..session.closeError = StateError('socket already gone');

      final CastReceiverTrustException error = await refusal(
        transport,
        authenticator: const _RefusingAuthenticator(),
      );

      expect(error.kind, CastTrustFailureKind.rejected);
      expect(transport.session.loaded, isEmpty);
    });
  });

  group('the boundary itself', () {
    test('containment refuses before trust is even asked about', () async {
      // The gate is not a second route to a receiver: a contained transport
      // fails first, and no handshake is attempted.
      final _FakeTransport transport = _FakeTransport()
        ..connectError = CastContainmentError('connecting');
      final _AcceptingAuthenticator authenticator = _AcceptingAuthenticator();

      await expectLater(
        gate(transport, authenticator: authenticator).connect(speaker),
        throwsA(isA<CastContainmentError>()),
      );
      expect(authenticator.calls, isEmpty);
    });

    test('discovery passes through, refusals and all', () async {
      final _FakeTransport transport = _FakeTransport();

      expect(
        await gate(transport).discover(const Duration(seconds: 1)),
        <CastDevice>[speaker],
      );

      transport.discoverError = CastContainmentError('discovery');
      await expectLater(
        gate(transport).discover(const Duration(seconds: 1)),
        throwsA(isA<CastContainmentError>()),
      );
    });

    test('trust does not survive the receiver dropping the session', () async {
      final _FakeTransport transport = _FakeTransport();

      final CastSessionHandle session = await gate(transport).connect(speaker);
      // Let the wrapper's lifetime listener attach (the handle replays its
      // readiness to it) before the receiver goes away.
      await pumpEventQueue();
      transport.session.drop();
      await pumpEventQueue();

      // The connection the proof was made over is gone, so the handoff refuses
      // even though nobody has called close() yet — a track resolution that
      // started before the drop must not still reach a dead receiver.
      await expectLater(
        session.loadMedia(media),
        throwsA(isA<CastReceiverTrustException>().having(
          (CastReceiverTrustException e) => e.kind,
          'kind',
          CastTrustFailureKind.incomplete,
        )),
      );
      expect(transport.session.loaded, isEmpty);
    });

    test('a drop between the check and the handoff still revokes trust',
        () async {
      // The handshake sees the session go ready; it drops in the gap before the
      // wrapper subscribes, so all the wrapper is replayed is that latest
      // `false`. Read naively that looks like "not ready yet" — it is not.
      final _FakeTransport transport = _FakeTransport();

      final CastSessionHandle session = await gate(
        transport,
        authenticator: _AcceptingAuthenticator(
          after: const Duration(milliseconds: 5),
        ),
      ).connect(speaker);
      transport.session.dropSilently();
      await pumpEventQueue();

      await expectLater(
        session.loadMedia(media),
        throwsA(isA<CastReceiverTrustException>()),
      );
      expect(transport.session.loaded, isEmpty);
    });

    test('a readiness error ends the session instead of escaping', () async {
      // An error on the delegate's readiness stream must not reach the service
      // as an unhandled async error: it becomes a clean "not ready" so the
      // ordinary session-lost teardown runs.
      final _FakeTransport transport = _FakeTransport();

      final CastSessionHandle session = await gate(transport).connect(speaker);
      final Future<List<bool>> readiness = session.readyStream.toList();
      await pumpEventQueue();
      transport.session.failReadiness(StateError('socket blew up'));

      expect(await readiness, <bool>[true, false]);
      await expectLater(
        session.loadMedia(media),
        throwsA(isA<CastReceiverTrustException>()),
      );
    });

    test('every receiver command refuses once trust is gone', () async {
      // Not just the media handoff: after the proved connection ends, the
      // delegate may have reconnected underneath, and this session's proof says
      // nothing about that one.
      final _FakeTransport transport = _FakeTransport();

      final CastSessionHandle session = await gate(transport).connect(speaker);
      await pumpEventQueue();
      transport.session.drop();
      await pumpEventQueue();

      for (final Future<void> Function() command in <Future<void> Function()>[
        () => session.loadMedia(media),
        session.play,
        session.pause,
        () => session.seek(const Duration(seconds: 3)),
        () => session.setVolume(0.5),
        () => session.setMuted(true),
        session.requestStatus,
      ]) {
        await expectLater(
          command(),
          throwsA(isA<CastReceiverTrustException>()),
        );
      }

      expect(transport.session.loaded, isEmpty);
      expect(transport.session.playCount, 0);
      expect(transport.session.pauseCount, 0);
      expect(transport.session.seeks, isEmpty);
      expect(transport.session.volumes, isEmpty);
      expect(transport.session.mutes, isEmpty);
      expect(transport.session.statusRequests, 0);

      // Teardown still works: closing an untrusted session is exactly what the
      // caller should still be able to do.
      await session.close();
      expect(transport.session.closed, isTrue);
    });

    test('closing returns even when the receiver stalls', () async {
      // Teardown that never finishes would keep DefaultCastService from
      // reaching its idle state, so the next connection could never start.
      final _FakeTransport transport = _FakeTransport();

      final CastSessionHandle session = await gate(transport).connect(speaker);
      transport.session.closeHangs = true;

      await session.close();

      expect(transport.session.closed, isTrue);
      await expectLater(
        session.loadMedia(media),
        throwsA(isA<CastReceiverTrustException>()),
      );
    });

    test('trust does not survive the session being closed', () async {
      final _FakeTransport transport = _FakeTransport();

      final CastSessionHandle session = await gate(transport).connect(speaker);
      await session.close();

      await expectLater(
        session.loadMedia(media),
        throwsA(isA<CastReceiverTrustException>().having(
          (CastReceiverTrustException e) => e.kind,
          'kind',
          CastTrustFailureKind.incomplete,
        )),
      );
      expect(transport.session.loaded, isEmpty);
      expect(await session.readyStream.first, isFalse);
    });

    test('no refusal carries anything from the handshake', () async {
      for (final CastReceiverAuthenticator authenticator
          in <CastReceiverAuthenticator>[
        const UnverifiedCastReceiverAuthenticator(),
        const _RefusingAuthenticator(),
        const _ExplodingAuthenticator(),
        const _LeakyAuthenticator(),
        _AcceptingAuthenticator(as: other),
        _HangingAuthenticator(),
      ]) {
        final _FakeTransport transport = _FakeTransport();
        String message = '';
        try {
          await gate(transport, authenticator: authenticator).connect(speaker);
        } on CastReceiverTrustException catch (error) {
          message = error.message.toLowerCase();
        }

        expect(message, isNotEmpty);
        for (final String leak in <String>[
          'certificate',
          'challenge',
          'signature',
          'nonce',
          'token',
          'key',
          'fingerprint',
          'sha256',
        ]) {
          expect(message, isNot(contains(leak)),
              reason: '${authenticator.runtimeType} leaks "$leak"');
        }
      }
    });
  });

  group('the receiver has to stay the same device', () {
    // Cast device authentication proves the peer holds a genuine receiver
    // certificate. It does not say which genuine receiver, and discovery, being
    // a friendly name on a LAN, says nothing at all. Pinning is what turns "a
    // real Cast device" into "the one this entry has always been".

    test('the first receiver a device presents is remembered', () async {
      final _FakeTransport transport = _FakeTransport();
      final InMemoryCastReceiverPinStore pins = InMemoryCastReceiverPinStore();

      await gate(transport, pins: pins).connect(speaker);

      expect(pins.pins[speaker.id], 'sha256aabb');
    });

    test('the same receiver connects again', () async {
      final InMemoryCastReceiverPinStore pins = InMemoryCastReceiverPinStore();

      await gate(_FakeTransport(), pins: pins).connect(speaker);
      final _FakeTransport again = _FakeTransport();
      final CastSessionHandle session =
          await gate(again, pins: pins).connect(speaker);
      await session.loadMedia(media);

      expect(again.session.loaded, <CastMedia>[media]);
    });

    test('a different receiver on the same entry is refused', () async {
      final InMemoryCastReceiverPinStore pins = InMemoryCastReceiverPinStore();
      await gate(_FakeTransport(), pins: pins).connect(speaker);

      final _FakeTransport impostor = _FakeTransport();
      await expectLater(
        gate(
          impostor,
          pins: pins,
          authenticator: _AcceptingAuthenticator(fingerprint: 'sha256:cc:dd'),
        ).connect(speaker),
        throwsA(isA<CastReceiverTrustException>().having(
          (CastReceiverTrustException e) => e.kind,
          'kind',
          CastTrustFailureKind.changedReceiver,
        )),
      );

      expect(impostor.session.closed, isTrue);
      expect(impostor.session.loaded, isEmpty);
      // The pin is evidence, not a cache: a device that failed the check does
      // not get to replace what it failed against.
      expect(pins.pins[speaker.id], 'sha256aabb');
    });

    test('the refusal says what the user can do, and nothing else', () async {
      final InMemoryCastReceiverPinStore pins = InMemoryCastReceiverPinStore();
      await gate(_FakeTransport(), pins: pins).connect(speaker);

      Object? thrown;
      try {
        await gate(
          _FakeTransport(),
          pins: pins,
          authenticator: _AcceptingAuthenticator(fingerprint: 'sha256:cc:dd'),
        ).connect(speaker);
      } catch (error) {
        thrown = error;
      }

      final String message = (thrown! as CastReceiverTrustException).message;
      expect(message, contains('forget it'));
      expect(message, isNot(contains('sha256')));
      expect(message, isNot(contains('aa:bb')));
      expect(message, isNot(contains('cc:dd')));
    });

    test('forgetting a device lets the next receiver pin', () async {
      final InMemoryCastReceiverPinStore pins = InMemoryCastReceiverPinStore();
      await gate(_FakeTransport(), pins: pins).connect(speaker);

      // The replaced-my-speaker path, and the only one: deliberate, from the
      // user, never something the trust check does to recover from a mismatch.
      await pins.forget(speaker.id);
      final _FakeTransport replacement = _FakeTransport();
      await gate(
        replacement,
        pins: pins,
        authenticator: _AcceptingAuthenticator(fingerprint: 'sha256:cc:dd'),
      ).connect(speaker);

      expect(pins.pins[speaker.id], 'sha256ccdd');
      expect(replacement.session.closed, isFalse);
    });

    test('how a fingerprint is written does not make it another device',
        () async {
      final InMemoryCastReceiverPinStore pins = InMemoryCastReceiverPinStore();
      await gate(_FakeTransport(), pins: pins).connect(speaker);

      final _FakeTransport again = _FakeTransport();
      await gate(
        again,
        pins: pins,
        authenticator: _AcceptingAuthenticator(fingerprint: '  SHA256: AA:BB '),
      ).connect(speaker);

      expect(again.session.closed, isFalse);
    });

    test('a base64url digest keeps every character that carries meaning',
        () async {
      // Normalising drops colons and whitespace, never `-` or `_`: those are
      // digits of a base64url digest, and dropping them would let two different
      // fingerprints compare equal.
      final InMemoryCastReceiverPinStore pins = InMemoryCastReceiverPinStore();
      await gate(
        _FakeTransport(),
        pins: pins,
        authenticator: _AcceptingAuthenticator(fingerprint: 'ab-cd_ef'),
      ).connect(speaker);

      final _FakeTransport impostor = _FakeTransport();
      await expectLater(
        gate(
          impostor,
          pins: pins,
          authenticator: _AcceptingAuthenticator(fingerprint: 'abcdef'),
        ).connect(speaker),
        throwsA(isA<CastReceiverTrustException>().having(
          (CastReceiverTrustException e) => e.kind,
          'kind',
          CastTrustFailureKind.changedReceiver,
        )),
      );

      expect(impostor.session.closed, isTrue);
    });

    test('each device is pinned on its own', () async {
      final InMemoryCastReceiverPinStore pins = InMemoryCastReceiverPinStore();
      await gate(_FakeTransport(), pins: pins).connect(speaker);

      final _FakeTransport bedroom = _FakeTransport();
      await gate(
        bedroom,
        pins: pins,
        authenticator: _AcceptingAuthenticator(fingerprint: 'sha256:cc:dd'),
      ).connect(other);

      expect(pins.pins[speaker.id], 'sha256aabb');
      expect(pins.pins[other.id], 'sha256ccdd');
      expect(bedroom.session.closed, isFalse);
    });

    test('an identity with nothing to pin is refused', () async {
      // A fingerprint that normalises to nothing would match every receiver
      // forever, so it fails here rather than being written down.
      final _FakeTransport transport = _FakeTransport();
      final InMemoryCastReceiverPinStore pins = InMemoryCastReceiverPinStore();

      await expectLater(
        gate(
          transport,
          pins: pins,
          authenticator: _AcceptingAuthenticator(fingerprint: ' :: '),
        ).connect(speaker),
        throwsA(isA<CastReceiverTrustException>().having(
          (CastReceiverTrustException e) => e.kind,
          'kind',
          CastTrustFailureKind.rejected,
        )),
      );

      expect(pins.pins, isEmpty);
      expect(transport.session.closed, isTrue);
    });

    test('a store that cannot be read refuses instead of re-pinning', () async {
      // Otherwise breaking the store would be a way to erase the check.
      final _FakeTransport transport = _FakeTransport();

      await expectLater(
        gate(transport, pins: _BrokenPinStore(onRead: true)).connect(speaker),
        throwsA(isA<CastReceiverTrustException>().having(
          (CastReceiverTrustException e) => e.kind,
          'kind',
          CastTrustFailureKind.incomplete,
        )),
      );

      expect(transport.session.closed, isTrue);
      expect(transport.session.loaded, isEmpty);
    });

    test('a store that cannot be written refuses too', () async {
      // Handing out a session that was never recorded would leave the entry
      // unpinned, so whichever receiver answered next would become the pin.
      final _FakeTransport transport = _FakeTransport();

      await expectLater(
        gate(transport, pins: _BrokenPinStore(onWrite: true)).connect(speaker),
        throwsA(isA<CastReceiverTrustException>()),
      );

      expect(transport.session.closed, isTrue);
      expect(transport.session.loaded, isEmpty);
    });

    test('a store that never answers expires into a refusal', () async {
      final _FakeTransport transport = _FakeTransport();

      await expectLater(
        gate(
          transport,
          pins: _HangingPinStore(),
          pinTimeout: const Duration(milliseconds: 10),
        ).connect(speaker),
        throwsA(isA<CastReceiverTrustException>().having(
          (CastReceiverTrustException e) => e.kind,
          'kind',
          CastTrustFailureKind.incomplete,
        )),
      );

      expect(transport.session.closed, isTrue);
    });

    test('a write that did not take is not a pin', () async {
      // A store that accepts a write and keeps nothing would leave the entry
      // unpinned while the app believed it was pinned, so the next receiver to
      // answer would become the pin.
      final _FakeTransport transport = _FakeTransport();

      await expectLater(
        gate(transport, pins: _ForgetfulPinStore()).connect(speaker),
        throwsA(isA<CastReceiverTrustException>().having(
          (CastReceiverTrustException e) => e.kind,
          'kind',
          CastTrustFailureKind.incomplete,
        )),
      );

      expect(transport.session.closed, isTrue);
    });

    test('losing the race to pin is a refusal, not a pass', () async {
      // Two connections to the same entry can reach the empty pin together. The
      // store keeps whichever arrived first, so the other one has to notice it
      // is not the receiver that got recorded.
      final _FakeTransport transport = _FakeTransport();

      await expectLater(
        gate(transport, pins: _RacedPinStore('sha256ccdd')).connect(speaker),
        throwsA(isA<CastReceiverTrustException>().having(
          (CastReceiverTrustException e) => e.kind,
          'kind',
          CastTrustFailureKind.changedReceiver,
        )),
      );

      expect(transport.session.closed, isTrue);
      expect(transport.session.loaded, isEmpty);
    });

    test('a recorded pin is never quietly replaced', () async {
      final InMemoryCastReceiverPinStore pins = InMemoryCastReceiverPinStore();

      await pins.remember(speaker.id, 'sha256:aa:bb');
      await pins.remember(speaker.id, 'sha256:cc:dd');

      expect(pins.pins[speaker.id], 'sha256:aa:bb');
    });
  });

  group('CastReceiverIdentity', () {
    test('is bound to the device *and* the connection it was proved on', () {
      final _FakeHandle session = _FakeHandle();
      final _FakeHandle elsewhere = _FakeHandle();
      final CastReceiverIdentity identity = CastReceiverIdentity(
        deviceId: 'speaker-1',
        connection: session,
        fingerprint: 'sha256:aa:bb',
        model: 'Test Receiver',
      );

      expect(identity.matches(speaker, session), isTrue);
      // Right device, wrong connection: a proof made somewhere else says
      // nothing about the socket the media would go to.
      expect(identity.matches(speaker, elsewhere), isFalse);
      expect(identity.matches(other, session), isFalse);
    });

    test('two proofs are only equal if they agree on all of it', () {
      final _FakeHandle session = _FakeHandle();
      final CastReceiverIdentity identity = CastReceiverIdentity(
        deviceId: 'speaker-1',
        connection: session,
        fingerprint: 'sha256:aa:bb',
      );

      expect(
        identity,
        CastReceiverIdentity(
          deviceId: 'speaker-1',
          connection: session,
          fingerprint: 'sha256:aa:bb',
        ),
      );
      expect(
        identity,
        isNot(CastReceiverIdentity(
          deviceId: 'speaker-1',
          connection: _FakeHandle(),
          fingerprint: 'sha256:aa:bb',
        )),
      );
      expect(
        identity,
        isNot(CastReceiverIdentity(
          deviceId: 'speaker-1',
          connection: session,
          fingerprint: 'sha256:cc:dd',
        )),
      );
    });
  });
}

/// A transport whose session, and whose failures, the test drives.
class _FakeTransport implements CastTransport {
  final _FakeHandle session = _FakeHandle();

  /// When set, [connect] throws it — how a contained transport behaves.
  Object? connectError;

  /// When set, [discover] throws it.
  Object? discoverError;

  @override
  Future<List<CastDevice>> discover(Duration timeout) async {
    if (discoverError != null) throw discoverError!;
    return const <CastDevice>[CastDevice(id: 'speaker-1', name: 'Kitchen')];
  }

  @override
  Future<CastSessionHandle> connect(CastDevice device) async {
    if (connectError != null) throw connectError!;
    return session;
  }
}

/// The same shape as the real handle: readiness replays to a late listener, and
/// every command is recorded so a test can assert nothing reached the receiver.
class _FakeHandle implements CastSessionHandle {
  final StreamController<bool> _ready = StreamController<bool>.broadcast();
  bool? _last = true;

  final List<CastMedia> loaded = <CastMedia>[];
  final List<Duration> seeks = <Duration>[];
  final List<double> volumes = <double>[];
  final List<bool> mutes = <bool>[];
  int playCount = 0;
  int pauseCount = 0;
  int statusRequests = 0;
  bool closed = false;

  /// When set, [close] throws it, so a failing teardown can be exercised.
  Object? closeError;

  /// When true, [close] never completes — a receiver that accepts the request
  /// and then says nothing.
  bool closeHangs = false;

  /// When true, [close] throws before it returns a future at all.
  bool closeThrowsSynchronously = false;

  /// When true, cancelling a [readyStream] subscription never completes — a
  /// stream whose own teardown stalls.
  bool cancelHangs = false;

  /// Reports the receiver's media app as up.
  void becomeReady() {
    _last = true;
    if (!_ready.isClosed) _ready.add(true);
  }

  /// Reports the session as no longer ready, the way a dropped receiver does,
  /// without closing the stream.
  void drop() {
    _last = false;
    if (!_ready.isClosed) _ready.add(false);
  }

  /// Drops without emitting, so only a later listener's replay carries it —
  /// the receiver going away between two subscriptions.
  void dropSilently() => _last = false;

  /// Fails the readiness stream, the way a broken socket does.
  void failReadiness(Object error) {
    if (!_ready.isClosed) _ready.addError(error);
  }

  /// Ends the session the way a receiver that went away entirely does.
  void end() {
    _last = false;
    if (!_ready.isClosed) {
      _ready.add(false);
      _ready.close();
    }
  }

  @override
  Stream<bool> get readyStream {
    if (!cancelHangs) return _replayed();
    final StreamController<bool> stalling = StreamController<bool>();
    stalling.onListen = () {
      if (_last != null) stalling.add(_last!);
    };
    stalling.onCancel = () => Completer<void>().future;
    return stalling.stream;
  }

  Stream<bool> _replayed() async* {
    if (_last != null) yield _last!;
    yield* _ready.stream;
  }

  @override
  Stream<CastPlaybackStatus> get statusStream =>
      const Stream<CastPlaybackStatus>.empty();

  @override
  Stream<CastVolume> get volumeStream => const Stream<CastVolume>.empty();

  @override
  Future<void> loadMedia(CastMedia media) async => loaded.add(media);

  @override
  Future<void> play() async => playCount++;

  @override
  Future<void> pause() async => pauseCount++;

  @override
  Future<void> seek(Duration position) async => seeks.add(position);

  @override
  Future<void> setVolume(double level) async => volumes.add(level);

  @override
  Future<void> setMuted(bool muted) async => mutes.add(muted);

  @override
  Future<void> requestStatus() async => statusRequests++;

  @override
  Future<void> close() {
    closed = true;
    // Deliberately not `async`: this throw happens before any future exists.
    if (closeThrowsSynchronously) throw StateError('socket already disposed');
    return _close();
  }

  Future<void> _close() async {
    if (closeHangs) return Completer<void>().future;
    if (closeError != null) throw closeError!;
    if (!_ready.isClosed) await _ready.close();
  }
}

/// Vouches for a receiver — as itself over its own session by default, or as
/// [as] / over [over] to model a device answering for another one, or a proof
/// made on a different connection.
class _AcceptingAuthenticator implements CastReceiverAuthenticator {
  _AcceptingAuthenticator({
    this.as,
    this.over,
    this.after,
    this.fingerprint = 'sha256:aa:bb',
  });

  final CastDevice? as;

  /// The digest the proof carries, so a test can play the same receiver twice
  /// or a different one the second time.
  final String fingerprint;

  /// When set, the check takes this long, so a test can be sure the handshake
  /// observed the session's readiness before it completes.
  final Duration? after;

  /// When set, the proof names this session instead of the one being
  /// authenticated — a receiver proved over some other connection.
  final CastSessionHandle? over;

  /// Every device this was asked about, so a test can show it was never asked.
  final List<String> calls = <String>[];

  @override
  Future<CastReceiverIdentity> authenticate(
    CastDevice device,
    CastSessionHandle session,
  ) async {
    calls.add(device.id);
    if (after != null) await Future<void>.delayed(after!);
    return CastReceiverIdentity(
      deviceId: (as ?? device).id,
      connection: over ?? session,
      fingerprint: fingerprint,
    );
  }
}

/// Answers, and fails the check.
class _RefusingAuthenticator implements CastReceiverAuthenticator {
  const _RefusingAuthenticator();

  @override
  Future<CastReceiverIdentity> authenticate(
    CastDevice device,
    CastSessionHandle session,
  ) async {
    throw const CastReceiverTrustException(
      "Linthra couldn't verify that device.",
      kind: CastTrustFailureKind.rejected,
    );
  }
}

/// Throws something that is not a trust failure, carrying detail that must not
/// reach the user.
class _ExplodingAuthenticator implements CastReceiverAuthenticator {
  const _ExplodingAuthenticator();

  @override
  Future<CastReceiverIdentity> authenticate(
    CastDevice device,
    CastSessionHandle session,
  ) async {
    throw StateError('challenge nonce-4711 rejected by peer certificate');
  }
}

/// Refuses with handshake material in its message — the mistake the gate has to
/// make harmless.
class _LeakyAuthenticator implements CastReceiverAuthenticator {
  const _LeakyAuthenticator();

  @override
  Future<CastReceiverIdentity> authenticate(
    CastDevice device,
    CastSessionHandle session,
  ) async {
    throw const CastReceiverTrustException(
      'Chain rejected: CN=Some Receiver, fingerprint sha256:de:ad:be:ef',
      kind: CastTrustFailureKind.rejected,
    );
  }
}

/// Throws before it ever returns a future.
class _SynchronouslyThrowingAuthenticator implements CastReceiverAuthenticator {
  const _SynchronouslyThrowingAuthenticator();

  @override
  Future<CastReceiverIdentity> authenticate(
    CastDevice device,
    CastSessionHandle session,
  ) =>
      throw StateError('no trust anchors configured');
}

/// Never answers, the way a receiver that accepts a socket and then goes quiet
/// does not.
class _HangingAuthenticator implements CastReceiverAuthenticator {
  @override
  Future<CastReceiverIdentity> authenticate(
    CastDevice device,
    CastSessionHandle session,
  ) =>
      Completer<CastReceiverIdentity>().future;
}

/// A pin store that fails the way a real one can: a corrupt file, a database
/// that will not open, a write that runs out of room.
class _BrokenPinStore implements CastReceiverPinStore {
  _BrokenPinStore({this.onRead = false, this.onWrite = false});

  final bool onRead;
  final bool onWrite;

  @override
  Future<String?> pinFor(String deviceId) async {
    if (onRead) throw StateError('pin store unreadable');
    return null;
  }

  @override
  Future<void> remember(String deviceId, String fingerprint) async {
    if (onWrite) throw StateError('pin store unwritable');
  }

  @override
  Future<void> forget(String deviceId) async {}
}

/// A pin store that never answers, so the refusal has to come from the clock.
class _HangingPinStore implements CastReceiverPinStore {
  @override
  Future<String?> pinFor(String deviceId) => Completer<String?>().future;

  @override
  Future<void> remember(String deviceId, String fingerprint) =>
      Completer<void>().future;

  @override
  Future<void> forget(String deviceId) async {}
}

/// A store that accepts a write and keeps nothing.
class _ForgetfulPinStore implements CastReceiverPinStore {
  @override
  Future<String?> pinFor(String deviceId) async => null;

  @override
  Future<void> remember(String deviceId, String fingerprint) async {}

  @override
  Future<void> forget(String deviceId) async {}
}

/// A store that looks empty, and by the time the write lands holds somebody
/// else's fingerprint: the shape of two connections pinning the same entry at
/// once, with the contract's refusal to overwrite deciding the winner.
class _RacedPinStore implements CastReceiverPinStore {
  _RacedPinStore(this.winner);

  final String winner;
  bool _read = false;

  @override
  Future<String?> pinFor(String deviceId) async {
    if (!_read) {
      _read = true;
      return null;
    }
    return winner;
  }

  @override
  Future<void> remember(String deviceId, String fingerprint) async {}

  @override
  Future<void> forget(String deviceId) async {}
}
