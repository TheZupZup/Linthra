import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dbus/dbus.dart';

import '../../models/playback_state.dart';
import '../../repositories/download_repository.dart';
import '../../repositories/favorites_repository.dart';
import '../../repositories/music_library_repository.dart';
import '../../repositories/playlist_repository.dart';
import '../desktop_application_actions.dart';
import '../media_artwork_source.dart';
import '../media_session_binding.dart';
import '../playback_controller.dart';
import 'mpris_player_object.dart';

/// Opens a session-bus connection. Injectable so a test never touches a bus.
typedef DBusClientFactory = DBusClient Function();

/// Linthra's MPRIS presence on the session bus: the connection, the well-known
/// name, the exported object, and the subscription that keeps it current.
///
/// [MprisPlayerObject] does the translating; this class does the owning. The
/// split matters for shutdown as much as for testing — a media player that
/// leaves `org.mpris.MediaPlayer2.linthra` on the bus after it exits leaves a
/// ghost in every shell that was listening.
class MprisMediaSession implements MediaSession {
  MprisMediaSession._(this._client, this._object, this._subscription, this.name,
      this._coverReady);

  /// The bus name Linthra owns, e.g. `org.mpris.MediaPlayer2.linthra`.
  final String name;

  final DBusClient _client;
  final MprisPlayerObject _object;
  final StreamSubscription<PlaybackState> _subscription;

  /// Covers finishing their prewarm. A track is often published before its
  /// cover is cached, and nothing else would republish it: the diff loop only
  /// runs on a playback state, so a cover that lands while paused would stay
  /// missing from the shell's card for the whole pause.
  final StreamSubscription<Uri>? _coverReady;
  bool _detached = false;

  static const String _baseName = 'org.mpris.MediaPlayer2.linthra';

  /// Connects, claims a name, exports the player object and starts mirroring
  /// [controller]. Returns null when there is no usable session bus.
  ///
  /// Best-effort by design: a headless machine, a Flatpak without the bus
  /// socket, or a shell that never shows up are all "no desktop controls", not
  /// "Linthra failed to start". Anything that goes wrong here is unwound before
  /// returning, so a half-connected client never survives a failed attach.
  static Future<MprisMediaSession?> connect(
    PlaybackController controller, {
    MediaArtworkSource? artwork,
    DBusClientFactory clientFactory = DBusClient.session,
    int? processId,
    DesktopApplicationActions? application,
  }) async {
    DBusClient? client;
    try {
      client = clientFactory();

      // Export before claiming, not after. Taking the name is what puts
      // NameOwnerChanged on the bus, and a shell watching for MPRIS players
      // introspects the moment it sees one. Claiming first leaves a window
      // where /org/mpris/MediaPlayer2 does not exist yet, so that introspect
      // answers UnknownObject and a shell that does not retry discovery just
      // never shows Linthra.
      final MprisPlayerObject object = MprisPlayerObject(
        controller,
        artwork: artwork,
        application: application,
      );
      await client.registerObject(object);

      final String? name = await _claimName(client, processId ?? pid);
      if (name == null) {
        // Both candidates taken. Take the object back off the bus rather than
        // leaving an unnamed export behind on a client we are about to close.
        await client.unregisterObject(object);
        await client.close();
        return null;
      }

      final MprisMediaSession session = MprisMediaSession._(
        client,
        object,
        // Subscribed after both, so the first notification a shell can receive
        // always describes an object it can already read, under a name it has
        // already seen appear.
        controller.stateStream.listen(null),
        name,
        artwork?.coverReady.listen(null),
      );
      session._start(controller);
      return session;
    } catch (_) {
      // Leave nothing half-open behind a failed attach.
      try {
        await client?.close();
      } catch (_) {
        // Closing a client that never connected can throw; ignore.
      }
      return null;
    }
  }

  /// Claims [_baseName], falling back to the spec's per-instance form.
  ///
  /// MPRIS says a player that cannot take the plain name should append
  /// `.instance<pid>`, so a second Linthra window is still individually
  /// controllable instead of silently invisible to every shell.
  ///
  /// The pid is tried first because it is the spec's suggestion and it makes
  /// the name legible in `playerctl -l`, but it cannot be trusted to be unique:
  /// each Flatpak instance has its own pid namespace, so two sandboxed windows
  /// can genuinely both be pid 2. The runner is single-instance since #401, so
  /// a second Linthra is rare rather than routine (a second Flatpak instance,
  /// or a machine with no session bus to register on), but a collision must
  /// still cost a less readable name rather than a window with no media
  /// controls at all, which is what the random suffixes that follow are for.
  static Future<String?> _claimName(DBusClient client, int processId) async {
    final Random random = Random();
    for (final String candidate in <String>[
      _baseName,
      '$_baseName.instance$processId',
      for (int i = 0; i < 8; i++)
        '$_baseName.instance$processId-${random.nextInt(1 << 32)}',
    ]) {
      final DBusRequestNameReply reply = await client.requestName(
        candidate,
        flags: <DBusRequestNameFlag>{DBusRequestNameFlag.doNotQueue},
      );
      if (reply == DBusRequestNameReply.primaryOwner ||
          reply == DBusRequestNameReply.alreadyOwner) {
        return candidate;
      }
    }
    return null;
  }

