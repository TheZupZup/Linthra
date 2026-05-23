import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/jellyfin/http_jellyfin_client.dart';
import '../../../core/sources/jellyfin/jellyfin_authenticator.dart';
import '../../../core/sources/jellyfin/jellyfin_client.dart';

/// The HTTP seam for all Jellyfin networking.
///
/// Defaults to the real [HttpJellyfinClient]; tests override it with a fake
/// client that returns canned responses, so the whole settings/auth flow can be
/// exercised without a server. This is the single place production wires the
/// concrete client — `main` needs no override because the default is already
/// the real one.
final jellyfinClientProvider = Provider<JellyfinClient>((ref) {
  return HttpJellyfinClient();
});

/// Coordinates URL validation + authentication on top of [jellyfinClientProvider].
///
/// The settings controller depends on this rather than on the client directly,
/// keeping authentication (produce a session) separate from the controller's
/// orchestration (when to test, sign in, persist, clear).
final jellyfinAuthenticatorProvider = Provider<JellyfinAuthenticator>((ref) {
  return JellyfinAuthenticator(ref.watch(jellyfinClientProvider));
});
