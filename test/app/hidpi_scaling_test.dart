import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:linthra/app/routes.dart';
import 'package:linthra/core/catalog/library_grouping.dart';
import 'package:linthra/core/models/playback_state.dart';
import 'package:linthra/core/models/track.dart';
import 'package:linthra/data/repositories/in_memory_playlist_store.dart';
import 'package:linthra/data/repositories/music_library_repository_provider.dart';
import 'package:linthra/data/repositories/playlist_repository_provider.dart';
import 'package:linthra/features/library/album_detail_screen.dart';
import 'package:linthra/features/library/artist_detail_screen.dart';
import 'package:linthra/features/library/library_screen.dart';
import 'package:linthra/features/player/player_providers.dart';
import 'package:linthra/features/player/player_screen.dart';
import 'package:linthra/shared/layout/adaptive_layout.dart';

import '../features/library/fake_music_library_repository.dart';
import '../features/player/fake_playback_controller.dart';

/// HiDPI and fractional scaling (#457).
///
/// Linux desktops scale in two independent ways, and they do different things
/// to a layout:
///
///   * **Display scaling** raises the device pixel ratio, which *shrinks* the
///     logical size of the same physical window. A 1920x1080 monitor at 150%
///     hands the app 1280x720 logical pixels, so a window that looked roomy at
///     100% is a medium window at 150% and a small one at 200%. Nothing about
///     the text gets relatively bigger; there is simply less room.
///   * **Text scaling** (GNOME's text-scaling-factor, KDE's font DPI) leaves
///     the logical size alone and makes every glyph bigger inside it. That is
///     the one that overflows rows and buttons.
///
/// Real desktops combine them, so the matrix below is expressed the way a user
/// would describe their setup (a monitor and a scale) and every case is
/// pumped at both a plain and an enlarged text scale.
class _Display {
  const _Display(this.label, this.physicalSize, this.devicePixelRatio);

  final String label;
  final Size physicalSize;
  final double devicePixelRatio;

  /// What the app actually lays out in.
  Size get logicalSize => physicalSize / devicePixelRatio;

  @override
  String toString() => '$label '
      '(${logicalSize.width.round()}x${logicalSize.height.round()} logical)';
}

/// The scales the issue asks for, plus the ultrawide shapes that break
/// assumptions in the other direction.
const List<_Display> _displays = <_Display>[
  _Display('1080p at 100%', Size(1920, 1080), 1.0),
  _Display('1080p at 125%', Size(1920, 1080), 1.25),
  _Display('1080p at 150%', Size(1920, 1080), 1.5),
  _Display('1080p at 175%', Size(1920, 1080), 1.75),
  _Display('4K at 200%', Size(3840, 2160), 2.0),
  // A real HiDPI laptop panel, which is where 150% is the vendor default.
  _Display('3:2 laptop at 150%', Size(2256, 1504), 1.5),
  _Display('ultrawide at 100%', Size(3440, 1440), 1.0),
  _Display('ultrawide at 125%', Size(3440, 1440), 1.25),
  // Not a monitor: the floor the Linux runner refuses to resize below, at the
  // scale that makes it smallest in logical pixels.
  _Display('minimum window at 200%', Size(840, 1200), 2.0),
];

/// Text scales worth pumping every display at.
///
/// 1.0 is the default; 1.3 is what GNOME's Large Text gives, and roughly what
/// a 125-130% font DPI on KDE produces on top of display scaling.
const List<TextScaler> _textScales = <TextScaler>[
  TextScaler.noScaling,
  TextScaler.linear(1.3),
  TextScaler.linear(2.0),
];

final List<Track> _tracks = <Track>[
  for (int i = 0; i < 8; i++)
    Track(
      id: '$i',
      title: 'A reasonably long song title number $i',
      uri: 'jellyfin:$i',
      artistName: 'An Artist With A Long Name',
      albumName: i.isEven ? 'Discovery' : 'Homework',
      trackNumber: i + 1,
      duration: const Duration(minutes: 4, seconds: 7),
    ),
];

