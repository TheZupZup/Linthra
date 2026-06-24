import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/features/support/support_action.dart';
import 'package:linthra/features/support/support_actions_provider.dart';

void main() {
  group('SupportDistribution.fromDefine', () {
    test('defaults to fdroid for the empty dart-define', () {
      expect(SupportDistribution.fromDefine(''), SupportDistribution.fdroid);
    });

    test('defaults to fdroid for an unknown value', () {
      expect(
        SupportDistribution.fromDefine('something-else'),
        SupportDistribution.fdroid,
      );
    });

    test('maps the known Play aliases to play, case- and space-insensitively',
        () {
      for (final String value in <String>['play', 'PlayStore', '  google ']) {
        expect(
          SupportDistribution.fromDefine(value),
          SupportDistribution.play,
          reason: '"$value" should select the Play channel',
        );
      }
    });

    test('"fdroid" and "github" resolve to fdroid', () {
      expect(
        SupportDistribution.fromDefine('fdroid'),
        SupportDistribution.fdroid,
      );
      expect(
        SupportDistribution.fromDefine('github'),
        SupportDistribution.fdroid,
      );
    });
  });

  group('supportLinksEnabledFromDefine', () {
    test('defaults to enabled for the empty or unknown value', () {
      expect(supportLinksEnabledFromDefine(''), isTrue);
      expect(supportLinksEnabledFromDefine('whatever'), isTrue);
      expect(supportLinksEnabledFromDefine('on'), isTrue);
      expect(supportLinksEnabledFromDefine('true'), isTrue);
    });

    test('disables for the off aliases, case- and space-insensitively', () {
      for (final String value in <String>[
        'off',
        'false',
        '0',
        'no',
        'disabled',
        '  OFF ',
        'False',
      ]) {
        expect(
          supportLinksEnabledFromDefine(value),
          isFalse,
          reason: '"$value" should disable support links',
        );
      }
    });
  });

  group('supportActionsFor', () {
    test('the F-Droid build offers external links only — no billing seat', () {
      final List<SupportAction> actions =
          supportActionsFor(SupportDistribution.fdroid);

      expect(
        actions.map((SupportAction a) => a.id),
        <String>['github-sponsors', 'supporter-model', 'source-code'],
      );
      // Every F-Droid action is an external link; nothing is a billing/coming
      // -soon placeholder, so an F-Droid build never carries a billing path.
      expect(
        actions.every(
          (SupportAction a) => a.kind == SupportActionKind.externalLink,
        ),
        isTrue,
      );
    });

    test('the Play build adds a disabled supporter-purchase placeholder', () {
      final List<SupportAction> actions =
          supportActionsFor(SupportDistribution.play);

      // The same external links, plus the reserved Play seat at the end.
      expect(
        actions.map((SupportAction a) => a.id),
        <String>[
          'github-sponsors',
          'supporter-model',
          'source-code',
          'play-supporter',
        ],
      );
      final SupportAction playSeat = actions.last;
      expect(playSeat.kind, SupportActionKind.comingSoon);
      // A placeholder only — it opens nothing and pulls in no billing code.
      expect(playSeat.url, isNull);
    });

    test('every external-link action has a well-formed https URL', () {
      for (final SupportDistribution distribution
          in SupportDistribution.values) {
        for (final SupportAction action in supportActionsFor(distribution)) {
          if (action.kind != SupportActionKind.externalLink) {
            continue;
          }
          final Uri? uri = action.uri;
          expect(uri, isNotNull, reason: '${action.id} must have a url');
          expect(uri!.scheme, 'https', reason: '${action.id} must be https');
          expect(uri.host, isNotEmpty);
        }
      }
    });

    test('every shipped support link passes the runtime launch guard', () {
      // The same links the https check above asserts must also satisfy the
      // runtime guard the screen uses, so a correct build never trips it.
      for (final SupportDistribution distribution
          in SupportDistribution.values) {
        for (final SupportAction action in supportActionsFor(distribution)) {
          if (action.kind != SupportActionKind.externalLink) {
            continue;
          }
          expect(
            isLaunchableHttpUrl(action.uri),
            isTrue,
            reason: '${action.id} must be a launchable web link',
          );
        }
      }
    });
  });
}
