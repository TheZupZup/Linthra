import 'dart:async';

import 'package:dbus/dbus.dart';

import '../../app_info.dart';
import '../../models/playback_state.dart';
import '../../models/repeat_mode.dart';
import '../../models/track.dart';
import '../desktop_application_actions.dart';
import '../media_artwork_source.dart';
import '../playback_controller.dart';

/// The D-Bus object every Linux desktop shell talks to: `/org/mpris/MediaPlayer2`.
///
/// MPRIS is how GNOME's lock screen and top-bar controls, KDE's media applet,
/// `playerctl` and the media keys all discover and drive a player. Implementing
/// it is what makes Linthra a real desktop music player rather than a window
/// that happens to make sound (#397).
///
/// Everything here is a pure translation between the spec's properties/methods
/// and [PlaybackController]. Nothing owns a bus connection, a name, or a
/// subscription — [MprisMediaSession] does — so the whole mapping can be driven
/// and asserted in a unit test with no session bus in sight.
///
/// **What is deliberately not published.** `xesam:url` is part of the spec and
/// is omitted on purpose: for a remote track it is an authenticated stream URL,
/// and for a local one it is the user's file path. Either way it would be
/// readable by every process on the session bus, and no shell needs it to draw
/// a now-playing card. `mpris:artUrl` is filtered the same way the Android media
/// session filters `MediaItem.artUri` — a platform-loadable cover, or the
/// already-cached local copy, never an app-internal reference and never a
/// credentialed URL.
class MprisPlayerObject extends DBusObject {
  MprisPlayerObject(
    this._controller, {
    MediaArtworkSource? artwork,
    DesktopApplicationActions? application,
  })  : _artwork = artwork,
        _application = application,
        super(DBusObjectPath('/org/mpris/MediaPlayer2'));

  static const String rootInterface = 'org.mpris.MediaPlayer2';
  static const String playerInterface = 'org.mpris.MediaPlayer2.Player';

  /// The installed desktop entry, minus its `.desktop` suffix — how a shell
  /// finds Linthra's icon and name. Must stay the app id
  /// `linux/packaging/<app id>.desktop` is installed under.
  static const String desktopEntry = 'io.github.thezupzup.linthra';

  final PlaybackController _controller;
  final MediaArtworkSource? _artwork;

  /// The window and the process behind it, when this build has one it can act
  /// on (#401). Null on a host that cannot raise or quit itself, and then
  /// `CanRaise`/`CanQuit` are false and both methods do nothing, which is what
  /// the spec asks of a player that cannot perform them.
  final DesktopApplicationActions? _application;

  /// A counter behind `mpris:trackid`.
  ///
  /// The spec wants an object path, and a track's own id is arbitrary text (a
  /// file path, a Jellyfin GUID) that cannot be escaped into one safely. A
  /// counter is a valid path, is stable for as long as a track stays current,
  /// and — the useful part — leaks nothing about the library.
  int _trackSerial = 0;
  Track? _trackForSerial;

  PlaybackState get _state => _controller.state;

  // ---------------------------------------------------------------- introspect

