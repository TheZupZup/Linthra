import '../../models/cast_state.dart';

/// The emergency security containment that keeps casting off in shipped builds.
///
/// Casting is withheld from production while a reported security issue is being
/// resolved. The report itself, its assessment, and the requirements any
/// restoration has to meet are held in the repository's private security
/// advisory; [#575](https://github.com/TheZupZup/Linthra/issues/575) tracks the
/// public side of that work. Details of the report do not belong in this file,
/// in the app, in a commit message, or in a pull request.
///
/// Containment is not a UI decision. It is enforced at three independent layers,
/// so that no single edit re-enables the path by accident:
///
///  1. **Production wiring** — the production override binds
///     [UnavailableCastService]; the real service is not constructed at all, on
///     any platform, so there is nothing to discover or connect with.
///  2. **Transport** — [ChromecastCastTransport] refuses to discover or connect
///     while [isActive], so re-wiring the service in isolation (a test-only
///     injection reaching production, a revert of the provider) still cannot
///     open a receiver socket.
///  3. **Media handoff** — the session handle refuses to hand media to a
///     receiver, so a session obtained some other way is still given nothing.
///
/// [isActive] is a compile-time constant on purpose. There is deliberately no
/// setting, environment variable, or debug affordance that flips it: an
/// unreviewed runtime switch would be a second production path with none of the
/// review the restoration itself requires. Restoring casting means changing this
/// constant *and* the wiring in one reviewed change.
///
/// What actually demonstrates the containment is the test suite —
/// `test/app/production_cast_containment_test.dart` and
/// `test/core/services/cast/cast_containment_test.dart` exercise the real
/// production wiring and the transport at runtime.
/// `scripts/check_cast_containment.py` is a much weaker source-pattern tripwire
/// on top of that, and its own limitations are written down in it.
///
/// Local playback, downloads, and every server integration are untouched by
/// containment; only casting is withheld.
abstract final class CastContainment {
  /// Whether casting is withheld from production. Flipping this to `false` is a
  /// security decision, not a cleanup: see `docs/features/cast.md` and the private
  /// advisory.
  static const bool isActive = true;

  /// What the cast UI tells the user. Deliberately specific about what is off
  /// and what is unaffected, and deliberately free of any detail about the
  /// report — that stays in the private advisory until coordinated disclosure.
  static const String userMessage =
      'Casting is temporarily turned off in this version while a security fix '
      'is finished. Everything else — local playback, downloads, and your '
      'servers — works as usual, and your queue and settings are untouched.';

  /// The state the cast UI renders while contained: unavailable, with the
  /// explanation above.
  static const CastState state = CastState(message: userMessage);
}

/// Thrown by the fail-closed cast layers when something asks them to reach a
/// receiver while [CastContainment.isActive].
///
/// Reaching this is a bug rather than a user-facing condition — the production
/// wiring never builds a live transport — so it is an [Error]: it should crash a
/// debug build and be fixed, not be caught and retried. It carries no detail
/// about the report.
class CastContainmentError extends StateError {
  CastContainmentError(String operation)
      : super(
          'Cast is contained for security: $operation was refused. See '
          'CastContainment.',
        );
}
