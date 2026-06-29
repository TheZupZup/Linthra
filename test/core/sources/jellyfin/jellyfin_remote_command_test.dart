import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/services/remote_command.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_endpoints.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_remote_command.dart';

Map<String, dynamic> playstate(String command, {int? seekTicks}) {
  return <String, dynamic>{
    'MessageType': 'Playstate',
    'Data': <String, dynamic>{
      'Command': command,
      if (seekTicks != null) 'SeekPositionTicks': seekTicks,
    },
  };
}

void main() {
  group('JellyfinRemoteCommand.fromMessage', () {
    test('maps the transport commands to neutral commands', () {
      expect(JellyfinRemoteCommand.fromMessage(playstate('Unpause')),
          const RemotePlay());
      expect(JellyfinRemoteCommand.fromMessage(playstate('Play')),
          const RemotePlay());
      expect(JellyfinRemoteCommand.fromMessage(playstate('Pause')),
          const RemotePause());
      expect(JellyfinRemoteCommand.fromMessage(playstate('PlayPause')),
          const RemotePlayPause());
      expect(JellyfinRemoteCommand.fromMessage(playstate('Stop')),
          const RemoteStop());
      expect(JellyfinRemoteCommand.fromMessage(playstate('NextTrack')),
          const RemoteNext());
      expect(JellyfinRemoteCommand.fromMessage(playstate('PreviousTrack')),
          const RemotePrevious());
    });

    test('maps Seek ticks to a Duration (10M ticks == 1 second)', () {
      expect(
        JellyfinRemoteCommand.fromMessage(
          playstate('Seek', seekTicks: 50000000),
        ),
        const RemoteSeek(Duration(seconds: 5)),
      );
    });

    test('matches the message type and command case-insensitively', () {
      final Map<String, dynamic> message = <String, dynamic>{
        'MessageType': 'playstate',
        'Data': <String, dynamic>{'Command': 'pAuSe'},
      };
      expect(JellyfinRemoteCommand.fromMessage(message), const RemotePause());
    });

    test('ignores a Seek with no/invalid position', () {
      expect(JellyfinRemoteCommand.fromMessage(playstate('Seek')), isNull);
      expect(
        JellyfinRemoteCommand.fromMessage(playstate('Seek', seekTicks: -1)),
        isNull,
      );
    });

    test('ignores unsupported commands and other message types', () {
      expect(JellyfinRemoteCommand.fromMessage(playstate('Rewind')), isNull);
      expect(
        JellyfinRemoteCommand.fromMessage(playstate('FastForward')),
        isNull,
      );
      expect(
        JellyfinRemoteCommand.fromMessage(<String, dynamic>{
          'MessageType': 'GeneralCommand',
          'Data': <String, dynamic>{'Name': 'SetVolume'},
        }),
        isNull,
      );
    });

    test('ignores malformed envelopes', () {
      expect(JellyfinRemoteCommand.fromMessage(<String, dynamic>{}), isNull);
      expect(
        JellyfinRemoteCommand.fromMessage(<String, dynamic>{
          'MessageType': 'Playstate',
          'Data': 'not-a-map',
        }),
        isNull,
      );
      expect(
        JellyfinRemoteCommand.fromMessage(<String, dynamic>{
          'MessageType': 'Playstate',
          'Data': <String, dynamic>{'NoCommand': true},
        }),
        isNull,
      );
    });
  });

  group('JellyfinEndpoints control endpoints', () {
    test('controlSocket builds a wss URL with ApiKey and deviceId', () {
      final Uri uri = JellyfinEndpoints.controlSocket(
        'https://music.example.com',
        accessToken: 'tok',
        deviceId: 'dev-1',
      );
      expect(uri.scheme, 'wss');
      expect(uri.host, 'music.example.com');
      expect(uri.path, '/socket');
      expect(uri.queryParameters['ApiKey'], 'tok');
      expect(uri.queryParameters['deviceId'], 'dev-1');
    });

    test('controlSocket uses ws for an http base and keeps the port', () {
      final Uri uri = JellyfinEndpoints.controlSocket(
        'http://10.0.0.5:8096',
        accessToken: 'tok',
        deviceId: 'dev-1',
      );
      expect(uri.scheme, 'ws');
      expect(uri.host, '10.0.0.5');
      expect(uri.port, 8096);
    });

    test('capabilitiesFull targets the Full capabilities endpoint', () {
      expect(
        JellyfinEndpoints.capabilitiesFull('https://music.example.com')
            .toString(),
        'https://music.example.com/Sessions/Capabilities/Full',
      );
    });
  });
}