GoRouter _router(String initialLocation) {
  return GoRouter(
    initialLocation: initialLocation,
    routes: <RouteBase>[
      GoRoute(
        path: AppRoutes.library,
        builder: (_, __) => const LibraryScreen(),
      ),
      GoRoute(
        path: '/library/album/:id',
        builder: (_, GoRouterState s) =>
            AlbumDetailScreen(albumId: s.pathParameters['id']!),
      ),
      GoRoute(
        path: '/library/artist/:id',
        builder: (_, GoRouterState s) =>
            ArtistDetailScreen(artistId: s.pathParameters['id']!),
      ),
      GoRoute(path: AppRoutes.player, builder: (_, __) => const PlayerScreen()),
    ],
  );
}

Future<void> _pumpAt(
  WidgetTester tester,
  _Display display,
  TextScaler textScaler,
  String location,
) async {
  tester.view.devicePixelRatio = display.devicePixelRatio;
  tester.view.physicalSize = display.physicalSize;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        musicLibraryRepositoryProvider.overrideWithValue(
          FakeMusicLibraryRepository(tracks: _tracks),
        ),
        playlistStoreProvider.overrideWithValue(InMemoryPlaylistStore()),
        playbackControllerProvider.overrideWithValue(
          FakePlaybackController(
            initial: PlaybackState(
              status: PlaybackStatus.playing,
              currentTrack: _tracks.first,
              position: const Duration(seconds: 61),
              duration: const Duration(minutes: 4, seconds: 7),
            ),
          ),
        ),
      ],
      child: MaterialApp.router(
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: child!,
        ),
        routerConfig: _router(location),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The routes every scale is checked against, by the name a failure should
/// name.
final Map<String, String> _screens = <String, String>{
  'Library': AppRoutes.library,
  'Album detail': '/library/album/${albumIdForTrack(_tracks.first)}',
  'Artist detail': '/library/artist/${artistIdForTrack(_tracks.first)}',
  'Now Playing': AppRoutes.player,
};

/// Fails with the offending screen named, rather than leaving an unclaimed
/// exception for the harness to report without context.
void _expectNoOverflow(WidgetTester tester, String what) {
  final Object? error = tester.takeException();
  expect(
    error,
    isNull,
    reason: '$what overflowed or threw during layout:\n$error',
  );
}

/// Every rendered paragraph that ran out of room for the lines it was given.
///
/// A `TextOverflow.ellipsis` on a deliberately single-line row is a design
/// decision, not a defect, so this is used against widgets that are supposed to
/// fit: button labels, and the counts and headers beside them.
Iterable<RenderParagraph> _truncated(WidgetTester tester, Finder finder) {
  return finder
      .evaluate()
      .map((Element element) => element.renderObject)
      .whereType<RenderParagraph>()
      .where((RenderParagraph paragraph) => paragraph.didExceedMaxLines);
}

/// The minimum window size the Linux runner enforces, read from the runner
/// itself so this file and `my_application.cc` cannot drift apart.
({double width, double height}) _runnerMinimumWindowSize() {
  final String source =
      File('linux/runner/my_application.cc').readAsStringSync();
  double read(String name) {
    // Plain throw rather than expect(): this runs while the group is being
    // declared, which is outside any test.
    final RegExpMatch? match = RegExp('$name = (\\d+);').firstMatch(source);
    if (match == null) {
      throw StateError('$name is not in linux/runner/my_application.cc');
    }
    return double.parse(match.group(1)!);
  }

  return (
    width: read('kMinimumWindowWidth'),
    height: read('kMinimumWindowHeight'),
  );
}

