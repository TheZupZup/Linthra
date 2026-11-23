import 'dart:async';

import '../../models/cast_media.dart';
import '../../models/cast_playback_status.dart';
import '../../models/cast_state.dart';
import '../../models/cast_volume.dart';
import 'cast_receiver_pinning.dart';
import 'cast_receiver_trust.dart';
import 'cast_transport.dart';

/// The readiness boundary casting has to cross before a receiver gets anything:
/// a [CastTransport] that hands out a session only once the receiver on the
/// other end has proved, *on that session*, that it is the device the user
/// picked.
///
/// It is a decorator, not a transport: it opens no socket and speaks no
/// protocol. That is deliberate. The rule — *no verified identity, no session,
/// no media* — is policy, and policy that lives inside an I/O adapter can only
/// be tested on a device. Here it is a few dozen lines of orchestration over a
/// [CastTransport] and a [CastReceiverAuthenticator], so every failure the
/// boundary must survive (a refusal, a device answering for another device, a
/// proof made over some other connection, an authentication that never
/// finishes, a session that dies mid-handshake or after it) is a unit test
/// rather than a code review.
///
/// It also narrows what authentication can honestly claim. A Cast handshake
/// proves the peer is *a* genuine receiver, not that it is the receiver the user
/// meant, so the gate additionally pins each device to the certificate it first
/// proved itself with ([CastReceiverPinStore]) and refuses a device that comes
/// back as different hardware. See docs/design/cast-hardened.md.
///
/// It also owns what the user is told. A refusal keeps its
/// [CastTrustFailureKind] and nothing else: the message the sheet shows is
/// written here, so no message an authenticator produces — which may have been
/// built from something the receiver said — can reach the UI.
///
/// **This does not restore casting.** Nothing in production builds a live
/// transport while the security containment holds, and the shipped
/// [UnverifiedCastReceiverAuthenticator] refuses every receiver anyway. This is
/// the boundary the reviewed restoration
/// ([#575](https://github.com/TheZupZup/Linthra/issues/575)) has to plug a real
/// authenticator into, built and tested ahead of it rather than alongside it.
///
/// **Containment still comes first.** Trust is checked *after* the delegate
/// opens the session, because a receiver can only prove itself over a
/// connection. So a contained transport refuses before this class ever asks
/// about identity, and this class never becomes a second way to reach a device
/// that the transport itself would not reach.
class TrustGatedCastTransport implements CastTransport {
  TrustGatedCastTransport({
    required CastTransport delegate,
    CastReceiverAuthenticator authenticator =
        const UnverifiedCastReceiverAuthenticator(),
    CastReceiverPinStore? pins,
    Duration authenticationTimeout = const Duration(seconds: 10),
    Duration pinTimeout = const Duration(seconds: 5),
    Duration cleanupTimeout = const Duration(seconds: 5),
  })  : _delegate = delegate,
        _authenticator = authenticator,
        _pins = pins ?? InMemoryCastReceiverPinStore(),
        _authenticationTimeout = authenticationTimeout,
        _pinTimeout = pinTimeout,
        _cleanupTimeout = cleanupTimeout;

  final CastTransport _delegate;
  final CastReceiverAuthenticator _authenticator;

  /// Which receiver each device is known to be. Defaulted rather than optional
  /// on purpose: leaving it out shortens how long the app remembers, it never
  /// turns the check off. A restoration is expected to pass a persistent store.
  final CastReceiverPinStore _pins;

  /// How long a receiver has to prove itself. A handshake that hangs is not a
  /// slow success: it expires as [CastTrustFailureKind.incomplete], the session
  /// is closed, and nothing is handed over.
  final Duration _authenticationTimeout;

  /// How long the pin store gets to answer. Reading which receiver a device is
  /// supposed to be sits on the connect path, so a store that hangs (a slow
  /// disk, a lock someone else is holding) must expire into a refusal rather
  /// than leave the user watching "connecting" forever.
  final Duration _pinTimeout;

  /// How long the refused session gets to close before the refusal is returned
  /// anyway. Closing is cleanup on a path that has already failed, so an
  /// unresponsive receiver must not be able to hold the refusal back — the
  /// caller would sit in "connecting" forever on the strength of a socket that
  /// failed its check.
  final Duration _cleanupTimeout;

  /// Discovery is not a trust boundary — finding a name on the LAN says nothing
  /// about who owns it — so it passes straight through, containment guards and
  /// all. Trust is established per connection, on the connection.
  @override
  Future<List<CastDevice>> discover(Duration timeout) =>
      _delegate.discover(timeout);

