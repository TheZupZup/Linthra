import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/audiobookshelf/audiobookshelf_authenticator.dart';
import '../../../core/sources/audiobookshelf/audiobookshelf_client.dart';
import '../../../core/sources/audiobookshelf/http_audiobookshelf_client.dart';
import '../local_network/local_network_providers.dart';

/// The HTTP seam for all Audiobookshelf networking.
///
/// Defaults to the real [HttpAudiobookshelfClient]; tests override it with a
/// fake client that returns canned responses, so the whole settings/auth flow
/// can be exercised without a server. This is the single place production wires
/// the concrete client — `main` needs no override because the default is
/// already the real one.
final audiobookshelfClientProvider = Provider<AudiobookshelfClient>((ref) {
  return HttpAudiobookshelfClient(httpClient: guardedServerHttpClient(ref));
});

/// Coordinates URL validation + sign-in on top of [audiobookshelfClientProvider].
///
/// The settings controller depends on this rather than on the client directly,
/// keeping authentication (produce a session) separate from the controller's
/// orchestration (when to test, sign in, persist, clear).
final audiobookshelfAuthenticatorProvider =
    Provider<AudiobookshelfAuthenticator>((ref) {
  return AudiobookshelfAuthenticator(ref.watch(audiobookshelfClientProvider));
});