void main() {
  group('desktop scales lay out without overflow', () {
    for (final _Display display in _displays) {
      for (final TextScaler textScaler in _textScales) {
        final double scale = textScaler.scale(10) / 10;
        testWidgets('$display, text x$scale', (WidgetTester tester) async {
          for (final MapEntry<String, String> screen in _screens.entries) {
            await _pumpAt(tester, display, textScaler, screen.value);
            _expectNoOverflow(
                tester, '${screen.key} at $display, text x$scale');
          }
        });
      }
    }
  });

  group('controls stay usable at every scale', () {
    for (final _Display display in _displays) {
      // Every declared text scale, not just the middle one: 2.0 is the
      // accessibility case, and a control can stay layout-valid there while
      // its label truncates or its tap target shrinks, which the overflow
      // group above cannot see.
      for (final TextScaler textScaler in _textScales) {
        final double scale = textScaler.scale(10) / 10;
        testWidgets(
            '$display, text x$scale keeps the album actions tappable and legible',
            (WidgetTester tester) async {
          await _pumpAt(
            tester,
            display,
            textScaler,
            _screens['Album detail']!,
          );

          final Finder play = find.widgetWithText(FilledButton, 'Play');
          expect(play, findsOneWidget);

          // A primary action's own label must never be the thing that gets cut.
          expect(
            _truncated(
                tester, find.descendant(of: play, matching: find.byType(Text))),
            isEmpty,
            reason: 'the Play label is truncated at $display, text x$scale',
          );

          // Material sizes its own tap targets, but a scaled layout can still
          // squeeze a button below the minimum before anything overflows.
          expect(
            tester.getSize(play).height,
            greaterThanOrEqualTo(kMinInteractiveDimension - 0.01),
            reason: 'the Play button is under the minimum tap height at '
                '$display, text x$scale',
          );

          // tap() hit-tests at the widget's visual centre, so this fails when
          // the painted button and the box that receives the click have
          // drifted apart.
          await tester.tap(play);
          await tester.pumpAndSettle();
          _expectNoOverflow(tester, 'Play at $display, text x$scale');
        });
      }
    }
  });

  group('the minimum window stays usable', () {
    // The runner floors the window at a size "the shared layout can still
    // render without overflowing". That claim is only true if something checks
    // it, and it is most easily broken by enlarged text rather than by width.
    final ({double width, double height}) minimum = _runnerMinimumWindowSize();

    for (final double ratio in <double>[1.0, 1.5, 2.0]) {
      for (final TextScaler textScaler in _textScales) {
        final double scale = textScaler.scale(10) / 10;
        testWidgets(
            'the runner floor at ${ratio}x, text x$scale renders every screen',
            (WidgetTester tester) async {
          final _Display floor = _Display(
            'runner floor at ${ratio}x',
            Size(minimum.width * ratio, minimum.height * ratio),
            ratio,
          );
          for (final MapEntry<String, String> screen in _screens.entries) {
            await _pumpAt(tester, floor, textScaler, screen.value);
            _expectNoOverflow(tester, '${screen.key} at $floor, text x$scale');
          }
        });
      }
    }

    test('the floor is a size the compact layout is written for', () {
      expect(
        windowSizeClassFor(minimum.width),
        WindowSizeClass.compact,
        reason: 'the runner floor must land in the layout class the shared '
            'phone-shaped layout is written for',
      );
      // Display scaling only ever makes the logical window smaller, so the
      // floor is also the worst case: nothing can shrink below it.
      expect(minimum.width, lessThan(mediumWindowWidth));
    });
  });

  group('ultrawide', () {
    // The failure mode at 3440 px is not overflow, it is a track row with its
    // title and its duration a screen apart. The layout caps and centres
    // instead, and that has to survive the scale factors too.
    for (final _Display display in <_Display>[
      _displays.firstWhere((_Display d) => d.label == 'ultrawide at 100%'),
      _displays.firstWhere((_Display d) => d.label == 'ultrawide at 125%'),
    ]) {
      testWidgets('$display caps content instead of stretching it',
          (WidgetTester tester) async {
        await _pumpAt(
          tester,
          display,
          TextScaler.noScaling,
          _screens['Album detail']!,
        );
        _expectNoOverflow(tester, 'Album detail at $display');

        final double windowWidth = display.logicalSize.width;
        expect(
          windowWidth,
          greaterThan(maxPaneLayoutWidth),
          reason: 'this case is only interesting above the cap',
        );

        for (final Element element
            in find.byType(AdaptiveContentWidth).evaluate()) {
          final RenderBox box = element.renderObject! as RenderBox;
          expect(
            box.size.width,
            lessThanOrEqualTo(maxContentWidth + 0.01),
            reason: 'content is stretched past its cap at $display',
          );
        }
      });
    }
  });
}
