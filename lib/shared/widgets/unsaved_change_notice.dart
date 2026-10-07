import 'package:flutter/material.dart';

import '../../core/repositories/local_store_write_exception.dart';

/// Runs [change], something the listener just did to their favourites or
/// playlists, and says so through [messenger] when the device refused to save
/// it. Returns what [change] returned, or null when it was refused.
///
/// A refused change is left undone by the repository (#808), so without this
/// the tap would look like it did nothing. [what] names what wasn't saved when
/// part of the action already was (a playlist created, then its songs
/// refused). Any other error is not this one's to explain and is rethrown.
Future<T?> saveOrReport<T>(
  ScaffoldMessengerState? messenger,
  Future<T> Function() change, {
  String? what,
}) async {
  try {
    return await change();
  } on LocalStoreWriteException catch (error) {
    messenger?.showSnackBar(
      SnackBar(content: Text(unsavedChangeMessage(error.area, what: what))),
    );
    return null;
  }
}

/// What the listener is told when a change to [area], or [what] in it, could
/// not be saved.
String unsavedChangeMessage(LocalStoreArea area, {String? what}) {
  final String unsaved = what ??
      switch (area) {
        LocalStoreArea.favorites => 'that favorite',
        LocalStoreArea.playlists => 'that playlist change',
        LocalStoreArea.playHistory => 'your listening history',
      };
  return "Couldn't save $unsaved. Check that your device has free storage, "
      'then try again.';
}