  @override
  Future<CastSessionHandle> connect(CastDevice device) async {
    final CastSessionHandle session = await _delegate.connect(device);

    final _Authentication proof;
    try {
      proof = await _authenticate(device, session);
    } catch (_) {
      // Every failure path closes the session it was handed. A connected but
      // unauthenticated receiver is exactly what must not survive this method,
      // including when the failure is a timeout or a dropped connection.
      await _close(session);
      rethrow;
    }

    if (!proof.identity.matches(device, session)) {
      await _close(session);
      throw CastReceiverTrustException(
        _messageFor(CastTrustFailureKind.identityMismatch),
        kind: CastTrustFailureKind.identityMismatch,
      );
    }

    try {
      await _checkPin(device, proof.identity);
    } catch (_) {
      await _close(session);
      rethrow;
    }

    // The readiness seen during the handshake is carried over deliberately: the
    // wrapper subscribes a moment later, and if the session went ready and then
    // dropped in between, all the wrapper is replayed is that latest `false`.
    // Without knowing the session had been up, it would read that as "not ready
    // yet" and keep trusting a connection that is already gone.
    return _TrustedCastSession(session, proof.identity,
        wasReady: proof.wasReady, cleanupTimeout: _cleanupTimeout);
  }

  /// Races the receiver's proof against the session ending and the clock, so an
  /// authentication that cannot conclude fails instead of waiting forever.
  Future<_Authentication> _authenticate(
    CastDevice device,
    CastSessionHandle session,
  ) async {
    final Completer<CastReceiverIdentity> race =
        Completer<CastReceiverIdentity>();

    void fail(CastTrustFailureKind kind, String message) {
      if (!race.isCompleted) {
        race.completeError(CastReceiverTrustException(message, kind: kind));
      }
    }

    // The session dying underneath the handshake is an unfinished check, not a
    // pass: whatever the receiver had said so far, it never finished saying it.
    // A `false` before the session has ever been ready is just "not yet" — the
    // receiver's media app is still launching — but a `false` after a `true` is
    // the session ending, exactly as DefaultCastService reads it.
    bool wasReady = false;
    final StreamSubscription<bool> ended = session.readyStream.listen(
      (bool ready) {
        if (ready) {
          wasReady = true;
        } else if (wasReady) {
          fail(CastTrustFailureKind.incomplete, _incompleteMessage);
        }
      },
      onError: (_) => fail(
        CastTrustFailureKind.incomplete,
        _incompleteMessage,
      ),
      onDone: () => fail(
        CastTrustFailureKind.incomplete,
        _incompleteMessage,
      ),
      cancelOnError: false,
    );

    final Timer expiry = Timer(
      _authenticationTimeout,
      () => fail(CastTrustFailureKind.incomplete, _incompleteMessage),
    );

    try {
      // Future.sync, inside the try: an implementation is free to throw before
      // it ever returns a future, and that must land on the same refusal and
      // the same cleanup as any other failed check — not escape past the timer
      // and the subscription that are already running.
      unawaited(
        Future<CastReceiverIdentity>.sync(
          () => _authenticator.authenticate(device, session),
        ).then(
          (CastReceiverIdentity identity) {
            if (!race.isCompleted) race.complete(identity);
          },
          onError: (Object error, StackTrace stack) {
            if (race.isCompleted) return;
            // Every failure becomes a refusal — "the check threw" is never
            // "the check passed" — and every refusal gets *this class's* copy.
            // A typed failure keeps only its kind: an implementation that wrote
            // a fingerprint or a challenge into its message would otherwise
            // have it published in CastState.message, and one natural
            // error-wrapping mistake should not be able to do that.
            race.completeError(
              CastReceiverTrustException(
                _messageFor(error is CastReceiverTrustException
                    ? error.kind
                    : CastTrustFailureKind.rejected),
                kind: error is CastReceiverTrustException
                    ? error.kind
                    : CastTrustFailureKind.rejected,
              ),
              stack,
            );
          },
        ),
      );

      return _Authentication(await race.future, wasReady: wasReady);
    } finally {
      expiry.cancel();
      // Bounded for the same reason closing is: cancelling a subscription can
      // wait on the stream's own teardown, and a delegate that stalls there
      // would hold the refusal — and the session's close with it — forever.
      await settleWithin(ended.cancel, _cleanupTimeout);
    }
  }