  /// Mirrors [controller] onto the bus, one `PropertiesChanged` per real change.
  ///
  /// Diffed rather than emitted per tick: the state stream also carries position
  /// updates, and a signal several times a second per listening shell is exactly
  /// the kind of chatter that makes a player unpleasant to have on a desktop.
  /// `Position` is not in the diff at all — the spec has shells extrapolate it
  /// and listen for `Seeked` instead, which the player object emits.
  void _start(PlaybackController controller) {
    Map<String, DBusValue> previous =
        _object.properties(MprisPlayerObject.playerInterface);

    _subscription.onData((PlaybackState _) {
      final Map<String, DBusValue> current =
          _object.properties(MprisPlayerObject.playerInterface);
      final Map<String, DBusValue> changed = <String, DBusValue>{};
      for (final MapEntry<String, DBusValue> entry in current.entries) {
        if (entry.key == 'Position') continue;
        if (previous[entry.key] != entry.value) {
          changed[entry.key] = entry.value;
        }
      }
      previous = current;
      // Position is not a diffed property (the spec has shells extrapolate it),
      // so a seek made in Linthra's own UI has to be announced separately.
      unawaited(_guard(_object.syncSeek));
      if (changed.isEmpty) return;
      unawaited(_emit(changed));
    });

    _coverReady?.onData((Uri _) {
      // Republish Metadata only when the cover actually reached the current
      // track: the prewarm also warms look-ahead covers, and a signal for a
      // track nobody is on is chatter.
      final Map<String, DBusValue> current =
          _object.properties(MprisPlayerObject.playerInterface);
      final DBusValue? metadata = current['Metadata'];
      if (metadata == null || previous['Metadata'] == metadata) return;
      // Only the baseline for what is actually being emitted. Taking all of
      // `current` would mark properties this signal does not carry as already
      // published: a coverReady landing just before a state event would leave
      // CanGoNext or PlaybackStatus looking unchanged to the loop below, and
      // the shell would keep stale controls.
      previous = <String, DBusValue>{...previous, 'Metadata': metadata};
      unawaited(_emit(<String, DBusValue>{'Metadata': metadata}));
    });
  }

  Future<void> _emit(Map<String, DBusValue> changed) async {
    if (_detached) return;
    try {
      await _object.emitPropertiesChanged(
        MprisPlayerObject.playerInterface,
        changedProperties: changed,
      );
    } catch (_) {
      // A shell that vanished, or a bus that went away, must not take playback
      // down with it.
    }
  }

  /// Releases the name, unexports the object and closes the connection.
  ///
  /// Idempotent and never throws: shutdown runs it best-effort alongside every
  /// other teardown step.
  @override
  Future<void> detach() async {
    if (_detached) return;
    _detached = true;
    await _guard(_subscription.cancel);
    if (_coverReady != null) await _guard(_coverReady.cancel);
    await _guard(() => _client.unregisterObject(_object));
    await _guard(() => _client.releaseName(name));
    await _guard(_client.close);
  }

  static Future<void> _guard(Future<void> Function() step) async {
    try {
      await step();
    } catch (_) {
      // Best-effort: one failed step must not skip the ones behind it.
    }
  }
}

/// The Linux [MediaSessionBinding]: MPRIS, or nothing at all.
///
/// Mirrors [AudioServiceMediaSessionBinding]'s shape so
/// [PlatformMediaSessionBinding] routes to it exactly the way it routes to
/// Android's — and so `audio_service` stays untouched on desktop.
class MprisMediaSessionBinding implements MediaSessionBinding {
  const MprisMediaSessionBinding({
    DBusClientFactory clientFactory = DBusClient.session,
  }) : _clientFactory = clientFactory;

  final DBusClientFactory _clientFactory;

  @override
  bool get isSupported => true;

  @override
  Future<MediaSession?> attach(
    PlaybackController controller,
    MusicLibraryRepository library, {
    PlaylistRepository? playlists,
    FavoritesRepository? favorites,
    DownloadRepository? downloads,
    MediaArtworkSource? artwork,
    DesktopApplicationActions? application,
  }) {
    // The repositories are Android Auto's browse tree. MPRIS has no browsing —
    // `HasTrackList` is false — so they are deliberately unused here.
    return MprisMediaSession.connect(
      controller,
      artwork: artwork,
      clientFactory: _clientFactory,
      application: application,
    );
  }
}
