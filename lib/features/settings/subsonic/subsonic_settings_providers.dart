import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/subsonic/http_subsonic_client.dart';
import '../../../core/sources/subsonic/subsonic_authenticator.dart';
import '../../../core/sources/subsonic/subsonic_client.dart';

/// The HTTP seam for all Subsonic networking.
///
/// Defaults to the real [HttpSubsonicClient]; tests override it with a fake
/// client that returns canned responses, so the whole settings/auth flow can be
/// exercised without a server. This is the single place production wires the
/// concrete client — `main` needs no override because the default is already the
/// real one.
final subsonicClientProvider = Provider<SubsonicClient>((ref) {
  return HttpSubsonicClient();
});

/// Coordinates URL validation + the token+salt auth on top of
/// [subsonicClientProvider].
///
/// The settings controller depends on this rather than on the client directly,
/// keeping authentication (produce a session) separate from the controller's
/// orchestration (when to test, sign in, persist, clear).
final subsonicAuthenticatorProvider = Provider<SubsonicAuthenticator>((ref) {
  return SubsonicAuthenticator(ref.watch(subsonicClientProvider));
});
