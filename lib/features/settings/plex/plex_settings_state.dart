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

  /// Connect (verify + persist) is running — for the manual flow right after
  /// the form submits, for the sign-in flow right after a server is picked.
  connecting,

  /// Connected — a session exists.
  connected,

  /// "Connect with Plex" handed the sign-in page to the browser and the app
  /// is polling plex.tv for the user's approval. Can run for minutes (the
  /// user is away in the browser); cancellable.
  linking,

  /// The sign-in was approved; the account's Plex Media Servers are being
  /// fetched from plex.tv.
  loadingServers,

  /// The servers are known and the user is choosing one ([PlexSettingsState.
  /// servers] holds the choices — possibly none, the empty state).
  pickingServer,
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

/// One Plex Media Server the user can pick after signing in — the
/// display-safe projection of a `PlexResource`, so the server picker UI (and
/// this state) never touches the token-bearing wire DTO. **No field is a
/// secret**: the per-server access token stays inside the controller's
/// private flow state and the (encrypted) session.
@immutable
class PlexServerChoice {
  const PlexServerChoice({
    required this.clientIdentifier,
    required this.name,
    this.productVersion,
    this.owned = true,
  });

  /// The server's stable identifier (its `machineIdentifier`), used to tell
  /// the controller which server was picked. Not a credential.
  final String clientIdentifier;

  /// The server's friendly name.
  final String name;

  /// The server's reported version, when known. Display only.
  final String? productVersion;

  /// Whether the signed-in account owns this server (vs. shared with it).
  final bool owned;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlexServerChoice &&
          other.clientIdentifier == clientIdentifier &&
          other.name == name &&
          other.productVersion == productVersion &&
          other.owned == owned);

  @override
  int get hashCode =>
      Object.hash(clientIdentifier, name, productVersion, owned);

  @override
  String toString() => 'PlexServerChoice(clientIdentifier: $clientIdentifier, '
      'name: $name, productVersion: $productVersion, owned: $owned)';
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
    this.sectionsLoaded = false,
    this.selectedSectionKeys = const <String>[],
    this.servers = const <PlexServerChoice>[],
    this.statusMessage,
    this.errorMessage,
    this.errorKind,
  });

  final PlexConnectionPhase phase;

  /// Last connected/tested base URL, for display. Not secret (never carries
  /// the token; Plex API URLs keep the token in a header).
  final String? baseUrl;

  /// The server's friendly name, when known. The plex.tv sign-in flow fills
  /// it from the picked server resource; the manual `/identity` flow doesn't
  /// report one, so it stays `null` there.
  final String? serverName;

  /// The server's reported version, when known. Display only.
  final String? serverVersion;

  /// The server's **music** libraries discovered for the picker (non-music
  /// sections are filtered out before they reach this state). Empty until
  /// loaded.
  final List<PlexLibrarySection> sections;

  /// True while the library sections are being (re)fetched.
  final bool isLoadingSections;

  /// True once the music libraries have been fetched successfully at least
  /// once for the current connection. Lets the UI tell "this server has no
  /// music libraries" (loaded, [sections] empty) apart from "they couldn't be
  /// loaded yet" (not loaded — offer a retry instead of a misleading empty
  /// message). Reset on connect/restore/disconnect.
  final bool sectionsLoaded;

  /// `key`s of the music libraries the user selected. Empty means connected
  /// but nothing chosen yet — the source then serves an empty library, never
  /// an error.
  final List<String> selectedSectionKeys;

  /// The signed-in account's Plex Media Servers, for the server picker
  /// ([PlexConnectionPhase.pickingServer] — where an empty list is the "no
  /// servers on this account" empty state, not an error). Display-safe
  /// projections only; the token-bearing resources stay in the controller.
  final List<PlexServerChoice> servers;

  /// A friendly, non-error status line (e.g. "Connected to Plex…").
  final String? statusMessage;

  /// A friendly error line, when the last action failed. Always secret-free:
  /// every message originates from a static [PlexException] factory.
  final String? errorMessage;

  /// The kind of the last failure, kept for the UI to branch on.
  final PlexErrorKind? errorKind;

  bool get isConnected => phase == PlexConnectionPhase.connected;

  /// True while a network action is in flight, so the UI can disable inputs
  /// and show a spinner. [PlexConnectionPhase.linking] is deliberately *not*
  /// busy: it waits on the user (possibly for minutes) and must keep its
  /// Cancel action live.
  bool get isBusy =>
      phase == PlexConnectionPhase.testing ||
      phase == PlexConnectionPhase.connecting ||
      phase == PlexConnectionPhase.loadingServers;

  /// True while the "Connect with Plex" sign-in flow owns the card (waiting
  /// on the browser, loading servers, or picking one) — the phases a Cancel
  /// returns from.
  bool get isLinkFlowActive =>
      phase == PlexConnectionPhase.linking ||
      phase == PlexConnectionPhase.loadingServers ||
      phase == PlexConnectionPhase.pickingServer;

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
    bool? sectionsLoaded,
    List<String>? selectedSectionKeys,
    List<PlexServerChoice>? servers,
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
      sectionsLoaded: sectionsLoaded ?? this.sectionsLoaded,
      selectedSectionKeys: selectedSectionKeys ?? this.selectedSectionKeys,
      servers: servers ?? this.servers,
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
