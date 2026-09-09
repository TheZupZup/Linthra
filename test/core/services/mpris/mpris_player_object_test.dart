import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/repeat_mode.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/core/services/desktop_application_actions.dart';
import 'package:linthra/core/services/media_artwork_source.dart';
import 'package:linthra/core/services/mpris/mpris_player_object.dart';

import '../../../features/player/fake_playback_controller.dart';

/// The window and process behind the root interface's Raise and Quit (#401).
class _RecordingApplication implements DesktopApplicationActions {
  int raiseCount = 0;
  int quitCount = 0;

  @override
  Future<void> raise() async => raiseCount++;

  @override
  Future<void> quit() async => quitCount++;
}

/// A cache that has exactly one cover ready, for the artwork-filter tests.
class _Artwork implements MediaArtworkSource {
  _Artwork(this._ready);

  final Map<Uri, Uri> _ready;

  @override
  Uri? cached(Uri reference) => _ready[reference];

  // MPRIS reads this one: the Linux shell needs the file, not the Android
  // content:// wrapper. The fake keeps the same entries so a test that warms a
  // cover gets it back whichever accessor the code under test uses.
  @override
  Uri? cachedFileUri(Uri reference) => _ready[reference];

  @override
  Stream<Uri> get coverReady => const Stream<Uri>.empty();
}

Track _track({
  String id = 't1',
  String title = 'A Song',
  String uri = '/music/a.flac',
  String? artist = 'An Artist',
  String? albumArtist,
  String? album = 'An Album',
  int? trackNumber = 4,
  Uri? artworkUri,
}) =>
    Track(
      id: id,
      title: title,
      uri: uri,
      artistName: artist,
      albumArtistName: albumArtist,
      albumName: album,
      trackNumber: trackNumber,
      artworkUri: artworkUri,
    );

