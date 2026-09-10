import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The Flathub metadata rules that can be checked without building anything
/// (#449).
///
/// `flatpak-builder-lint` is the authority, and CI runs it, but it needs a
/// Flatpak, a 90-minute build for two of its three modes, and a runner with
/// `org.flatpak.Builder` installed. These are the same rules from Flathub's
/// quality guidelines, checked in the second it takes to read a file, so a
/// regression is caught on the PR that causes it rather than in a submission
/// review.
///
/// This is deliberately not a reimplementation of the linter. It covers the
/// handful of rules that are stable, textual, and cheap; everything else is the
/// linter's job.
void main() {
  late String metainfo;
  late String desktop;

  String? tagValue(String tag) {
    final RegExpMatch? match =
        RegExp('<$tag>(.*?)</$tag>', dotAll: true).firstMatch(metainfo);
    return match?.group(1)?.trim();
  }

  setUpAll(() {
    // Comments stripped first: the file's header explains the rules below and
    // names the very tags it is explaining, so a naive match for `<summary>`
    // starts inside the prose and runs to the real closing tag.
    metainfo = File(
      'linux/packaging/io.github.thezupzup.linthra.metainfo.xml',
    ).readAsStringSync().replaceAll(
          RegExp(r'<!--.*?-->', dotAll: true),
          '',
        );
    desktop = File(
      'linux/packaging/io.github.thezupzup.linthra.desktop',
    ).readAsStringSync();
  });

  group('summary', () {
    // Flathub's limit, not AppStream's (which allows about 90). A software
    // centre renders the summary on one line beside the name.
    test('is at most 35 characters', () {
      final String? summary = tagValue('summary');
      expect(summary, isNotNull);
      expect(
        summary!.length,
        lessThanOrEqualTo(35),
        reason: 'Flathub caps the summary at 35 characters; "$summary" is '
            '${summary.length}',
      );
    });

    test('does not end in a period', () {
      expect(tagValue('summary'), isNot(endsWith('.')));
    });

    test('does not start with an article', () {
      final String summary = tagValue('summary')!.toLowerCase();
      for (final String article in <String>['a ', 'an ', 'the ']) {
        expect(
          summary.startsWith(article),
          isFalse,
          reason: 'the summary must not begin with "$article"',
        );
      }
    });

    // "Linthra, a music player" wastes the line: the name is already shown
    // right next to it.
    test('does not repeat the app name', () {
      expect(tagValue('summary')!.toLowerCase(), isNot(contains('linthra')));
    });
  });

  group('name', () {
    test('is at most 20 characters', () {
      final String? name = tagValue('name');
      expect(name, isNotNull);
      expect(name!.length, lessThanOrEqualTo(20));
    });

    test('does not end in a period', () {
      expect(tagValue('name'), isNot(endsWith('.')));
    });
  });

  group('required components', () {
    // Each of these is a hard requirement for a Flathub listing, and each has
    // a different consequence when missing: no id, no listing; no licence,
    // no build; no rating, no age gate; no launchable, an app a software
    // centre will not offer to open.
    test('the metainfo carries what a listing needs', () {
      for (final String required in <String>[
        '<id>io.github.thezupzup.linthra</id>',
        '<metadata_license>',
        '<project_license>',
        '<content_rating type="oars-1.1"',
        '<launchable type="desktop-id">io.github.thezupzup.linthra.desktop'
            '</launchable>',
        '<url type="homepage">',
        '<url type="bugtracker">',
        '<developer id=',
      ]) {
        expect(
          metainfo,
          contains(required),
          reason: 'the metainfo is missing $required',
        );
      }
    });

    test('every release entry carries a version and a date', () {
      final Iterable<RegExpMatch> releases =
          RegExp(r'<release\b[^>]*>').allMatches(metainfo);
      expect(releases, isNotEmpty, reason: 'a listing needs a release history');
      for (final RegExpMatch release in releases) {
        final String tag = release.group(0)!;
        expect(tag, contains('version="'), reason: '$tag has no version');
        expect(tag, contains('date="'), reason: '$tag has no date');
      }
    });
  });

  group('desktop entry', () {
    test('is not a terminal application and has a startup class', () {
      expect(desktop, contains('Terminal=false'));
      expect(
        desktop,
        contains('StartupWMClass=io.github.thezupzup.linthra'),
      );
    });

    // The icon has to be an icon-theme name equal to the app id, or the
    // exported icon does not resolve inside the sandbox.
    test('names the app id as its icon', () {
      expect(desktop, contains('Icon=io.github.thezupzup.linthra'));
    });

    // A `.desktop` file NoDisplay=true would hide the app from the launcher
    // that Flathub exists to put it in.
    test('is visible in a launcher', () {
      expect(desktop, isNot(contains('NoDisplay=true')));
      expect(desktop, isNot(contains('Hidden=true')));
    });
  });

  // #450: the listing must describe the Linux app that actually ships, not
  // everything the codebase can do. A feature reaches this file only after it
  // has been run on Linux, not because a unit test covers it.
  group('claims match what is validated on Linux', () {
    String describedText() {
      final RegExpMatch? match = RegExp(
        '<description>(.*?)</description>',
        dotAll: true,
      ).firstMatch(metainfo);
      return (match?.group(1) ?? '').toLowerCase();
    }

    // Server playback has never been run from the installed Flatpak. The
    // network permission exists (#440), which makes this an easy claim to add
    // by accident and a damaging one to publish.
    test('no streaming provider is advertised', () {
      for (final String provider in <String>[
        'jellyfin',
        'navidrome',
        'subsonic',
        'plex',
      ]) {
        expect(
          describedText(),
          isNot(contains(provider)),
          reason: 'the listing names $provider, but nobody has signed in to a '
              'server from the installed Flatpak and played a track. Validate '
              'it first, then claim it.',
        );
      }
    });

    test('no Android-only feature is advertised', () {
      for (final String feature in <String>[
        'chromecast',
        'android auto',
        'share sheet',
      ]) {
        expect(
          describedText(),
          isNot(contains(feature)),
          reason: '$feature does not exist on Linux',
        );
      }
    });

    // Keywords are what a software centre searches. They are cheap, and a
    // listing without them is much harder to find.
    test('the listing is searchable', () {
      expect(metainfo, contains('<keywords>'));
      expect(metainfo, contains('<keyword>music</keyword>'));
    });
  });

  group('the lint runner is wired up and unsuppressed', () {
    test('CI runs all three linter modes', () {
      final String workflow =
          File('.github/workflows/flatpak-build.yml').readAsStringSync();
      expect(workflow,
          contains('flatpak install --user -y flathub org.flatpak.Builder'));
      expect(workflow,
          contains('--manifest flatpak/io.github.thezupzup.linthra.yml'));
      expect(workflow, contains('--repo flatpak/repo-ci'));
      expect(workflow, contains('--builddir flatpak/flatpak-builder-ci'));
    });

    // #456 requires an empty exceptions file. Adding the first entry should
    // have to change this test, in a diff a reviewer reads.
    test('no linter finding is currently excepted', () {
      final String exceptions =
          File('flatpak/flathub-lint-exceptions.json').readAsStringSync();
      expect(
        exceptions,
        contains('"exceptions": {}'),
        reason: 'an entry here needs a written reason and a reviewer, not a '
            'green check',
      );
    });
  });
}