  @override
  List<DBusIntrospectInterface> introspect() {
    return <DBusIntrospectInterface>[
      DBusIntrospectInterface(
        rootInterface,
        methods: <DBusIntrospectMethod>[
          DBusIntrospectMethod('Raise'),
          DBusIntrospectMethod('Quit'),
        ],
        properties: <DBusIntrospectProperty>[
          _readable('CanQuit', 'b'),
          _readable('CanRaise', 'b'),
          _readable('HasTrackList', 'b'),
          _readable('Identity', 's'),
          _readable('DesktopEntry', 's'),
          _readable('SupportedUriSchemes', 'as'),
          _readable('SupportedMimeTypes', 'as'),
        ],
      ),
      DBusIntrospectInterface(
        playerInterface,
        methods: <DBusIntrospectMethod>[
          DBusIntrospectMethod('Next'),
          DBusIntrospectMethod('Previous'),
          DBusIntrospectMethod('Pause'),
          DBusIntrospectMethod('PlayPause'),
          DBusIntrospectMethod('Stop'),
          DBusIntrospectMethod('Play'),
          DBusIntrospectMethod('Seek', args: <DBusIntrospectArgument>[
            DBusIntrospectArgument(
                DBusSignature('x'), DBusArgumentDirection.in_,
                name: 'Offset'),
          ]),
          DBusIntrospectMethod('SetPosition', args: <DBusIntrospectArgument>[
            DBusIntrospectArgument(
                DBusSignature('o'), DBusArgumentDirection.in_,
                name: 'TrackId'),
            DBusIntrospectArgument(
                DBusSignature('x'), DBusArgumentDirection.in_,
                name: 'Position'),
          ]),
          DBusIntrospectMethod('OpenUri', args: <DBusIntrospectArgument>[
            DBusIntrospectArgument(
                DBusSignature('s'), DBusArgumentDirection.in_,
                name: 'Uri'),
          ]),
        ],
        signals: <DBusIntrospectSignal>[
          DBusIntrospectSignal('Seeked', args: <DBusIntrospectArgument>[
            DBusIntrospectArgument(
                DBusSignature('x'), DBusArgumentDirection.out,
                name: 'Position'),
          ]),
        ],
        properties: <DBusIntrospectProperty>[
          _readable('PlaybackStatus', 's'),
          DBusIntrospectProperty('LoopStatus', DBusSignature('s'),
              access: DBusPropertyAccess.readwrite),
          _readable('Rate', 'd'),
          DBusIntrospectProperty('Shuffle', DBusSignature('b'),
              access: DBusPropertyAccess.readwrite),
          _readable('Metadata', 'a{sv}'),
          DBusIntrospectProperty('Volume', DBusSignature('d'),
              access: DBusPropertyAccess.readwrite),
          _readable('Position', 'x'),
          _readable('MinimumRate', 'd'),
          _readable('MaximumRate', 'd'),
          _readable('CanGoNext', 'b'),
          _readable('CanGoPrevious', 'b'),
          _readable('CanPlay', 'b'),
          _readable('CanPause', 'b'),
          _readable('CanSeek', 'b'),
          _readable('CanControl', 'b'),
        ],
      ),
    ];
  }

  /// Runs one of the root interface's application actions without waiting for
  /// it. Nothing on this object may block a D-Bus reply, least of all Quit,
  /// whose whole job is to take the connection away.
  void _startApplicationAction(
    Future<void> Function(DesktopApplicationActions actions) action,
  ) {
    final DesktopApplicationActions? actions = _application;
    if (actions == null) return;
    unawaited(action(actions));
  }

  static DBusIntrospectProperty _readable(String name, String signature) =>
      DBusIntrospectProperty(name, DBusSignature(signature),
          access: DBusPropertyAccess.read);

