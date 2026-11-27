import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'linthra_core_ffi.dart';

/// The search's mixed-result order in the Rust core
/// (native/linthra_core/src/search_rank.rs).
///
/// Use `rankSearchResults`, which calls this.
abstract final class NativeSearchRank {
  /// The positions of the results ([kinds] as `SearchResultKind.index`, with
  /// their [names]) in the order to show them for [query].
  static List<int> rank(String query, List<int> kinds, List<String> names) {
    final int count = kinds.length;
    final Uint8List queryBytes = utf8.encode(query);
    final BytesBuilder text = BytesBuilder(copy: false);
    final List<int> spans = <int>[];
    for (final String name in names) {
      final Uint8List bytes = utf8.encode(name);
      spans
        ..add(text.length)
        ..add(bytes.length);
      text.add(bytes);
    }
    final Uint8List textBytes = text.takeBytes();
    return using((Arena arena) {
      final Pointer<Uint8> q = arena<Uint8>(queryBytes.length + 1);
      q.asTypedList(queryBytes.length).setAll(0, queryBytes);
      final Pointer<Uint8> t = arena<Uint8>(textBytes.length + 1);
      t.asTypedList(textBytes.length).setAll(0, textBytes);
      final Pointer<Uint8> k = arena<Uint8>(count + 1);
      k.asTypedList(count).setAll(0, kinds);
      final Pointer<Uint32> s = arena<Uint32>(2 * count + 1);
      s.asTypedList(2 * count).setAll(0, spans);
      final Pointer<Uint32> out = arena<Uint32>(count + 1);
      final int status = linthraSearchRank(
        q,
        queryBytes.length,
        t,
        textBytes.length,
        k,
        s,
        count,
        out,
      );
      // Every span was written here from Dart strings, so a refusal means the
      // two sides of the ABI disagree.
      if (status != LinthraStatus.ok) {
        throw StateError('linthra_search_rank refused its input');
      }
      return List<int>.of(out.asTypedList(count));
    });
  }
}