  /// Narrows "a receiver that authenticated" to "the receiver this device has
  /// always been".
  ///
  /// Authentication proves the peer holds a genuine Cast certificate; it does
  /// not say which genuine device it is, and discovery, being a friendly name
  /// on a LAN, says nothing at all. So the fingerprint the proof carries is
  /// recorded on first use and required to match every time after.
  ///
  /// Every uncertainty here is a refusal. A store that throws or hangs is not
  /// "no pin yet": it cannot tell a first use apart from a swap, so re-pinning
  /// on its silence would hand an attacker a way to erase the check by breaking
  /// it. A mismatch never overwrites the pin either: replacing one is
  /// [CastReceiverPinStore.forget], behind a deliberate user action.
  Future<void> _checkPin(
    CastDevice device,
    CastReceiverIdentity identity,
  ) async {
    final String fingerprint = normalizeCastFingerprint(identity.fingerprint);
    if (fingerprint.isEmpty) {
      // An identity with nothing to pin would match every device forever. That
      // is an authenticator bug, and it fails here rather than being recorded.
      throw CastReceiverTrustException(
        _messageFor(CastTrustFailureKind.rejected),
        kind: CastTrustFailureKind.rejected,
      );
    }

    final String? known;
    try {
      known = await _pins.pinFor(device.id).timeout(_pinTimeout);
    } catch (_) {
      throw CastReceiverTrustException(
        _messageFor(CastTrustFailureKind.incomplete),
        kind: CastTrustFailureKind.incomplete,
      );
    }

    if (known == null) {
      final String? recorded;
      try {
        await _pins.remember(device.id, fingerprint).timeout(_pinTimeout);
        // Read back rather than assume. Two connections to the same entry can
        // race here, and a store that refuses to overwrite (as the contract
        // requires) will have kept the other one's fingerprint: without this,
        // the loser of that race would carry on believing it had pinned itself.
        // It also catches a store that accepts a write and drops it.
        recorded = await _pins.pinFor(device.id).timeout(_pinTimeout);
      } catch (_) {
        // Refusing on a failed write keeps the two states the app can be in
        // honest: either this device is pinned, or it has never been cast to.
        // Handing out a session that was never recorded would silently pin the
        // *next* receiver instead, whichever one that is.
        throw CastReceiverTrustException(
          _messageFor(CastTrustFailureKind.incomplete),
          kind: CastTrustFailureKind.incomplete,
        );
      }
      if (recorded == null) {
        throw CastReceiverTrustException(
          _messageFor(CastTrustFailureKind.incomplete),
          kind: CastTrustFailureKind.incomplete,
        );
      }
      if (normalizeCastFingerprint(recorded) != fingerprint) {
        throw CastReceiverTrustException(
          _messageFor(CastTrustFailureKind.changedReceiver),
          kind: CastTrustFailureKind.changedReceiver,
        );
      }
      return;
    }

    if (normalizeCastFingerprint(known) != fingerprint) {
      throw CastReceiverTrustException(
        _messageFor(CastTrustFailureKind.changedReceiver),
        kind: CastTrustFailureKind.changedReceiver,
      );
    }
  }

  /// The only wording a refusal ever reaches the user with. Owned here, chosen
  /// by [CastTrustFailureKind] alone, so nothing an implementation writes into
  /// an exception can travel to the cast sheet.
  static String _messageFor(CastTrustFailureKind kind) {
    switch (kind) {
      case CastTrustFailureKind.unsupported:
        return "Linthra can't verify this device yet, so it won't send your "
            'music to it.';
      case CastTrustFailureKind.rejected:
        return _rejectedMessage;
      case CastTrustFailureKind.identityMismatch:
        return "Linthra couldn't confirm that this is the device you picked, "
            'so it stopped.';
      case CastTrustFailureKind.changedReceiver:
        return _changedReceiverMessage;
      case CastTrustFailureKind.incomplete:
        return _incompleteMessage;
    }
  }

  static const String _incompleteMessage =
      "Linthra couldn't finish checking that device, so it didn't send "
      'anything to it.';

  static const String _changedReceiverMessage =
      "This isn't the same device Linthra cast to before, so it stopped. If you "
      'replaced it, forget it in the cast list and try again.';

  static const String _rejectedMessage =
      "Linthra couldn't verify that device, so it didn't send anything to it.";

  Future<void> _close(CastSessionHandle session) =>
      // Bounded and swallowed: the refusal above is what the caller needs, and
      // a receiver that will not close — or will not answer at all — must not
      // be able to turn a refusal into a hang or an unhandled error.
      settleWithin(session.close, _cleanupTimeout);
}

/// Waits for best-effort cleanup, but never on it: [work] is given [limit] to
/// finish, and whether it times out or throws, the caller carries on. Used for
/// every teardown on a path whose real result is a refusal already in hand.
///
/// [work] is a callback rather than a future on purpose: an implementation may
/// throw before it ever returns one, and started outside this function that
/// throw would replace the refusal the caller is carrying. Future.sync brings
/// both kinds of failure inside.
Future<void> settleWithin(Future<void> Function() work, Duration limit) async {
  try {
    await Future<void>.sync(work).timeout(limit);
  } catch (_) {
    // Intentionally ignored: cleanup is not the outcome anyone is waiting for.
  }
}

