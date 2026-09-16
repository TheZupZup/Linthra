import 'package:flutter/material.dart';

/// The spinner a screen shows while it has nothing else to show yet.
///
/// A bare `CircularProgressIndicator` is **silent**: Flutter only builds a
/// semantics node for one when it is given a label, so a screen reader landing
/// on a loading Library, Playlists or Downloads found an empty page and no way
/// to tell "still working" from "there is nothing here". Sighted users have the
/// spinning ring; this is the same information for everyone else.
///
/// Deliberately *not* used for every spinner in the app. Where a caption
/// already says what is happening — "Connecting to Living Room…", "Searching
/// for devices…", "Downloading… 40%" — the ring beside it must stay silent, or
/// the same sentence is read twice. This is for the blocking, textless case
/// only, which is exactly the one that used to announce nothing at all.
///
/// Useful beyond TalkBack: Orca reads the same node on Linux, and a `label`
/// that names the thing being loaded ("Loading your library") gives a listener
/// on any platform the context a spinner cannot.
class LoadingIndicator extends StatelessWidget {
  const LoadingIndicator({this.label = 'Loading', super.key});

  /// What is being loaded, as a short phrase. Kept as a plain noun phrase
  /// rather than a sentence, because a screen reader will already be saying it
  /// in the middle of its own announcement.
  final String label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: CircularProgressIndicator(semanticsLabel: label),
    );
  }
}
