import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/shared/widgets/artwork_image.dart';

void main() {
  group('artworkImageProvider', () {
    test('loads a file:// cover from disk with a FileImage', () {
      final provider = artworkImageProvider(
        Uri.parse('file:///data/app/cache/linthra_local_artwork/abc.img'),
      );
      expect(provider, isA<FileImage>());
      expect(
        (provider as FileImage).file.path,
        File('/data/app/cache/linthra_local_artwork/abc.img').path,
      );
    });

    test('loads an http(s) cover over the network with a NetworkImage', () {
      final http = artworkImageProvider(
        Uri.parse('http://server.example/Items/1/Images/Primary'),
      );
      expect(http, isA<NetworkImage>());
      expect(
        (http as NetworkImage).url,
        'http://server.example/Items/1/Images/Primary',
      );

      final https = artworkImageProvider(
        Uri.parse('https://music.example.com/Items/2/Images/Primary'),
      );
      expect(https, isA<NetworkImage>());
      expect(
        (https as NetworkImage).url,
        'https://music.example.com/Items/2/Images/Primary',
      );
    });
  });
}