/// A session whose receiver has been authenticated, wrapped so it can be told
/// apart from one that has not — and so the media handoff has its own refusal
/// rather than relying on nobody ever holding on to a session that has ended.
class _TrustedCastSession implements CastSessionHandle {
  _TrustedCastSession(
    this._session,
    this.identity, {
    required bool wasReady,
    required Duration cleanupTimeout,
  })  : _wasReady = wasReady,
        _cleanupTimeout = cleanupTimeout {
    // Trust belongs to the connection the proof was made over, so it ends when
    // that connection does — not when someone gets around to calling [close].
    // Without this, a track resolution that started before the receiver dropped
    // could still hand a credential-bearing URL to a dead session while the
    // service is still tearing it down.
    _lifetime = _session.readyStream.listen(
      (bool ready) {
        if (ready) {
          _wasReady = true;
        } else if (_wasReady) {
          _trusted = false;
        }
      },
      onError: (_) => _trusted = false,
      onDone: () => _trusted = false,
      cancelOnError: false,
    );
  }

  final CastSessionHandle _session;

  /// The verified receiver this session is bound to.
  final CastReceiverIdentity identity;

  /// How long teardown gets before it is left to finish on its own.
  final Duration _cleanupTimeout;

  StreamSubscription<bool>? _lifetime;

  /// Whether this session has been ready — seeded with what the handshake saw,
  /// so a drop in the gap between the two subscriptions is not read as "not
  /// ready yet".
  bool _wasReady;

  /// Trust does not survive the session. Once the connection it was proved over
  /// has ended — dropped by the receiver, or closed from here — this handle
  /// refuses media even though it authenticated a moment ago: a reconnection is
  /// a new receiver to prove.
  bool _trusted = true;

  /// Readiness as the app should see it: false once trust is gone, and an error
  /// on the delegate's stream turned into a clean "not ready" rather than passed
  /// on. A readiness error escaping here would reach the service as an unhandled
  /// async error instead of its ordinary session-lost teardown.
  @override
  Stream<bool> get readyStream => _session.readyStream
          .map((bool ready) => ready && _trusted)
          .transform(StreamTransformer<bool, bool>.fromHandlers(
        handleError: (Object error, StackTrace stack, EventSink<bool> sink) {
          _trusted = false;
          sink.add(false);
          sink.close();
        },
      ));

  @override
  Stream<CastPlaybackStatus> get statusStream => _session.statusStream;

  @override
  Stream<CastVolume> get volumeStream => _session.volumeStream;

  /// Refuses when the connection the receiver proved itself on is gone.
  ///
  /// Every outbound operation goes through this, not just the media handoff: a
  /// command sent after trust ended is a command to a receiver nobody has
  /// authenticated — the same connection may have been re-established
  /// underneath, and this session's proof says nothing about that one. Inbound
  /// streams are untouched; they carry no authority, and the app still needs to
  /// see the session end.
  void _requireTrust() {
    if (_trusted) return;
    throw const CastReceiverTrustException(
      "Linthra stopped casting to that device because it couldn't keep "
      'verifying it.',
      kind: CastTrustFailureKind.incomplete,
    );
  }

  @override
  Future<void> loadMedia(CastMedia media) async {
    // The last refusal before a token-bearing URL leaves the device: the check
    // is repeated here, at the handoff, rather than trusted to have happened in
    // the right order somewhere above.
    _requireTrust();
    await _session.loadMedia(media);
  }

  @override
  Future<void> play() async {
    _requireTrust();
    await _session.play();
  }

  @override
  Future<void> pause() async {
    _requireTrust();
    await _session.pause();
  }

  @override
  Future<void> seek(Duration position) async {
    _requireTrust();
    await _session.seek(position);
  }

  @override
  Future<void> setVolume(double level) async {
    _requireTrust();
    await _session.setVolume(level);
  }

  @override
  Future<void> setMuted(bool muted) async {
    _requireTrust();
    await _session.setMuted(muted);
  }

  @override
  Future<void> requestStatus() async {
    _requireTrust();
    await _session.requestStatus();
  }

  /// Teardown is never gated: closing an untrusted session is exactly what the
  /// caller should still be able to do.
  ///
  /// Both halves are bounded. A receiver that stalls while closing — its socket
  /// subscriptions winding down, say — would otherwise hold the service's own
  /// teardown open, so a disconnect would never reach the idle state and the
  /// next connection would never start. The delegate is free to finish closing
  /// in its own time; nothing here waits on it.
  @override
  Future<void> close() async {
    _trusted = false;
    final StreamSubscription<bool>? lifetime = _lifetime;
    _lifetime = null;
    if (lifetime != null) {
      await settleWithin(lifetime.cancel, _cleanupTimeout);
    }
    await settleWithin(_session.close, _cleanupTimeout);
  }
}

/// What a completed check yields: the proof, plus whether the session had been
/// ready while it ran. Both matter to the wrapper the caller gets.
class _Authentication {
  const _Authentication(this.identity, {required this.wasReady});

  final CastReceiverIdentity identity;
  final bool wasReady;
}
