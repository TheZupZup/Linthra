import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../../core/native/rust_http_client.dart';
import '../../../core/platform/host_platform.dart';
import '../../../core/sources/subsonic/http_subsonic_client.dart';
import '../../../core/sources/subsonic/subsonic_authenticator.dart';
import '../../../core/sources/subsonic/subsonic_client.dart';
import '../../../data/repositories/host_platform_provider.dart';
import '../local_network/local_network_providers.dart';

/// How Navidrome/Subsonic requests travel, as a new client for each user
/// (the folder browser closes its own).
///
/// On Linux they go out through the Rust core ([RustHttpClient]), with TLS
/// checked by the system's trust store, proven there by
/// native/linthra_core/tests/tls_*.rs. Elsewhere through `package:http`, until
/// the same is checked on an Android device with a CA the user installed
/// (docs/development/rust-backend.md).
final subsonicTransportProvider = Provider<http.Client Function()>((ref) {
  return ref.watch(hostPlatformProvider) == HostPlatform.linux
      ? RustHttpClient.new
      : http.Client.new;
});

/// The HTTP seam for all Subsonic networking.
///
/// Defaults to the real [HttpSubsonicClient]; tests override it with a fake
/// client that returns canned responses, so the whole settings/auth flow can be
/// exercised without a server. This is the single place production wires the
/// concrete client — `main` needs no override because the default is already the
/// real one.
final subsonicClientProvider = Provider<SubsonicClient>((ref) {
  return HttpSubsonicClient(
    httpClient: guardedServerHttpClient(
      ref,
      transport: ref.watch(subsonicTransportProvider)(),
    ),
  );
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