void main() {
  late FakePlaybackController controller;
  late MprisPlayerObject object;

  setUp(() {
    controller = FakePlaybackController();
    object = MprisPlayerObject(controller);
  });

  tearDown(() async {
    await controller.dispose();
  });

  /// Calls a method the way the bus would.
  Future<DBusMethodResponse> call(
    String name, {
    List<DBusValue> values = const <DBusValue>[],
    String interface = MprisPlayerObject.playerInterface,
  }) =>
      object.handleMethodCall(DBusMethodCall(
        sender: ':1.42',
        interface: interface,
        name: name,
        values: values,
      ));

  DBusValue? property(String name) =>
      object.properties(MprisPlayerObject.playerInterface)[name];

  group('identity', () {
    test('names itself the way a shell expects', () {
      final Map<String, DBusValue> root =
          object.properties(MprisPlayerObject.rootInterface);

      expect(root['Identity'], const DBusString('Linthra'));
      // Must match the installed linux/packaging/<app id>.desktop, or the shell
      // shows a generic icon and name.
      expect(root['DesktopEntry'],
          const DBusString('io.github.thezupzup.linthra'));
      expect(root['HasTrackList'], const DBusBoolean(false));
    });

    test('advertises no URI schemes, so nothing hands it foreign media',
        () async {
      final Map<String, DBusValue> root =
          object.properties(MprisPlayerObject.rootInterface);

      expect((root['SupportedUriSchemes']! as DBusArray).children, isEmpty);
      expect(
        await call('OpenUri',
            values: <DBusValue>[const DBusString('http://example/x.mp3')]),
        isA<DBusMethodErrorResponse>(),
      );
    });

    test('Raise and Quit are accepted and do nothing without a window',
        () async {
      // No application seam (Android, or a desktop whose runner cannot do
      // this): the spec says a player that cannot perform them should simply
      // do nothing, and say so through CanRaise/CanQuit.
      final Map<String, DBusValue> root =
          object.properties(MprisPlayerObject.rootInterface);
      expect(root['CanQuit'], const DBusBoolean(false));
      expect(root['CanRaise'], const DBusBoolean(false));

      expect(
        await call('Raise', interface: MprisPlayerObject.rootInterface),
        isA<DBusMethodSuccessResponse>(),
      );
      expect(
        await call('Quit', interface: MprisPlayerObject.rootInterface),
        isA<DBusMethodSuccessResponse>(),
      );
      expect(controller.stopCount, 0);
    });

    test('offers Raise and Quit to the shell when there is a window (#401)',
        () async {
      final _RecordingApplication application = _RecordingApplication();
      final MprisPlayerObject windowed =
          MprisPlayerObject(controller, application: application);

      final Map<String, DBusValue> root =
          windowed.properties(MprisPlayerObject.rootInterface);
      expect(root['CanQuit'], const DBusBoolean(true));
      expect(root['CanRaise'], const DBusBoolean(true));

      // Both answer immediately: Quit takes away the very connection the call
      // arrived on, so the reply cannot wait for it.
      expect(
        await windowed.handleMethodCall(const DBusMethodCall(
          sender: ':1.42',
          interface: MprisPlayerObject.rootInterface,
          name: 'Raise',
        )),
        isA<DBusMethodSuccessResponse>(),
      );
      expect(
        await windowed.handleMethodCall(const DBusMethodCall(
          sender: ':1.42',
          interface: MprisPlayerObject.rootInterface,
          name: 'Quit',
        )),
        isA<DBusMethodSuccessResponse>(),
      );
      await pumpEventQueue();

      expect(application.raiseCount, 1);
      expect(application.quitCount, 1);
    });
  });

  group('transport', () {
    test('Play, Pause, Stop, Next and Previous reach the controller', () async {
      await call('Play');
      await call('Pause');
      await call('Stop');
      await call('Next');
      await call('Previous');

      expect(controller.playCount, 1);
      expect(controller.pauseCount, 1);
      expect(controller.stopCount, 1);
      expect(controller.skipCount, 1);
      expect(controller.previousCount, 1);
    });

    test('PlayPause pauses a buffering player instead of playing it', () async {
      // playerctl play-pause mid-buffer used to call play(), which cannot
      // cancel pending playback: the sound arrived anyway once recovery
      // finished. The in-app transport treats buffering as pauseable and this
      // has to match it.
      for (final PlaybackStatus status in <PlaybackStatus>[
        PlaybackStatus.buffering,
        PlaybackStatus.reconnecting,
      ]) {
        controller.pauseCount = 0;
        controller.playCount = 0;
        controller.emit(PlaybackState(status: status, currentTrack: _track()));

        await call('PlayPause');

        expect(controller.pauseCount, 1, reason: '$status');
        expect(controller.playCount, 0, reason: '$status');
      }
    });

    test('PlayPause pauses while playing and plays otherwise', () async {
      controller.emit(PlaybackState(
        status: PlaybackStatus.playing,
        currentTrack: _track(),
      ));
      await call('PlayPause');
      expect(controller.pauseCount, 1);
      expect(controller.playCount, 0);

      controller.emit(PlaybackState(
        status: PlaybackStatus.paused,
        currentTrack: _track(),
      ));
      await call('PlayPause');
      expect(controller.playCount, 1);
      expect(controller.pauseCount, 1);
    });

    test('an unknown method and a foreign interface are refused', () async {
      expect(await call('Levitate'), isA<DBusMethodErrorResponse>());
      expect(
        await call('Play', interface: 'org.example.Other'),
        isA<DBusMethodErrorResponse>(),
      );
    });
  });

  group('seeking', () {
    setUp(() {
      controller.emit(PlaybackState(
        status: PlaybackStatus.playing,
        currentTrack: _track(),
        position: const Duration(seconds: 30),
        duration: const Duration(seconds: 100),
      ));
    });

    test('Seek moves relative to the current position', () async {
      await call('Seek', values: <DBusValue>[
        DBusInt64(const Duration(seconds: 10).inMicroseconds)
      ]);

      expect(controller.seeks, <Duration>[const Duration(seconds: 40)]);
    });

    test('seeking back past the start clamps to zero', () async {
      await call('Seek', values: <DBusValue>[
        DBusInt64(const Duration(minutes: -5).inMicroseconds)
      ]);

      expect(controller.seeks, <Duration>[Duration.zero]);
    });

    test('seeking past the end skips to the next track', () async {
      await call('Seek', values: <DBusValue>[
        DBusInt64(const Duration(minutes: 5).inMicroseconds)
      ]);

      expect(controller.skipCount, 1);
      expect(controller.seeks, isEmpty);
    });

    test('SetPosition seeks absolutely when the track id matches', () async {
      final DBusObjectPath trackId =
          (object.metadata()['mpris:trackid']! as DBusObjectPath);

      await call('SetPosition', values: <DBusValue>[
        trackId,
        DBusInt64(const Duration(seconds: 12).inMicroseconds),
      ]);

      expect(controller.seeks, <Duration>[const Duration(seconds: 12)]);
    });

    test('SetPosition for a track that is no longer current does nothing',
        () async {
      // The stale-shell case the track-id guard exists for: a progress bar
      // drawn for the previous track must not seek the one that replaced it.
      await call('SetPosition', values: <DBusValue>[
        DBusObjectPath('/io/github/thezupzup/linthra/track/999'),
        DBusInt64(const Duration(seconds: 12).inMicroseconds),
      ]);

      expect(controller.seeks, isEmpty);
    });

    test('SetPosition outside the track is ignored', () async {
      final DBusObjectPath trackId =
          (object.metadata()['mpris:trackid']! as DBusObjectPath);

      await call('SetPosition',
          values: <DBusValue>[trackId, const DBusInt64(-1)]);
      await call('SetPosition', values: <DBusValue>[
        trackId,
        DBusInt64(const Duration(hours: 1).inMicroseconds),
      ]);

      expect(controller.seeks, isEmpty);
    });

    test('wrong argument types are rejected, not guessed at', () async {
      expect(
        await call('Seek', values: <DBusValue>[const DBusString('a bit')]),
        isA<DBusMethodErrorResponse>(),
      );
      expect(
        await call('SetPosition', values: <DBusValue>[const DBusInt64(0)]),
        isA<DBusMethodErrorResponse>(),
      );
      expect(controller.seeks, isEmpty);
    });
  });

  group('status', () {
    test('playing, paused and stopped map to the spec\'s three values', () {
      controller.emit(const PlaybackState(status: PlaybackStatus.playing));
      expect(property('PlaybackStatus'), const DBusString('Playing'));

      controller.emit(const PlaybackState(status: PlaybackStatus.paused));
      expect(property('PlaybackStatus'), const DBusString('Paused'));

      controller.emit(const PlaybackState(status: PlaybackStatus.idle));
      expect(property('PlaybackStatus'), const DBusString('Stopped'));
    });

    test('buffering and reconnecting still read as playing', () {
      // MPRIS has no buffering state, and a player waiting on data is working
      // toward sound rather than stopped by the user. Same call the in-app
      // transport makes, and it has to agree with PlayPause, or a shell draws a
      // play button for a state whose toggle pauses.
      for (final PlaybackStatus status in <PlaybackStatus>[
        PlaybackStatus.buffering,
        PlaybackStatus.reconnecting,
      ]) {
        controller.emit(PlaybackState(status: status, currentTrack: _track()));
        expect(property('PlaybackStatus'), const DBusString('Playing'),
            reason: '$status');
      }
    });

    test('loading reads as paused, and nothing mid-recovery reads as stopped',
        () {
      // Reporting Stopped would make the shell's now-playing card disappear and
      // come back, which looks like a crash.
      controller.emit(PlaybackState(
          status: PlaybackStatus.loading, currentTrack: _track()));
      expect(property('PlaybackStatus'), const DBusString('Paused'));

      for (final PlaybackStatus status in <PlaybackStatus>[
        PlaybackStatus.loading,
        PlaybackStatus.buffering,
        PlaybackStatus.reconnecting,
      ]) {
        controller.emit(PlaybackState(status: status, currentTrack: _track()));
        expect(property('PlaybackStatus'), isNot(const DBusString('Stopped')),
            reason: '$status');
      }
    });

    test('an error stops rather than pretending to play', () {
      controller.emit(const PlaybackState(status: PlaybackStatus.error));
      expect(property('PlaybackStatus'), const DBusString('Stopped'));
    });
  });

  group('seeking a track that cannot be seeked', () {
    // CanSeek is false without a known duration. Honouring it is not cosmetic:
    // on the Linux controller a seek supersedes the in-flight load, so seeking
    // a still-loading track strands it with no playback at all.
    test('CanSeek is false while the duration is unknown', () {
      controller.emit(PlaybackState(
          status: PlaybackStatus.loading, currentTrack: _track()));
      expect(property('CanSeek'), const DBusBoolean(false));
    });

    test('Seek does nothing when CanSeek is false', () async {
      controller.emit(PlaybackState(
          status: PlaybackStatus.loading, currentTrack: _track()));

      await call('Seek', values: <DBusValue>[const DBusInt64(5000000)]);

      expect(controller.seeks, isEmpty);
    });

    test('SetPosition does nothing when CanSeek is false', () async {
      controller.emit(PlaybackState(
          status: PlaybackStatus.loading, currentTrack: _track()));

      await call('SetPosition', values: <DBusValue>[
        DBusObjectPath('/io/github/thezupzup/linthra/track/1'),
        const DBusInt64(5000000),
      ]);

      expect(controller.seeks, isEmpty);
    });
  });

  group('metadata', () {
    test('publishes what the catalog knows', () {
      controller.emit(PlaybackState(
        status: PlaybackStatus.playing,
        currentTrack: _track(albumArtist: 'The Album Artist'),
        duration: const Duration(minutes: 3, seconds: 20),
      ));

      final Map<String, DBusValue> metadata = object.metadata();

      expect(metadata['xesam:title'], const DBusString('A Song'));
      expect((metadata['xesam:artist']! as DBusArray).children,
          <DBusValue>[const DBusString('An Artist')]);
      expect((metadata['xesam:albumArtist']! as DBusArray).children,
          <DBusValue>[const DBusString('The Album Artist')]);
      expect(metadata['xesam:album'], const DBusString('An Album'));
      expect(metadata['xesam:trackNumber'], const DBusInt32(4));
      expect(metadata['mpris:length'],
          DBusInt64(const Duration(minutes: 3, seconds: 20).inMicroseconds));
    });

    test('never publishes the track URI', () {
      // The requirement this whole class is careful about: for a remote track
      // that URI is an authenticated stream URL, and for a local one it is the
      // user's file path. Everything on the session bus could read it.
      controller.emit(PlaybackState(
        status: PlaybackStatus.playing,
        currentTrack: _track(uri: 'https://music.example/stream?token=secret'),
      ));

      final Map<String, DBusValue> metadata = object.metadata();

      expect(metadata.containsKey('xesam:url'), isFalse);
      expect(metadata.values.map((DBusValue v) => v.toString()).join(),
          isNot(contains('secret')));
    });

    test('an absent field is a missing key, not an empty string', () {
      controller.emit(PlaybackState(
        status: PlaybackStatus.playing,
        currentTrack: _track(artist: null, album: null, trackNumber: null),
      ));

      final Map<String, DBusValue> metadata = object.metadata();

      expect(metadata.containsKey('xesam:artist'), isFalse);
      expect(metadata.containsKey('xesam:album'), isFalse);
      expect(metadata.containsKey('xesam:trackNumber'), isFalse);
      expect(metadata['xesam:title'], const DBusString('A Song'));
    });

    test('nothing playing publishes the reserved no-track id', () {
      expect(object.metadata(), isEmpty);
      expect(
        object.properties(MprisPlayerObject.playerInterface)['Metadata'],
        DBusDict.stringVariant(const <String, DBusValue>{}),
      );
    });

    test('the track id is stable per track and changes with it', () {
      controller.emit(PlaybackState(currentTrack: _track(uri: '/a.flac')));
      final DBusValue first = object.metadata()['mpris:trackid']!;
      expect(object.metadata()['mpris:trackid'], first,
          reason: 'the id must not change while the track is still current');

      controller.emit(PlaybackState(currentTrack: _track(uri: '/b.flac')));
      expect(object.metadata()['mpris:trackid'], isNot(first));
    });
  });

  group('artwork', () {
    test('a local cover is published as-is', () {
      final Uri cover = Uri.file('/home/someone/.cache/linthra/cover.jpg');
      controller.emit(PlaybackState(
        currentTrack: _track(artworkUri: cover),
      ));

      expect(object.metadata()['mpris:artUrl'], DBusString(cover.toString()));
    });

    test('an app-internal reference is not published until it is cached', () {
      final Uri reference = Uri.parse('subsonic-cover:al-12');
      controller
          .emit(PlaybackState(currentTrack: _track(artworkUri: reference)));

      expect(
          MprisPlayerObject(controller).metadata().containsKey('mpris:artUrl'),
          isFalse,
          reason: 'a reference is not a URL any shell can load');

      final Uri cached = Uri.file('/tmp/cover.jpg');
      final MprisPlayerObject withCache = MprisPlayerObject(
        controller,
        artwork: _Artwork(<Uri, Uri>{reference: cached}),
      );
      expect(
          withCache.metadata()['mpris:artUrl'], DBusString(cached.toString()));
    });
  });

  group('modes', () {
    test('LoopStatus reports the repeat mode', () {
      expect(property('LoopStatus'), const DBusString('None'));

      controller.emit(const PlaybackState(repeatMode: RepeatMode.one));
      expect(property('LoopStatus'), const DBusString('Track'));

      controller.emit(const PlaybackState(repeatMode: RepeatMode.all));
      expect(property('LoopStatus'), const DBusString('Playlist'));
    });

    test('setting LoopStatus changes the repeat mode', () async {
      await object.setProperty(MprisPlayerObject.playerInterface, 'LoopStatus',
          const DBusString('Playlist'));

      expect(controller.state.repeatMode, RepeatMode.all);
      expect(property('LoopStatus'), const DBusString('Playlist'));
    });

    test('Shuffle reports whether shuffle is on', () {
      expect(property('Shuffle'), const DBusBoolean(false));

      controller.emit(const PlaybackState(shuffleEnabled: true));
      expect(property('Shuffle'), const DBusBoolean(true));
    });

    test('setting Shuffle turns shuffle on', () async {
      await object.setProperty(MprisPlayerObject.playerInterface, 'Shuffle',
          const DBusBoolean(true));

      expect(controller.state.shuffleEnabled, isTrue);
      expect(property('Shuffle'), const DBusBoolean(true));
    });

    test('a LoopStatus the spec does not define is refused', () async {
      expect(
        await object.setProperty(MprisPlayerObject.playerInterface,
            'LoopStatus', const DBusString('Sometimes')),
        isA<DBusMethodErrorResponse>(),
      );
      expect(controller.state.repeatMode, RepeatMode.off);
    });

    test('Rate says it is read-only rather than lying', () async {
      // Linthra's playback seam has no playback rate, so accepting a value and
      // not applying it would leave a shell's control permanently wrong.
      expect(
        await object.setProperty(
            MprisPlayerObject.playerInterface, 'Rate', const DBusDouble(2)),
        isA<DBusMethodErrorResponse>(),
      );
    });

    test('Volume reports the level actually heard', () {
      expect(property('Volume'), const DBusDouble(1.0));

      controller.setVolume(0.4);
      expect(property('Volume'), const DBusDouble(0.4));

      // Muted reads as silent on the bus, without losing the stored level.
      controller.setMuted(true);
      expect(property('Volume'), const DBusDouble(0.0));

      controller.setMuted(false);
      expect(property('Volume'), const DBusDouble(0.4));
    });

    test('setting Volume from the bus changes playback', () async {
      expect(
        await object.setProperty(MprisPlayerObject.playerInterface, 'Volume',
            const DBusDouble(0.25)),
        isA<DBusMethodSuccessResponse>(),
      );

      expect(controller.state.volume, 0.25);
      expect(property('Volume'), const DBusDouble(0.25));
    });

    test('a Volume outside the spec range is clamped, not refused', () async {
      expect(
        await object.setProperty(
            MprisPlayerObject.playerInterface, 'Volume', const DBusDouble(1.4)),
        isA<DBusMethodSuccessResponse>(),
      );
      expect(controller.state.volume, 1.0);

      expect(
        await object.setProperty(
            MprisPlayerObject.playerInterface, 'Volume', const DBusDouble(-2)),
        isA<DBusMethodSuccessResponse>(),
      );
      expect(controller.state.volume, 0.0);
    });

    test('setting Volume above zero unmutes', () async {
      controller.setVolume(0.6);
      controller.setMuted(true);

      await object.setProperty(
          MprisPlayerObject.playerInterface, 'Volume', const DBusDouble(0.3));

      expect(controller.state.muted, isFalse);
      expect(controller.state.volume, 0.3);
    });

    test('a Volume of the wrong type is refused', () async {
      expect(
        await object.setProperty(MprisPlayerObject.playerInterface, 'Volume',
            const DBusString('loud')),
        isA<DBusMethodErrorResponse>(),
      );
      expect(controller.state.volume, 1.0);
    });
  });

  group('capabilities', () {
    test('nothing playing means nothing to control', () {
      expect(property('CanPlay'), const DBusBoolean(false));
      expect(property('CanPause'), const DBusBoolean(false));
      expect(property('CanGoNext'), const DBusBoolean(false));
      expect(property('CanGoPrevious'), const DBusBoolean(false));
      expect(property('CanSeek'), const DBusBoolean(false));
      // Always true: Linthra does answer the interface.
      expect(property('CanControl'), const DBusBoolean(true));
    });

    test('a queue enables next, a history enables previous', () {
      controller.emit(PlaybackState(
        currentTrack: _track(),
        upNext: <Track>[_track(uri: '/b.flac')],
        hasPrevious: true,
        duration: const Duration(minutes: 2),
      ));

      expect(property('CanPlay'), const DBusBoolean(true));
      expect(property('CanPause'), const DBusBoolean(true));
      expect(property('CanGoNext'), const DBusBoolean(true));
      expect(property('CanGoPrevious'), const DBusBoolean(true));
      expect(property('CanSeek'), const DBusBoolean(true));
    });

    test('a track with no known duration cannot be seeked', () {
      controller.emit(PlaybackState(currentTrack: _track()));

      expect(property('CanSeek'), const DBusBoolean(false));
    });
  });

  group('property access', () {
    test('getProperty answers a known one and refuses an unknown one',
        () async {
      expect(
        await object.getProperty(
            MprisPlayerObject.playerInterface, 'PlaybackStatus'),
        isA<DBusGetPropertyResponse>(),
      );
      expect(
        await object.getProperty(
            MprisPlayerObject.playerInterface, 'Telepathy'),
        isA<DBusMethodErrorResponse>(),
      );
    });

    test('getAllProperties covers both interfaces', () async {
      final DBusMethodResponse player =
          await object.getAllProperties(MprisPlayerObject.playerInterface);
      final DBusMethodResponse root =
          await object.getAllProperties(MprisPlayerObject.rootInterface);

      expect(player, isA<DBusGetAllPropertiesResponse>());
      expect(root, isA<DBusGetAllPropertiesResponse>());
    });

    test('introspection lists both interfaces', () {
      expect(
        object.introspect().map((DBusIntrospectInterface i) => i.name),
        containsAll(<String>[
          MprisPlayerObject.rootInterface,
          MprisPlayerObject.playerInterface,
        ]),
      );
    });
  });
}
