import 'package:flutter_test/flutter_test.dart';
import 'package:sonara/core/sources/local/audio_file_types.dart';

void main() {
  group('AudioFileTypes.isSupported', () {
    test('recognizes every supported extension', () {
      const List<String> names = <String>[
        'song.mp3',
        'song.flac',
        'song.m4a',
        'song.aac',
        'song.ogg',
        'song.opus',
        'song.wav',
      ];
      for (final String name in names) {
        expect(AudioFileTypes.isSupported(name), isTrue, reason: name);
      }
    });

    test('is case-insensitive', () {
      expect(AudioFileTypes.isSupported('SONG.MP3'), isTrue);
      expect(AudioFileTypes.isSupported('Song.Flac'), isTrue);
      expect(AudioFileTypes.isSupported('track.OpUs'), isTrue);
    });

    test('matches files inside nested directories', () {
      expect(
        AudioFileTypes.isSupported('/music/Artist/Album/01 - Track.flac'),
        isTrue,
      );
    });

    test('rejects unsupported extensions', () {
      const List<String> names = <String>[
        'cover.jpg',
        'notes.txt',
        'video.mp4',
        'archive.zip',
        'playlist.m3u',
      ];
      for (final String name in names) {
        expect(AudioFileTypes.isSupported(name), isFalse, reason: name);
      }
    });

    test('rejects files with no extension and dotfiles', () {
      expect(AudioFileTypes.isSupported('README'), isFalse);
      expect(AudioFileTypes.isSupported('/music/album/folder'), isFalse);
      expect(AudioFileTypes.isSupported('.DS_Store'), isFalse);
      expect(AudioFileTypes.isSupported('song.'), isFalse);
    });

    test('exposes exactly the seven documented formats', () {
      expect(AudioFileTypes.supportedExtensions, hasLength(7));
      expect(
        AudioFileTypes.supportedExtensions,
        containsAll(<String>[
          'mp3',
          'flac',
          'm4a',
          'aac',
          'ogg',
          'opus',
          'wav',
        ]),
      );
    });
  });
}
