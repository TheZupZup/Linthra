import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/catalog/source_priority.dart';

void main() {
  group('SourcePriority.rankOf', () {
    test('honours the preferred order first', () {
      const priority = SourcePriority(<String>['subsonic', 'jellyfin']);
      expect(
        priority.rankOf('subsonic'),
        lessThan(priority.rankOf('jellyfin')),
      );
      expect(
        priority.rankOf('jellyfin'),
        lessThan(priority.rankOf('local')),
      );
    });

    test('falls back to the default order for unlisted sources', () {
      // Nothing preferred: jellyfin < subsonic < plex < local by the fixed
      // default (remote servers before local).
      expect(
        SourcePriority.fallback.rankOf('jellyfin'),
        lessThan(SourcePriority.fallback.rankOf('subsonic')),
      );
      expect(
        SourcePriority.fallback.rankOf('subsonic'),
        lessThan(SourcePriority.fallback.rankOf('plex')),
      );
      expect(
        SourcePriority.fallback.rankOf('plex'),
        lessThan(SourcePriority.fallback.rankOf('local')),
      );
    });

    test('plex is a known source, ranked ahead of an unknown one', () {
      // Plex now has a deterministic, non-trailing rank rather than sharing the
      // unknown-source tail, so a Plex copy is preferred over a truly unknown
      // provider when both hold the same song.
      const priority = SourcePriority(<String>['jellyfin']);
      expect(
        priority.rankOf('plex'),
        lessThan(priority.rankOf('webdav')),
      );
    });

    test('a preferred source always outranks an only-default one', () {
      const priority = SourcePriority(<String>['local']);
      // Local is promoted, so it now beats jellyfin even though the default
      // order puts jellyfin first.
      expect(priority.rankOf('local'), lessThan(priority.rankOf('jellyfin')));
    });

    test('an unknown source sorts after every known one', () {
      const priority = SourcePriority(<String>['subsonic']);
      expect(
        priority.rankOf('webdav'),
        greaterThan(priority.rankOf('local')),
      );
    });
  });

  group('SourcePriority.promote', () {
    test('moves a source to the front without duplicating it', () {
      const priority = SourcePriority(<String>['jellyfin', 'subsonic']);
      final promoted = priority.promote('subsonic');
      expect(promoted.preferredOrder, <String>['subsonic', 'jellyfin']);
    });

    test('adds a new source at the front', () {
      const priority = SourcePriority(<String>['jellyfin']);
      expect(
        priority.promote('subsonic').preferredOrder,
        <String>['subsonic', 'jellyfin'],
      );
    });

    test('is value-equal when nothing changes', () {
      const priority = SourcePriority(<String>['subsonic', 'jellyfin']);
      expect(priority.promote('subsonic'), priority);
    });
  });
}
