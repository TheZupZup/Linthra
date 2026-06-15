import 'package:linthra/core/sources/plex/plex_exception.dart';
import 'package:linthra/core/sources/plex/plex_tv_api.dart';
import 'package:linthra/core/sources/plex/plex_tv_client.dart';

/// A configurable [PlexTvClient] that returns canned responses (or throws) and
/// records what it was asked, so the PIN auth flow and the settings controller
/// can be tested without plex.tv or HTTP.
///
/// Mirrors `FakePlexClient`: no mocking library, just settable fields and
/// recorded inputs. [checkPin] is scripted per call through [checkPinScript],
/// so a test can spell out an exact poll sequence (pending → transient failure
/// → granted) and the timeout/expiry paths.
class FakePlexTvClient implements PlexTvClient {
  FakePlexTvClient({
    this.pin =
        const PlexPin(id: 7, code: 'fake-pin-code', expiresInSeconds: 1800),
    this.createPinError,
    List<Object?>? checkPinScript,
    this.resources = const <PlexResource>[],
    this.resourcesError,
    this.homeUsers = const <PlexHomeUser>[],
    this.homeUsersError,
    Map<String, String>? switchTokens,
    this.switchError,
  })  : checkPinScript = checkPinScript ?? <Object?>[],
        switchTokens = switchTokens ?? <String, String>{};

  /// Canned PIN for [createPin].
  PlexPin pin;
  PlexException? createPinError;

  /// One entry consumed per [checkPin] call: a `String` is returned as the
  /// granted token, `null` means still pending, and a [PlexException] is
  /// thrown. An exhausted script keeps answering "pending" — the state a
  /// timeout test needs.
  final List<Object?> checkPinScript;

  /// Canned devices for [fetchResources].
  List<PlexResource> resources;
  PlexException? resourcesError;

  /// Canned Plex Home users for [fetchHomeUsers].
  List<PlexHomeUser> homeUsers;
  PlexException? homeUsersError;

  /// Per-uuid tokens returned by [switchHomeUser]; an unmapped uuid falls back
  /// to a deterministic `switched-token-<uuid>`.
  Map<String, String> switchTokens;
  PlexException? switchError;

  // Recorded inputs.
  int createPinCount = 0;
  int checkPinCount = 0;
  int? lastCheckedPinId;
  String? lastResourcesToken;
  String? lastHomeUsersToken;
  int switchCount = 0;
  String? lastSwitchedUuid;
  String? lastSwitchToken;
  String? lastSwitchPin;

  @override
  Future<PlexPin> createPin() async {
    createPinCount++;
    final PlexException? error = createPinError;
    if (error != null) throw error;
    return pin;
  }

  @override
  Future<String?> checkPin(int pinId) async {
    checkPinCount++;
    lastCheckedPinId = pinId;
    if (checkPinScript.isEmpty) return null;
    final Object? next = checkPinScript.removeAt(0);
    if (next is PlexException) throw next;
    return next as String?;
  }

  @override
  Future<List<PlexResource>> fetchResources({required String token}) async {
    lastResourcesToken = token;
    final PlexException? error = resourcesError;
    if (error != null) throw error;
    return resources;
  }

  @override
  Future<List<PlexHomeUser>> fetchHomeUsers({required String token}) async {
    lastHomeUsersToken = token;
    final PlexException? error = homeUsersError;
    if (error != null) throw error;
    return homeUsers;
  }

  @override
  Future<String> switchHomeUser({
    required String uuid,
    required String token,
    String? pin,
  }) async {
    switchCount++;
    lastSwitchedUuid = uuid;
    lastSwitchToken = token;
    lastSwitchPin = pin;
    final PlexException? error = switchError;
    if (error != null) throw error;
    return switchTokens[uuid] ?? 'switched-token-$uuid';
  }
}
