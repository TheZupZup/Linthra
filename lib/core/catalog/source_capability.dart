import '../models/playback_source.dart';
import '../models/track.dart';
import '../sources/music_provider.dart';
import 'track_identity.dart';

/// The owning provider of a source candidate. Distinct from *where the bytes come
/// from* this time ([SourceDelivery]): a Jellyfin track played from a downloaded
/// copy is still `jellyfin` here, with [SourceDelivery.cache] delivery.
enum SourceProviderType {
  jellyfin('Jellyfin'),
  subsonic('Navidrome / Subsonic'),
  local('Local music'),
  unknown('Unknown source');

  const SourceProviderType(this.displayName);

  /// A fixed, non-identifying display name — never a URL, host, or path.
  final String displayName;
}

/// How a candidate's audio would actually reach the player. Separate from the
/// owning [SourceProviderType] so "prefer cache/local" or "prefer lower data"
/// strategies (PR3b) can reason about delivery cost without re-deriving it.
enum SourceDelivery {
  /// An on-device file (or Android SAF document) played from its own path.
  localFile,

  /// A remote track served from its downloaded, on-disk copy (no network).
  cache,

  /// A remote track streamed live from its server.
  remoteStream,

  /// Not known (e.g. an unrecognised source).
  unknown;
}

/// An immutable snapshot of *what Linthra knows* about one playback source
/// candidate — the foundation for future smart source strategies (PR3b: prefer
/// local/cache, prefer highest quality, prefer lower data, automatic balanced).
///
/// **PR3a is metadata-only.** This model describes a candidate; it never decides
/// the winner and is not yet wired into playback selection, the default-source
/// behaviour, or runtime fallback. PR3b will consume it.
///
/// ## Honesty over guessing
///
/// Every field that isn't safely derivable from existing data is left `null` /
/// `unknown` rather than guessed. Today only the owning provider, the inherent
/// delivery, and the [duration] are known from a [Track]; codec, bitrate, file
/// size, transcoding, and LAN-vs-remote are **not** captured anywhere yet (the
/// Subsonic/Jellyfin DTOs don't parse them and `Track` doesn't store them), so
/// they read as unknown. Capturing them later (e.g. onto `Track` from the wire)
/// is a separate change; the structure here is ready for it.
///
/// ## Safety
///
/// Only a non-identifying [sourceId] (`jellyfin` / `subsonic` / `local`) plus
/// enums and plain numbers are stored. The track's URI, file path, server host,
/// username, and tokens are **never** held or printed — [toString] is safe to log.
class PlaybackSourceCapability {
  const PlaybackSourceCapability({
    required this.sourceId,
    required this.providerType,
    required this.delivery,
    this.isLikelyLan,
    this.codec,
    this.bitrateKbps,
    this.fileSizeBytes,
    this.duration,
    this.transcoded,
  });

  /// The owning provider's id (`jellyfin` / `subsonic` / `local`, or another
  /// known scheme). A stable, non-sensitive identifier — never a URL or path.
  final String sourceId;

  /// The owning provider type (see [SourceProviderType]).
  final SourceProviderType providerType;

  /// How the audio would reach the player (see [SourceDelivery]).
  final SourceDelivery delivery;

  /// Whether the source is *likely* on the local network rather than the public
  /// internet, when that is safely knowable without inspecting a URL/IP. `null`
  /// (unknown) by default — Linthra does not guess this from an address.
  final bool? isLikelyLan;

  /// Audio codec/container (e.g. `flac`, `mp3`) when already known; else `null`.
  final String? codec;

  /// Stream/file bitrate in kbps when already known; else `null`.
  final int? bitrateKbps;

  /// File size in bytes when already known; else `null`.
  final int? fileSizeBytes;

  /// Track duration when known (a positive value); else `null`.
  final Duration? duration;

  /// Whether the server would transcode rather than serve the original: `true`
  /// (transcoded), `false` (original), or `null` (unknown). Never guessed.
  final bool? transcoded;

  /// The source is an on-device file.
  bool get isLocalFile => delivery == SourceDelivery.localFile;

  /// The source would play from a downloaded, on-disk copy (no network).
  bool get isCachedOffline => delivery == SourceDelivery.cache;

  /// The source would stream live from a remote server.
  bool get isRemoteStream => delivery == SourceDelivery.remoteStream;

  /// Whether the transcoding state is known (vs. [transcoded] being `null`).
  bool get transcodingKnown => transcoded != null;

  /// Whether anything about audio quality (codec or bitrate) is known.
  bool get qualityKnown => codec != null || bitrateKbps != null;

  /// Whether the data cost (bitrate or file size) is known. A local/cached
  /// source costs no network data regardless, which PR3b can treat as cheap.
  bool get dataCostKnown => bitrateKbps != null || fileSizeBytes != null;

