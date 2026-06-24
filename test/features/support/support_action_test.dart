import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/features/support/support_action.dart';

void main() {
  group('SupportAction', () {
    test('an externalLink action exposes its url as a parsed Uri', () {
      const SupportAction action = SupportAction(
        id: 'github-sponsors',
        title: 'GitHub Sponsors',
        description: 'Sponsor on GitHub.',
        icon: Icons.favorite_outline,
        kind: SupportActionKind.externalLink,
        url: 'https://github.com/sponsors/thezupzup',
      );

      expect(action.uri, Uri.parse('https://github.com/sponsors/thezupzup'));
    });

    test('a comingSoon action carries no url', () {
      const SupportAction action = SupportAction(
        id: 'play-supporter',
        title: 'Become a supporter',
        description: 'Coming to the Play Store edition.',
        icon: Icons.card_giftcard_outlined,
        kind: SupportActionKind.comingSoon,
      );

      expect(action.url, isNull);
      expect(action.uri, isNull);
    });

    test('an externalLink action without a url fails the assertion', () {
      expect(
        () => SupportAction(
          id: 'broken',
          title: 'Broken',
          description: 'Missing url.',
          icon: Icons.error_outline,
          kind: SupportActionKind.externalLink,
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('isLaunchableHttpUrl', () {
    test('accepts http and https web links', () {
      expect(
        isLaunchableHttpUrl(Uri.parse('https://github.com/sponsors/thezupzup')),
        isTrue,
      );
      expect(
          isLaunchableHttpUrl(Uri.parse('http://example.org/donate')), isTrue);
    });

    test('rejects null, non-web schemes, and host-less urls', () {
      // The runtime backstop: anything that is not an http(s) web link with a
      // host must fail safe so the screen never hands the OS an odd scheme.
      expect(isLaunchableHttpUrl(null), isFalse);
      expect(
          isLaunchableHttpUrl(Uri.parse('mailto:support@linthra.ca')), isFalse);
      expect(isLaunchableHttpUrl(Uri.parse('tel:+15551234567')), isFalse);
      expect(isLaunchableHttpUrl(Uri.parse('javascript:alert(1)')), isFalse);
      expect(isLaunchableHttpUrl(Uri.parse('file:///etc/passwd')), isFalse);
      expect(isLaunchableHttpUrl(Uri.parse('https://')), isFalse);
    });
  });
}
