import 'package:flutter/foundation.dart';

/// What a source hands to a receiver so it can fetch the bytes.
///
/// A cast handoff is a delegation: the phone stops fetching the audio and tells
/// a device on the network to fetch it instead, which means giving that device
/// whatever it needs to be allowed to. How *much* it needs is not Linthra's
/// choice alone — it is whatever the music server is willing to issue.
enum CastMediaDelegation {
  /// A capability minted for this one piece of media: a signed or otherwise
  /// scoped URL that lets the bearer fetch this item and nothing else, and that
  /// stops working on its own. This is the shape least privilege wants.
  scopedCapability,

  /// The account credential itself, carried in the URL because that is the only
  /// authentication the server's stream endpoint accepts. Anyone holding the URL
  /// holds an account credential, not a permission to play one song.
  accountCredential,

  /// Nothing is delegated, because nothing is handed over — an on-device file
  /// has no URL a receiver could fetch at all.
  none,
}

/// How much a delegated capability reaches.
enum CastMediaScope {
  /// The one item being cast.
  singleItem,

  /// Everything the signed-in account can reach on that server.
  account,

  /// Nothing.
  nothing,
}

/// What casting one track actually hands over, per source.
///
/// This exists because "the URL has a token in it" is not a security model, and
/// [#576](https://github.com/TheZupZup/Linthra/issues/576) is about being honest
/// about the difference between the delegation a provider *supports* and the one
/// Linthra is *forced* into. Declaring it in code — next to the resolver that
/// mints the URL, checked by tests — means a new source cannot quietly widen the
/// exposure, and the app can eventually tell a user what a handoff costs.
///
/// It carries no secret: it describes a URL's authority, never its contents.
/// See docs/cast-media-access.md for the per-provider matrix and what each
/// server would have to add for [CastMediaDelegation.scopedCapability] to become
/// available.
@immutable
class CastMediaAccess {
  const CastMediaAccess({
    required this.delegation,
    required this.scope,
    required this.summary,
    this.lifetime,
    this.revocableIndependently = false,
  });

  /// The fail-safe default, used when nothing has declared otherwise: assume the
  /// widest exposure a source could have. A resolver that forgets to describe
  /// itself is treated as handing over an account credential rather than as
  /// harmless, so the mistake shows up as an overstatement, never as a quiet
  /// under-statement.
  static const CastMediaAccess undeclared = CastMediaAccess(
    delegation: CastMediaDelegation.accountCredential,
    scope: CastMediaScope.account,
    summary:
        'No source declared what this handoff delegates, so it is treated as '
        'handing the receiver account-level access.',
  );

  /// Nothing is handed over.
  static const CastMediaAccess none = CastMediaAccess(
    delegation: CastMediaDelegation.none,
    scope: CastMediaScope.nothing,
    summary: 'Nothing is delegated to a receiver.',
  );

  /// Media re-served by the on-device relay (`LocalCastMediaProxy`).
  ///
  /// The receiver is given an address on the phone, with a random token for
  /// this one item, instead of the server URL. The relay enforces it: the token
  /// reaches only that item, stops working once the receiver accepts the next
  /// item or the cast session ends, and ending it touches nothing on the server. The
  /// account credential never leaves the phone. That is a capability Linthra
  /// issues and checks itself, not one the server does, which is why it is
  /// declared here rather than by a resolver.
  static const CastMediaAccess localRelay = CastMediaAccess(
    delegation: CastMediaDelegation.scopedCapability,
    scope: CastMediaScope.singleItem,
    summary: 'The receiver is given a one-item address on this phone that '
        'stops working when the cast session ends. The server credential stays '
        'on the phone.',
    revocableIndependently: true,
  );

  /// The mechanism the receiver is given.
  final CastMediaDelegation delegation;

  /// How far that mechanism reaches if it is observed or kept.
  final CastMediaScope scope;

  /// A short, non-secret sentence for docs, diagnostics and (eventually) the
  /// cast sheet. Never contains a credential, a URL, or a fragment of either.
  final String summary;

  /// How long the delegated access stays usable, when the server bounds it.
  /// Null means it lasts as long as the credential behind it does — which for
  /// an account credential is "until the user signs out or changes it".
  final Duration? lifetime;

  /// Whether the user can revoke *this* access without invalidating their whole
  /// session or changing their password.
  final bool revocableIndependently;

  /// Whether this handoff gives the receiver no more than the item being played.
  bool get isLeastPrivilege =>
      delegation != CastMediaDelegation.accountCredential &&
      scope != CastMediaScope.account;

  /// Whether the receiver ends up holding an account credential. The honest
  /// answer for every server Linthra supports today; see the doc above.
  bool get delegatesAccountCredential =>
      delegation == CastMediaDelegation.accountCredential;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CastMediaAccess &&
          other.delegation == delegation &&
          other.scope == scope &&
          other.summary == summary &&
          other.lifetime == lifetime &&
          other.revocableIndependently == revocableIndependently);

  @override
  int get hashCode => Object.hash(
        delegation,
        scope,
        summary,
        lifetime,
        revocableIndependently,
      );

  @override
  String toString() =>
      'CastMediaAccess(${delegation.name}, scope: ${scope.name}, '
      'lifetime: ${lifetime ?? 'until the session ends'})';
}
