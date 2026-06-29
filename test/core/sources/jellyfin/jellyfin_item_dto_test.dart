import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/sources/jellyfin/jellyfin_api.dart';

/// Tolerant parsing of one Jellyfin item. The guarantee under test: a server
/// that omits fields, or sends them with the *wrong type*, yields a safe DTO (or
/// a clean skip) — never a thrown `TypeError` that would abort a whole sync.
void main() {
  group('JellyfinItemDto.fromJson — required fields', () {
    test('parses a full audio item', () {
      final dto = JellyfinItemDto.fromJson(<String, dynamic>{
        'Id': 't1',
        'Name': 'One',
        'Album': 'Album',
        'AlbumId': 'alb-1',
        'AlbumArtist': 'Artist',
        'Artists': <dynamic>['Artist', 'Feature'],
        'RunTimeTicks': 2400000000,
        'IndexNumber': 3,
        'ProductionYear': 1999,
        'ChildCount': 12,
        'ImageTags': <String, dynamic>{'Primary': 'abc'},
      })!;

      expect(dto.id, 't1');
      expect(dto.name, 'One');
      expect(dto.album, 'Album');
      expect(dto.albumArtist, 'Artist');
      expect(dto.artists, <String>['Artist', 'Feature']);
      expect(dto.runTimeTicks, 2400000000);
      expect(dto.indexNumber, 3);
      expect(dto.productionYear, 1999);
      expect(dto.childCount, 12);
      expect(dto.hasPrimaryImage, isTrue);
    });

    test('skips an item with no Id', () {
      expect(
        JellyfinItemDto.fromJson(<String, dynamic>{'Name': 'No id'}),
        isNull,
      );
    });

    test('skips an item with no Name', () {
      expect(
        JellyfinItemDto.fromJson(<String, dynamic>{'Id': 't1'}),
        isNull,
      );
    });

    test('skips an item with a blank / whitespace-only Name', () {
      expect(
        JellyfinItemDto.fromJson(<String, dynamic>{'Id': 't1', 'Name': '   '}),
        isNull,
      );
    });

    test('skips an item whose Id is the wrong type (a number)', () {
      // A weird server sending a numeric Id: coerced to "no usable id" → skip,
      // not a crash.
      expect(
        JellyfinItemDto.fromJson(<String, dynamic>{'Id': 12, 'Name': 'One'}),
        isNull,
      );
    });
  });

  group('JellyfinItemDto.fromJson — missing optional fields use fallbacks', () {
    test('a minimal item (only Id + Name) parses with safe defaults', () {
      final dto = JellyfinItemDto.fromJson(<String, dynamic>{
        'Id': 't1',
        'Name': 'One',
      })!;

      expect(dto.album, isNull);
      expect(dto.albumArtist, isNull);
      expect(dto.artists, isEmpty);
      expect(dto.runTimeTicks, isNull);
      expect(dto.indexNumber, isNull);
      expect(dto.productionYear, isNull);
      expect(dto.childCount, isNull);
      expect(dto.hasPrimaryImage, isFalse);
    });

    test('missing Artists list reads as empty', () {
      final dto = JellyfinItemDto.fromJson(<String, dynamic>{
        'Id': 't1',
        'Name': 'One',
        'AlbumArtist': 'Solo',
      })!;
      expect(dto.artists, isEmpty);
      expect(dto.albumArtist, 'Solo');
    });

    test('missing ImageTags means no primary image', () {
      final dto = JellyfinItemDto.fromJson(<String, dynamic>{
        'Id': 't1',
        'Name': 'One',
        'ImageTags': <String, dynamic>{'Backdrop': 'x'},
      })!;
      expect(dto.hasPrimaryImage, isFalse);
    });

    test('ImageTags as a list (not a map) means no primary image', () {
      // JF12 shape drift: if ImageTags arrives as a list, hasPrimaryImage stays
      // false and the track is still usable — only artwork degrades.
      final dto = JellyfinItemDto.fromJson(<String, dynamic>{
        'Id': 't1',
        'Name': 'One',
        'ImageTags': <dynamic>['Primary', 'Backdrop'],
      })!;
      expect(dto.hasPrimaryImage, isFalse);
    });

    test('ImageTags with a lowercase "primary" key means no primary image', () {
      // The key is matched exactly; a renamed/recased key degrades to no
      // artwork rather than guessing.
      final dto = JellyfinItemDto.fromJson(<String, dynamic>{
        'Id': 't1',
        'Name': 'One',
        'ImageTags': <String, dynamic>{'primary': 'abc'},
      })!;
      expect(dto.hasPrimaryImage, isFalse);
    });
  });

  group('JellyfinItemDto.fromJson — wrong field types never throw', () {
    test('a numeric Album is dropped, not crashed on', () {
      final dto = JellyfinItemDto.fromJson(<String, dynamic>{
        'Id': 't1',
        'Name': 'One',
        'Album': 1999,
      })!;
      expect(dto.album, isNull);
    });

    test('a string RunTimeTicks is coerced from a numeric string', () {
      final dto = JellyfinItemDto.fromJson(<String, dynamic>{
        'Id': 't1',
        'Name': 'One',
        'RunTimeTicks': '2400000000',
      })!;
      expect(dto.runTimeTicks, 2400000000);
    });

    test('a fractional numeric-string RunTimeTicks truncates like a number',
        () {
      // Symmetric with the JSON-number path: "123.9" and 123.9 both truncate.
      final dto = JellyfinItemDto.fromJson(<String, dynamic>{
        'Id': 't1',
        'Name': 'One',
        'RunTimeTicks': '2400000000.9',
      })!;
      expect(dto.runTimeTicks, 2400000000);
    });

    test('a non-numeric string RunTimeTicks falls back to null', () {
      final dto = JellyfinItemDto.fromJson(<String, dynamic>{
        'Id': 't1',
        'Name': 'One',
        'RunTimeTicks': 'not-a-number',
      })!;
      expect(dto.runTimeTicks, isNull);
    });

    test('an explicit null RunTimeTicks reads as null (no throw)', () {
      // JF12 may send the field as JSON null rather than omitting it.
      final dto = JellyfinItemDto.fromJson(<String, dynamic>{
        'Id': 't1',
        'Name': 'One',
        'RunTimeTicks': null,
      })!;
      expect(dto.runTimeTicks, isNull);
    });

    test('a null ProductionYear and a numeric-string ChildCount coerce safely',
        () {
      final dto = JellyfinItemDto.fromJson(<String, dynamic>{
        'Id': 't1',
        'Name': 'One',
        'ProductionYear': null,
        'ChildCount': '12',
      })!;
      expect(dto.productionYear, isNull);
      expect(dto.childCount, 12);
    });

    test('a floating-point RunTimeTicks is truncated to an int', () {
      final dto = JellyfinItemDto.fromJson(<String, dynamic>{
        'Id': 't1',
        'Name': 'One',
        'RunTimeTicks': 2400000000.9,
      })!;
      expect(dto.runTimeTicks, 2400000000);
    });

    test('an Artists value that is a String (not a list) reads as empty', () {
      final dto = JellyfinItemDto.fromJson(<String, dynamic>{
        'Id': 't1',
        'Name': 'One',
        'Artists': 'Not A List',
      })!;
      expect(dto.artists, isEmpty);
    });

    test('non-string entries inside Artists are dropped, good ones kept', () {
      final dto = JellyfinItemDto.fromJson(<String, dynamic>{
        'Id': 't1',
        'Name': 'One',
        'Artists': <dynamic>['Good', 42, null, '', '  ', 'Also Good'],
      })!;
      expect(dto.artists, <String>['Good', 'Also Good']);
    });

    test('a boolean where a number is expected falls back to null', () {
      final dto = JellyfinItemDto.fromJson(<String, dynamic>{
        'Id': 't1',
        'Name': 'One',
        'IndexNumber': true,
        'ProductionYear': <String, dynamic>{'weird': 'object'},
        'ChildCount': <dynamic>[1, 2],
      })!;
      expect(dto.indexNumber, isNull);
      expect(dto.productionYear, isNull);
      expect(dto.childCount, isNull);
    });

    test('a whole grab-bag of wrong types parses without throwing', () {
      // The belt-and-suspenders case: one entry where *every* optional field is
      // the wrong type still yields a usable DTO rather than aborting a sync.
      final dto = JellyfinItemDto.fromJson(<String, dynamic>{
        'Id': 't1',
        'Name': 'One',
        'Album': 7,
        'AlbumId': <dynamic>[],
        'AlbumArtist': false,
        'Artists': 99,
        'RunTimeTicks': <String, dynamic>{},
        'IndexNumber': 'x',
        'ProductionYear': true,
        'ChildCount': 'many',
        'ImageTags': 'not-a-map',
      })!;
      expect(dto.id, 't1');
      expect(dto.name, 'One');
      expect(dto.album, isNull);
      expect(dto.artists, isEmpty);
      expect(dto.hasPrimaryImage, isFalse);
    });
  });

  group('JellyfinItemListing', () {
    test('empty carries no items and no skips', () {
      expect(JellyfinItemListing.empty.items, isEmpty);
      expect(JellyfinItemListing.empty.skippedCount, 0);
    });
  });
}
