import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/media_content_type.dart';

void main() {
  group('MediaContentType.isDocument', () {
    test('is true for pages and error documents', () {
      for (final String type in <String>[
        'text/html',
        'text/html; charset=utf-8',
        'TEXT/HTML',
        'text/xml; charset=utf-8',
        'text/plain',
        'application/json',
        'application/json; charset=UTF-8',
        'application/xml',
        'application/xhtml+xml',
        'application/problem+json',
        'application/atom+xml',
      ]) {
        expect(MediaContentType.isDocument(type), isTrue, reason: type);
      }
    });

    test('is false for media, unknown binary types, and no type', () {
      for (final String? type in <String?>[
        null,
        '',
        'audio/mpeg',
        'audio/flac',
        'audio/ogg; codecs=opus',
        'video/mp4',
        'application/ogg',
        'application/octet-stream',
        'binary/octet-stream',
        'application/x-flac',
      ]) {
        expect(MediaContentType.isDocument(type), isFalse, reason: '$type');
      }
    });
  });
}