  /// Describes a candidate from its catalog [Track] alone: the owning provider
  /// and its *inherent* delivery (local file vs. remote stream), plus the
  /// duration when present. Quality, size, transcoding, and LAN-vs-remote are
  /// unknown (not carried by `Track`). No network call, no disk read, no guess.
  ///
  /// [cachedOffline] is a safe, in-memory signal (e.g. the downloaded-track set)
  /// that a *remote* candidate already has an offline copy: when `true` such a
  /// candidate's delivery becomes [SourceDelivery.cache], so "prefer cache"
  /// strategies can favour it without a disk scan. It never upgrades a local
  /// file (already on device) or an unknown source, and defaults to `false`.
  factory PlaybackSourceCapability.fromTrack(
    Track track, {
    bool cachedOffline = false,
  }) {
    final String id = trackSourceId(track);
    final SourceProviderType provider = _providerTypeFor(id);
    final SourceDelivery inherent = _inherentDeliveryFor(provider);
    final SourceDelivery delivery =
        (cachedOffline && inherent == SourceDelivery.remoteStream)
            ? SourceDelivery.cache
            : inherent;
    return PlaybackSourceCapability(
      sourceId: id,
      providerType: provider,
      delivery: delivery,
      duration: track.duration > Duration.zero ? track.duration : null,
    );
  }

  /// Refines a candidate's profile with the delivery the resolver actually chose
  /// ([PlaybackSource]) — the safe way to learn a copy is being served from
  /// [SourceDelivery.cache]. The owning provider and duration are kept from
  /// [PlaybackSourceCapability.fromTrack]; nothing else is invented.
  factory PlaybackSourceCapability.fromResolvedSource(
    Track track,
    PlaybackSource source,
  ) {
    final PlaybackSourceCapability base =
        PlaybackSourceCapability.fromTrack(track);
    return PlaybackSourceCapability(
      sourceId: base.sourceId,
      providerType: base.providerType,
      delivery: _deliveryForResolved(source),
      isLikelyLan: base.isLikelyLan,
      codec: base.codec,
      bitrateKbps: base.bitrateKbps,
      fileSizeBytes: base.fileSizeBytes,
      duration: base.duration,
      transcoded: base.transcoded,
    );
  }

  static SourceProviderType _providerTypeFor(String sourceId) {
    if (sourceId == MusicProviders.jellyfin.sourceId) {
      return SourceProviderType.jellyfin;
    }
    if (sourceId == MusicProviders.subsonic.sourceId) {
      return SourceProviderType.subsonic;
    }
    if (sourceId == MusicProviders.local.sourceId) {
      return SourceProviderType.local;
    }
    return SourceProviderType.unknown;
  }

  static SourceDelivery _inherentDeliveryFor(SourceProviderType provider) {
    switch (provider) {
      case SourceProviderType.local:
        return SourceDelivery.localFile;
      case SourceProviderType.jellyfin:
      case SourceProviderType.subsonic:
        return SourceDelivery.remoteStream;
      case SourceProviderType.unknown:
        return SourceDelivery.unknown;
    }
  }

  static SourceDelivery _deliveryForResolved(PlaybackSource source) {
    switch (source) {
      case PlaybackSource.localFile:
        return SourceDelivery.localFile;
      case PlaybackSource.offlineCache:
        return SourceDelivery.cache;
      case PlaybackSource.streamingDirect:
        return SourceDelivery.remoteStream;
    }
  }

  /// A safe, debug-friendly description. Contains only the provider id, enums,
  /// and known/unknown values — never a URL, path, host, username, or token.
  @override
  String toString() {
    return 'PlaybackSourceCapability('
        'sourceId: $sourceId, '
        'provider: ${providerType.name}, '
        'delivery: ${delivery.name}, '
        'duration: ${duration ?? 'unknown'}, '
        'codec: ${codec ?? 'unknown'}, '
        'bitrateKbps: ${bitrateKbps ?? 'unknown'}, '
        'fileSizeBytes: ${fileSizeBytes ?? 'unknown'}, '
        'transcoded: ${transcoded ?? 'unknown'}, '
        'isLikelyLan: ${isLikelyLan ?? 'unknown'})';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlaybackSourceCapability &&
          other.sourceId == sourceId &&
          other.providerType == providerType &&
          other.delivery == delivery &&
          other.isLikelyLan == isLikelyLan &&
          other.codec == codec &&
          other.bitrateKbps == bitrateKbps &&
          other.fileSizeBytes == fileSizeBytes &&
          other.duration == duration &&
          other.transcoded == transcoded);

  @override
  int get hashCode => Object.hash(
        sourceId,
        providerType,
        delivery,
        isLikelyLan,
        codec,
        bitrateKbps,
        fileSizeBytes,
        duration,
        transcoded,
      );
}