  // ------------------------------------------------------------------- methods

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface == rootInterface) {
      switch (methodCall.name) {
        // Both are accepted whether or not this build can act on them: the
        // spec says a player that cannot perform one should simply do
        // nothing, which is what a null [_application] means here.
        case 'Raise':
          // Bring the window back. In background mode (#401) this is a
          // listener's way home from the shell's media widget when Linthra has
          // no window on screen at all.
          _startApplicationAction((actions) => actions.raise());
          return DBusMethodSuccessResponse();
        case 'Quit':
          // Not awaited on purpose: quitting releases the bus connection this
          // very call came in on, so the reply has to be sent first. The
          // shutdown it starts is the same one an in-app Quit runs.
          _startApplicationAction((actions) => actions.quit());
          return DBusMethodSuccessResponse();
        default:
          return DBusMethodErrorResponse.unknownMethod();
      }
    }
    if (methodCall.interface != playerInterface) {
      return DBusMethodErrorResponse.unknownInterface();
    }

    switch (methodCall.name) {
      case 'Play':
        await _controller.play();
        return DBusMethodSuccessResponse();
      case 'Pause':
        await _controller.pause();
        return DBusMethodSuccessResponse();
      case 'PlayPause':
        // Same test the in-app transport uses (playback_controls.dart): a
        // buffering or reconnecting player is working toward sound, so the
        // toggle has to stop it. Testing `status == playing` made playerctl
        // play-pause call play() mid-buffer, which cannot cancel anything and
        // lets the audio arrive anyway.
        if (_state.isPlaying || _state.isBuffering) {
          await _controller.pause();
        } else {
          await _controller.play();
        }
        return DBusMethodSuccessResponse();
      case 'Stop':
        await _controller.stop();
        return DBusMethodSuccessResponse();
      case 'Next':
        await _controller.skipToNext();
        return DBusMethodSuccessResponse();
      case 'Previous':
        await _controller.skipToPrevious();
        return DBusMethodSuccessResponse();
      case 'Seek':
        return _seek(methodCall);
      case 'SetPosition':
        return _setPosition(methodCall);
      case 'OpenUri':
        // Linthra plays what is in its own library; SupportedUriSchemes is
        // empty, so nothing should call this.
        return DBusMethodErrorResponse.notSupported();
      default:
        return DBusMethodErrorResponse.unknownMethod();
    }
  }

  /// `Seek(x)` — a *relative* jump in microseconds, clamped into the track.
  ///
  /// Whether the current track can be seeked, which is what `CanSeek`
  /// advertises and what both seek methods honour.
  ///
  /// A track with no known duration is still loading (or is a stream), and has
  /// no timeline to seek within.
  bool get _canSeek => _state.duration > Duration.zero;

  /// The spec is explicit that seeking past the end means skipping to the next
  /// track, and that a negative result clamps to zero rather than going back a
  /// track.
  Future<DBusMethodResponse> _seek(DBusMethodCall methodCall) async {
    if (methodCall.signature != DBusSignature('x')) {
      return DBusMethodErrorResponse.invalidArgs();
    }
    // CanSeek is false for a track with no known duration (still loading, or a
    // stream). Seeking one anyway is not just meaningless: on the Linux
    // controller a seek supersedes the in-flight load, so a `playerctl
    // position` against a loading track strands it with no playback at all.
    if (!_canSeek) return DBusMethodSuccessResponse();

    final int offset = (methodCall.values.first as DBusInt64).value;
    final PlaybackState state = _state;
    final Duration target = state.position + Duration(microseconds: offset);

    if (state.duration > Duration.zero && target >= state.duration) {
      await _controller.skipToNext();
      return DBusMethodSuccessResponse();
    }
    await _seekTo(target < Duration.zero ? Duration.zero : target);
    return DBusMethodSuccessResponse();
  }

  /// `SetPosition(o, x)` — an *absolute* seek, guarded by the track id.
  ///
  /// The track-id guard is the point of the method: it stops a stale shell
  /// (one that drew a progress bar for the previous track) from seeking the
  /// track that replaced it. A mismatch is a silent no-op, per the spec.
  Future<DBusMethodResponse> _setPosition(DBusMethodCall methodCall) async {
    if (methodCall.signature != DBusSignature('ox')) {
      return DBusMethodErrorResponse.invalidArgs();
    }
    if (!_canSeek) return DBusMethodSuccessResponse();

    final DBusObjectPath trackId = methodCall.values[0] as DBusObjectPath;
    final int position = (methodCall.values[1] as DBusInt64).value;

    if (trackId.value != _currentTrackId().value) {
      return DBusMethodSuccessResponse();
    }
    final PlaybackState state = _state;
    if (position < 0 ||
        (state.duration > Duration.zero &&
            position > state.duration.inMicroseconds)) {
      return DBusMethodSuccessResponse();
    }
    await _seekTo(Duration(microseconds: position));
    return DBusMethodSuccessResponse();
  }

  /// Seeks and tells the bus about it.
  ///
  /// `Position` deliberately has no `PropertiesChanged` in the spec — it would
  /// be a signal per tick — so a shell tracks it by extrapolating and listening
  /// for `Seeked`. Without this emission a seek from the shell leaves its
  /// progress bar showing the old position until the next track change.
  Future<void> _seekTo(Duration position) async {
    await _controller.seek(position);
    await _announceSeek(position);
  }

  /// Tolerance for calling a position change a seek rather than playback.
  ///
  /// The state stream ticks position while playing, so a small forward step is
  /// ordinary progress. Anything past this did not come from time passing.
  /// Generous on purpose: missing a two-second nudge costs a shell nothing (it
  /// is inside its own extrapolation error), while a false positive would put a
  /// Seeked on the bus every tick.
  static const Duration _seekTolerance = Duration(seconds: 2);

  /// Emits `Seeked` when the position moved in a way playback cannot explain.
  ///
  /// A seek made in Linthra's own UI calls [PlaybackController.seek] directly
  /// and reaches this object only as a changed position on the state stream.
  /// Without this, a shell keeps extrapolating from the old position until the
  /// track changes, so its progress bar silently disagrees with the app.
  /// Called by [MprisMediaSession] on every state.
  Future<void> syncSeek() async {
    final Duration position = _state.position;
    final Object? track = _state.currentTrack;
    final Duration? last = _lastPosition;
    final Object? lastTrack = _lastPositionTrack;
    final bool wasStalled = _wasStalled;
    _lastPosition = position;
    _lastPositionTrack = track;
    _wasStalled = _state.isBuffering;

    // A new track restarts the timeline; that is not a seek.
    if (last == null || !identical(track, lastTrack) && track != lastTrack) {
      return;
    }

    // Coming out of a stall. PlaybackStatus stays Playing through buffering and
    // reconnecting (so the card does not flicker, and so the toggle pauses),
    // which means shells kept extrapolating Position the whole time the engine
    // was frozen. Their bar is now ahead by the length of the stall, and the
    // ticks resuming afterwards are ordinary steps that the tolerance below
    // would never notice. Announcing the real position is the only thing that
    // pulls them back.
    if (wasStalled && !_state.isBuffering) {
      await _announceSeek(position);
      return;
    }

    if ((position - last).abs() <= _seekTolerance) return;
    await _announceSeek(position);
  }

  Future<void> _announceSeek(Duration position) async {
    // Recorded so the state tick that follows a seek made from the bus does not
    // read as a second, separate seek.
    _lastPosition = position;
    _lastPositionTrack = _state.currentTrack;
    await emitSignal(playerInterface, 'Seeked',
        <DBusValue>[DBusInt64(position.inMicroseconds)]);
  }

  Duration? _lastPosition;
  Object? _lastPositionTrack;

  /// Whether the last state seen was buffering or reconnecting, so the return
  /// to playing can be recognised as the end of a stall.
  bool _wasStalled = false;

  // ---------------------------------------------------------------- properties

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    final DBusValue? value = _property(interface, name);
    if (value == null) return DBusMethodErrorResponse.unknownProperty();
    return DBusGetPropertyResponse(value);
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async {
    return DBusGetAllPropertiesResponse(properties(interface));
  }

  @override
  Future<DBusMethodResponse> setProperty(
    String interface,
    String name,
    DBusValue value,
  ) async {
    if (interface != playerInterface) {
      return DBusMethodErrorResponse.unknownProperty();
    }
    switch (name) {
      case 'LoopStatus':
        if (value.signature != DBusSignature('s')) {
          return DBusMethodErrorResponse.invalidArgs();
        }
        final RepeatMode? mode = _repeatModeFor((value as DBusString).value);
        if (mode == null) return DBusMethodErrorResponse.invalidArgs();
        _controller.setRepeatMode(mode);
        return DBusMethodSuccessResponse();
      case 'Shuffle':
        if (value.signature != DBusSignature('b')) {
          return DBusMethodErrorResponse.invalidArgs();
        }
        _controller.setShuffleEnabled((value as DBusBoolean).value);
        return DBusMethodSuccessResponse();
      case 'Volume':
        if (value.signature != DBusSignature('d')) {
          return DBusMethodErrorResponse.invalidArgs();
        }
        // The spec's own advice for a value outside 0.0–1.0 is to clamp it, and
        // a shell's slider can hand over a hair above 1.0 through floating
        // point alone. Setting it above zero unmutes, the same as dragging
        // Linthra's own slider up.
        _controller.setVolume((value as DBusDouble).value);
        return DBusMethodSuccessResponse();
      case 'Rate':
        // Read/write in the spec and read-only here: Linthra's playback seam
        // exposes no playback rate. Saying so is better than accepting a value
        // and silently not applying it.
        return DBusMethodErrorResponse.propertyReadOnly();
      default:
        return DBusMethodErrorResponse.unknownProperty();
    }
  }

  /// Every property of [interface], as the bus sees them right now.
  ///
  /// Also what the change notification is diffed against, so there is one
  /// definition of "the current value" rather than one per call path.
  Map<String, DBusValue> properties(String interface) {
    if (interface == rootInterface) {
      return <String, DBusValue>{
        // True exactly when there is a window/process seam to act on, so a
        // shell only offers Quit and Raise where they do something (#401).
        'CanQuit': DBusBoolean(_application != null),
        'CanRaise': DBusBoolean(_application != null),
        'HasTrackList': const DBusBoolean(false),
        'Identity': const DBusString(AppInfo.name),
        'DesktopEntry': const DBusString(desktopEntry),
        // Empty on purpose: Linthra plays its own library, not arbitrary URIs
        // handed to it over the bus.
        'SupportedUriSchemes': DBusArray.string(const <String>[]),
        'SupportedMimeTypes': DBusArray.string(const <String>[]),
      };
    }
    if (interface != playerInterface) return const <String, DBusValue>{};

    final PlaybackState state = _state;
    return <String, DBusValue>{
      'PlaybackStatus': DBusString(_playbackStatus(state.status)),
      'LoopStatus': DBusString(_loopStatus(state.repeatMode)),
      'Rate': const DBusDouble(1.0),
      'Shuffle': DBusBoolean(state.shuffleEnabled),
      'Metadata': DBusDict.stringVariant(metadata()),
      // The level actually heard, so a mute in Linthra reads as zero on the bus
      // rather than as an unchanged slider in the shell.
      'Volume': DBusDouble(state.effectiveVolume),
      'Position': DBusInt64(state.position.inMicroseconds),
      'MinimumRate': const DBusDouble(1.0),
      'MaximumRate': const DBusDouble(1.0),
      'CanGoNext': DBusBoolean(state.upNext.isNotEmpty),
      'CanGoPrevious': DBusBoolean(state.hasPrevious),
      'CanPlay': DBusBoolean(state.currentTrack != null),
      'CanPause': DBusBoolean(state.currentTrack != null),
      'CanSeek': DBusBoolean(_canSeek),
      'CanControl': const DBusBoolean(true),
    };
  }

  DBusValue? _property(String interface, String name) =>
      properties(interface)[name];

  /// `Metadata` — the now-playing card a shell draws.
  ///
  /// Only fields the catalog actually knows are included: an absent artist is a
  /// missing key, not an empty string, so a shell renders its own layout
  /// instead of a blank line.
  Map<String, DBusValue> metadata() {
    final Track? track = _state.currentTrack;
    if (track == null) return const <String, DBusValue>{};

    final Uri? art = _artUrl(track.artworkUri);
    return <String, DBusValue>{
      'mpris:trackid': _currentTrackId(),
      if (_state.duration > Duration.zero)
        'mpris:length': DBusInt64(_state.duration.inMicroseconds),
      if (art != null) 'mpris:artUrl': DBusString(art.toString()),
      'xesam:title': DBusString(track.title),
      if (track.artistName != null)
        'xesam:artist': DBusArray.string(<String>[track.artistName!]),
      if (track.albumArtistName != null)
        'xesam:albumArtist': DBusArray.string(<String>[track.albumArtistName!]),
      if (track.albumName != null) 'xesam:album': DBusString(track.albumName!),
      if (track.trackNumber != null)
        'xesam:trackNumber': DBusInt32(track.trackNumber!),
    };
  }

  /// The cover a shell can load by itself, or null.
  ///
  /// Same rule as the Android media session's `artUri` for what may be
  /// published: a token-free `http(s)` image or a local `file:` passes through,
  /// an app-internal reference (Subsonic's `subsonic-cover:<id>`) only once its
  /// cover has been cached, and a credentialed URL never reaches the bus.
  ///
  /// Different *form* though. The cache hands Android a `content://` URI backed
  /// by Linthra's FileProvider, which nothing on a Linux desktop can open, so a
  /// shell would fetch nothing and draw no cover. This asks for the same entry
  /// as a `file:` URI instead, and refuses a `content:` it is given directly
  /// rather than publishing one a shell cannot use.
  Uri? _artUrl(Uri? artworkUri) {
    if (artworkUri == null) return null;
    if (artworkUri.isScheme('content')) return null;
    if (isPlatformLoadableArtwork(artworkUri)) return artworkUri;
    return _artwork?.cachedFileUri(artworkUri);
  }

  /// A stable object path for the current track, renewed when the track changes.
  DBusObjectPath _currentTrackId() {
    final Track? track = _state.currentTrack;
    if (track == null) {
      // The spec's reserved "no track" path.
      return DBusObjectPath('/org/mpris/MediaPlayer2/TrackList/NoTrack');
    }
    if (!identical(track, _trackForSerial) && track != _trackForSerial) {
      _trackForSerial = track;
      _trackSerial++;
    }
    return DBusObjectPath('/io/github/thezupzup/linthra/track/$_trackSerial');
  }

  static String _playbackStatus(PlaybackStatus status) {
    switch (status) {
      case PlaybackStatus.playing:
        return 'Playing';
      case PlaybackStatus.buffering:
      case PlaybackStatus.reconnecting:
        // Still Playing: MPRIS has no buffering state, and a player waiting on
        // data is working toward sound rather than stopped by the user. This is
        // the same call the in-app transport makes (`isPlaying || isBuffering`),
        // and it has to agree with PlayPause above, or a shell would draw a play
        // button for a state whose toggle pauses.
        return 'Playing';
      case PlaybackStatus.paused:
      case PlaybackStatus.loading:
        // Loading is "on this track, nothing coming out yet" and settles into
        // playing or paused on its own. Never Stopped for any of these: that
        // would make the card disappear and come back like a crash.
        return 'Paused';
      case PlaybackStatus.idle:
      case PlaybackStatus.completed:
      case PlaybackStatus.error:
        return 'Stopped';
    }
  }

  static String _loopStatus(RepeatMode mode) {
    switch (mode) {
      case RepeatMode.off:
        return 'None';
      case RepeatMode.one:
        return 'Track';
      case RepeatMode.all:
        return 'Playlist';
    }
  }

  static RepeatMode? _repeatModeFor(String loopStatus) {
    switch (loopStatus) {
      case 'None':
        return RepeatMode.off;
      case 'Track':
        return RepeatMode.one;
      case 'Playlist':
        return RepeatMode.all;
      default:
        return null;
    }
  }
}
