import 'package:flutter/foundation.dart';

import '../../../core/sources/plex/plex_exception.dart';

/// Where the Plex connection is in its lifecycle.
enum PlexConnectionPhase {
  /// No session and nothing in progress.
  disconnected,

  /// A connection test is running.
  testing,

  /// A connection test just succeeded (server reachable, token accepted);
  /// nothing is persisted yet.
  tested,

  /// Connect (verify + persist) is running.
  connecting,

  /// Connected — a session exists.
  connected,
}

/// One Plex music library the user can include — the display-safe projection of
/// a `PlexDirectory` (its section `key` and `title`), so the settings UI never
/// touches the wire DTOs. Neither field is a secret.
@immutable
class PlexLibrarySection {
  const PlexLibrarySection({required this.key, required this.title});

  /// The section id used in listing paths (e.g. `"3"`). Server-local, not a
  /// credential.
  final String key;

  final String title;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlexLibrarySection && other.key == key && other.title == title);

  @override
  int get hashCode => Object.hash(key, title);

  @override
  String toString() => 'PlexLibrarySection(key: $key, title: $title)';
}

/// Immutable snapshot the Plex settings UI renders from.
///
/// The screen reads this and never reaches into HTTP, the authenticator, or the
/// session store directly — the controller is the only thing that mutates it.
///
/// Security: this state intentionally holds NO secret. There is no token
/// field; only display-safe values (server URL, server version, library
/// sections) live here, so nothing sensitive can leak through the widget tree
/// or a state dump. The pasted token is forwarded once to the authenticator
/// and never retained outside the (encrypted) session store.
class PlexSettingsState {
  const PlexSettingsState({
    this.phase = PlexConnectionPhase.disconnected,
    this.baseUrl,
    this.serverName,
    this.serverVersion,
    this.sections = const <PlexLibrarySection>[],
    this.isLoadingSections = false,
    this.selectedSectionKeys = const <String>[],
    this.statusMessage,
    this.errorMessage,
    this.errorKind,
  });

  final PlexConnectionPhase phase;

  /// Last connected/tested base URL, for display. Not secret (never carries
  /// the token; Plex API URLs keep the token in a header).
  final String? baseUrl;

  /// The server's friendly name, when known. The manual `/identity` flow
  /// doesn't report one, so this stays `null` until the plex.tv discovery
  /// flow (a follow-up) provides it.
  final String? serverName;

  /// The server's reported version, when known. Display only.
  final String? serverVersion;

  /// The server's **music** libraries discovered for the picker (non-music
  /// sections are filtered out before they reach this state). Empty until
  /// loaded.
  final List<PlexLibrarySection> sections;

  /// True while the library sections are being (re)fetched.
  final bool isLoadingSections;

  /// `key`s of the music libraries the user selected. Empty means connected
  /// but nothing chosen yet — the source then serves an empty library, never
  /// an error.
  final List<String> selectedSectionKeys;

  /// A friendly, non-error status line (e.g. "Connected to Plex…").
  final String? statusMessage;

  /// A friendly error line, when the last action failed. Always secret-free:
  /// every message originates from a static [PlexException] factory.
  final String? errorMessage;

  /// The kind of the last failure, kept for the UI to branch on.
  final PlexErrorKind? errorKind;

  bool get isConnected => phase == PlexConnectionPhase.connected;

  /// True while a network action is in flight, so the UI can disable inputs
  /// and show a spinner.
  bool get isBusy =>
      phase == PlexConnectionPhase.testing ||
      phase == PlexConnectionPhase.connecting;

  /// The "Plex" / "Plex · name" label the section header shows once connected.
  String get displayName {
    final String? name = serverName;
    return (name != null && name.isNotEmpty) ? 'Plex · $name' : 'Plex';
  }

  /// Sentinel distinguishing "not passed" from "explicitly set to null" for
  /// the nullable copyWith parameters below.
  static const Object _unset = Object();

  /// Copies with the given fields replaced. The nullable message fields
  /// ([statusMessage], [errorMessage], [errorKind]) treat an omitted argument
  /// as "keep" and an explicit `null` as "clear", so the controller can update
  /// one flag (e.g. [isLoadingSections]) without resurrecting a stale error.
  PlexSettingsState copyWith({
    PlexConnectionPhase? phase,
    String? baseUrl,
    String? serverName,
    String? serverVersion,
    List<PlexLibrarySection>? sections,
    bool? isLoadingSections,
    List<String>? selectedSectionKeys,
    Object? statusMessage = _unset,
    Object? errorMessage = _unset,
    Object? errorKind = _unset,
  }) {
    return PlexSettingsState(
      phase: phase ?? this.phase,
      baseUrl: baseUrl ?? this.baseUrl,
      serverName: serverName ?? this.serverName,
      serverVersion: serverVersion ?? this.serverVersion,
      sections: sections ?? this.sections,
      isLoadingSections: isLoadingSections ?? this.isLoadingSections,
      selectedSectionKeys: selectedSectionKeys ?? this.selectedSectionKeys,
      statusMessage: identical(statusMessage, _unset)
          ? this.statusMessage
          : statusMessage as String?,
      errorMessage: identical(errorMessage, _unset)
          ? this.errorMessage
          : errorMessage as String?,
      errorKind: identical(errorKind, _unset)
          ? this.errorKind
          : errorKind as PlexErrorKind?,
    );
  }
}
