import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/playback_source_label.dart';
import '../../core/sources/music_provider.dart';
import '../../core/sources/source_availability.dart';
import '../library/source_availability_providers.dart';
import '../settings/jellyfin/jellyfin_settings_controller.dart';
import '../settings/plex/plex_settings_controller.dart';
import '../settings/subsonic/subsonic_settings_controller.dart';
import 'source_status.dart';

/// One configured self-hosted source, resolved to something the sidebar can
/// draw: who it is, and how it is doing.
@immutable
class ConfiguredSourceStatus {
  const ConfiguredSourceStatus({
    required this.sourceId,
    required this.name,
    required this.presentation,
  });

  /// `MusicProvider.sourceId` — the stable key, used for widget keys and for
  /// asserting isolation in tests. Not shown to the user.
  final String sourceId;

  /// The safe display name from [PlaybackSourceLabel]'s fixed vocabulary.
  final String name;

  final SourceStatusPresentation presentation;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ConfiguredSourceStatus &&
          other.sourceId == sourceId &&
          other.name == name &&
          other.presentation == presentation);

  @override
  int get hashCode => Object.hash(sourceId, name, presentation);

  @override
  String toString() =>
      'ConfiguredSourceStatus($sourceId, ${presentation.label})';
}

/// The self-hosted sources the sidebar may show, in a fixed order.
///
/// On-device music is deliberately absent: it has no server to be away, so a
/// permanent "connected" beside it would be the noise this feature exists to
/// avoid.
const List<MusicProvider> _selfHostedSources = <MusicProvider>[
  MusicProviders.jellyfin,
  MusicProviders.subsonic,
  MusicProviders.plex,
];

/// Whether each self-hosted source has a saved session, for the sources that
/// publish no availability of their own.
///
/// Each source is asked the same question its own `*MusicSourceProvider` asks,
/// because that is what actually decides whether the source is serving music —
/// and a sidebar row that disagrees with it is the row lying.
///
/// Jellyfin and Subsonic gate on the connected phase: their sign-in is a single
/// synchronous step, so the phase and the session move together.
///
/// Plex does not, and this is the reason the rule is per-source rather than one
/// `isConnected` for all three. `connectWithPlex` deliberately keeps the
/// existing session while the user is away in the browser approving a new one,
/// so a *reconnect* moves the phase to `linking` → `loadingUsers` →
/// `pickingServer` while `session` stays put and `plexMusicSourceProvider`
/// keeps serving. Reading the phase would have pulled the Plex row out of the
/// sidebar for the whole flow and popped it back on cancel — while Plex was
/// still playing.
final _configuredSourceIdsProvider = Provider<Set<String>>((ref) {
  // Watched for the rebuild, read for the session: the session lives on the
  // notifier rather than in the state (it holds a token, and the state is
  // deliberately secret-free), which is the same two-step
  // `plexMusicSourceProvider` does.
  ref.watch(plexSettingsControllerProvider);
  final bool plexConfigured =
      ref.read(plexSettingsControllerProvider.notifier).session != null;

  return <String>{
    if (ref.watch(
      jellyfinSettingsControllerProvider.select((s) => s.isConnected),
    ))
      MusicProviders.jellyfin.sourceId,
    if (ref.watch(
      subsonicSettingsControllerProvider.select((s) => s.isConnected),
    ))
      MusicProviders.subsonic.sourceId,
    if (plexConfigured) MusicProviders.plex.sourceId,
  };
});

/// What the desktop sidebar shows beside each configured self-hosted source.
///
/// **Derived, never probed.** Every input already exists and is already watched
/// by something else: [sourceAvailabilityProvider] (the per-source probe
/// controllers) and the three settings controllers. This provider owns no
/// timer, no client and no request, so a sidebar row costs exactly nothing to
/// render and adding a second row would cost nothing again. That is the whole
/// reason the indicators can be live without a polling system behind them.
///
/// **A source that publishes a probe wins.** For a source listed in
/// [sourceAvailabilityProvider], that value is the single truth — it already
/// encodes "not configured" — so the sidebar and the library filter can never
/// disagree about whether a server is away. Only a source that publishes
/// nothing yet (Navidrome and Plex today) falls back to "configured, and
/// therefore assumed reachable", which is exactly what the rest of the app
/// already assumes about it. When one adopts the probe the way Jellyfin did,
/// its indicator becomes real with no change here.
///
/// **Isolation.** Each entry is resolved from that source's own state alone, so
/// a Jellyfin probe coming back negative cannot move Plex's row.
///
/// **No flicker by construction.** The probe controllers publish `checking`
/// only when nothing is known yet — a fresh sign-in or a cold start — and never
/// on an ordinary re-probe, which writes its settled answer directly. So a
/// server that is simply being polled stays "connected" on screen instead of
/// blinking through a spinner every interval.
final configuredSourceStatusesProvider =
    Provider<List<ConfiguredSourceStatus>>((ref) {
  final Map<String, SourceAvailability> probed =
      ref.watch(sourceAvailabilityProvider);
  final Set<String> configured = ref.watch(_configuredSourceIdsProvider);

  final List<ConfiguredSourceStatus> statuses = <ConfiguredSourceStatus>[];
  for (final MusicProvider provider in _selfHostedSources) {
    final SourceAvailability availability = probed[provider.sourceId] ??
        (configured.contains(provider.sourceId)
            ? SourceAvailability.available
            : SourceAvailability.notConfigured);
    final String name = PlaybackSourceLabel.forSourceId(provider.sourceId);
    final SourceStatusPresentation? presentation =
        sourceStatusPresentation(availability, sourceName: name);
    // Null is "not configured": nothing to say, so no row at all.
    if (presentation == null) continue;
    statuses.add(
      ConfiguredSourceStatus(
        sourceId: provider.sourceId,
        name: name,
        presentation: presentation,
      ),
    );
  }
  return statuses;
});
