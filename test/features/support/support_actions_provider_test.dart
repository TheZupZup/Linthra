import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/features/support/support_action.dart';
import 'package:linthra/features/support/support_actions_provider.dart';

void main() {
  group('SupportDistribution.fromDefine', () {
    test('defaults to fdroid for the empty or unknown dart-define', () {
      expect(SupportDistribution.fromDefine(''), SupportDistribution.fdroid);
      expect(
        SupportDistribution.fromDefine('something-else'),
        SupportDistribution.fdroid,
      );
    });

    test('maps GitHub Release aliases', () {
      for (final String value in <String>[
        'github',
        'GitHub-Release',
        ' release ',
        'apk',
      ]) {
        expect(
          SupportDistribution.fromDefine(value),
          SupportDistribution.githubRelease,
        );
      }
    });

    test('maps Play aliases', () {
      for (final String value in <String>['play', 'PlayStore', '  google ']) {
        expect(
          SupportDistribution.fromDefine(value),
          SupportDistribution.play,
        );
      }
    });
  });

  group('supportLinksEnabledFromDefine', () {
    test('defaults to enabled for the empty or unknown value', () {
      expect(supportLinksEnabledFromDefine(''), isTrue);
      expect(supportLinksEnabledFromDefine('whatever'), isTrue);
      expect(supportLinksEnabledFromDefine('on'), isTrue);
      expect(supportLinksEnabledFromDefine('true'), isTrue);
    });

    test('disables for the off aliases', () {
      for (final String value in <String>[
        'off',
        'false',
        '0',
        'no',
        'disabled',
        '  OFF ',
        'False',
      ]) {
        expect(supportLinksEnabledFromDefine(value), isFalse);
      }
    });
  });

  group('supportActionsFor', () {
    test('F-Droid and GitHub builds offer external support links only', () {
      for (final SupportDistribution distribution in <SupportDistribution>[
        SupportDistribution.fdroid,
        SupportDistribution.githubRelease,
      ]) {
        final List<SupportAction> actions = supportActionsFor(distribution);
        expect(
          actions.map((SupportAction action) => action.id),
          <String>['github-sponsors', 'supporter-model', 'source-code'],
        );
        expect(
          actions.every(
            (SupportAction action) =>
                action.kind == SupportActionKind.externalLink,
          ),
          isTrue,
        );
      }
    });

    test('the Play build adds a disabled purchase placeholder', () {
      final List<SupportAction> actions =
          supportActionsFor(SupportDistribution.play);

      expect(
        actions.map((SupportAction action) => action.id),
        <String>[
          'github-sponsors',
          'supporter-model',
          'source-code',
          'play-supporter',
        ],
      );
      final SupportAction playSeat = actions.last;
      expect(playSeat.kind, SupportActionKind.comingSoon);
      expect(playSeat.url, isNull);
    });

    test('every external action has a launchable HTTPS URL', () {
      for (final SupportDistribution distribution
          in SupportDistribution.values) {
        for (final SupportAction action in supportActionsFor(distribution)) {
          if (action.kind != SupportActionKind.externalLink) {
            continue;
          }
          final Uri? uri = action.uri;
          expect(uri, isNotNull);
          expect(uri!.scheme, 'https');
          expect(uri.host, isNotEmpty);
          expect(isLaunchableHttpUrl(uri), isTrue);
        }
      }
    });
  });
}
