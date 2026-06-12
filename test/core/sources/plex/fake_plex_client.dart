import 'package:linthra/core/sources/plex/plex_api.dart';
import 'package:linthra/core/sources/plex/plex_client.dart';
import 'package:linthra/core/sources/plex/plex_exception.dart';

/// A configurable [PlexClient] that returns canned responses (or throws) and
/// records what it was asked, so the future authenticator / source / controllers
/// can be tested without a real server or HTTP.
///
/// Mirrors `FakeJellyfinClient` / `FakeSubsonicClient`: no mocking library, just
/// settable fields and recorded inputs.
class FakePlexClient implements PlexClient {
  FakePlexClient({
    this.identity,
    this.identityError,
    this.sections = const <PlexDirectory>[],
    this.sectionsError,
    this.itemsByType = const <PlexMetadataType, List<PlexMetadata>>{},
    this.itemsError,
    this.metadataByRatingKey = const <String, PlexMetadata>{},
    this.metadataError,
  });

  /// Canned identity for [fetchIdentity]; defaults to a healthy server.
  PlexServerIdentity? identity;
  PlexException? identityError;

  /// Canned sections for [fetchSections].
  List<PlexDirectory> sections;
  PlexException? sectionsError;

  /// Canned items per music type for [fetchSectionItems].
  Map<PlexMetadataType, List<PlexMetadata>> itemsByType;
  PlexException? itemsError;

  /// Canned single items per `ratingKey` for [fetchMetadata]; a missing key
  /// throws [PlexException.notFound] (the real client maps a 404 the same way).
  Map<String, PlexMetadata> metadataByRatingKey;
  PlexException? metadataError;

  /// When set, every [reportTimeline] call throws it (after being recorded),
  /// so reporters can prove failures are swallowed. Set [timelineError] for a
  /// typed failure or [timelineUnexpectedError] for an untyped one.
  PlexException? timelineError;
  Object? timelineUnexpectedError;

  // Recorded inputs.
  String? lastBaseUrl;
  String? lastToken;
  final List<({String sectionKey, PlexMetadataType itemType})> itemRequests =
      <({String sectionKey, PlexMetadataType itemType})>[];
  final List<String> requestedRatingKeys = <String>[];
  int identityCount = 0;

  /// Every timeline report received, in order, so tests can assert the exact
  /// state/position/duration sequence a playback scenario produced.
  final List<
      ({
        String ratingKey,
        PlexTimelineState state,
        Duration time,
        Duration? duration,
      })> timelineReports = <({
    String ratingKey,
    PlexTimelineState state,
    Duration time,
    Duration? duration,
  })>[];

  @override
  Future<PlexServerIdentity> fetchIdentity({
    required String baseUrl,
    required String token,
  }) async {
    identityCount++;
    lastBaseUrl = baseUrl;
    lastToken = token;
    final PlexException? error = identityError;
    if (error != null) throw error;
    return identity ??
        const PlexServerIdentity(
          machineIdentifier: 'fake-machine-id',
          version: '1.40.0',
        );
  }

  @override
  Future<List<PlexDirectory>> fetchSections({
    required String baseUrl,
    required String token,
  }) async {
    lastBaseUrl = baseUrl;
    lastToken = token;
    final PlexException? error = sectionsError;
    if (error != null) throw error;
    return sections;
  }

  @override
  Future<List<PlexMetadata>> fetchSectionItems({
    required String baseUrl,
    required String token,
    required String sectionKey,
    required PlexMetadataType itemType,
  }) async {
    lastBaseUrl = baseUrl;
    lastToken = token;
    itemRequests.add((sectionKey: sectionKey, itemType: itemType));
    final PlexException? error = itemsError;
    if (error != null) throw error;
    return itemsByType[itemType] ?? const <PlexMetadata>[];
  }

  @override
  Future<PlexMetadata> fetchMetadata({
    required String baseUrl,
    required String token,
    required String ratingKey,
  }) async {
    lastBaseUrl = baseUrl;
    lastToken = token;
    requestedRatingKeys.add(ratingKey);
    final PlexException? error = metadataError;
    if (error != null) throw error;
    final PlexMetadata? item = metadataByRatingKey[ratingKey];
    if (item == null) throw PlexException.notFound();
    return item;
  }

  @override
  Future<void> reportTimeline({
    required String baseUrl,
    required String token,
    required String ratingKey,
    required PlexTimelineState state,
    required Duration time,
    Duration? duration,
  }) async {
    lastBaseUrl = baseUrl;
    lastToken = token;
    timelineReports.add((
      ratingKey: ratingKey,
      state: state,
      time: time,
      duration: duration,
    ));
    final PlexException? error = timelineError;
    if (error != null) throw error;
    final Object? unexpected = timelineUnexpectedError;
    if (unexpected != null) throw unexpected;
  }
}
