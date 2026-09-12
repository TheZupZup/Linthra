import 'package:flutter/foundation.dart';

/// Whether one configured local music root can be reached **right now**, as
/// opposed to whether it is configured at all.
///
/// Music on a removable drive is the case this exists for. A USB disk, an SSD
/// or any other mount can go away for reasons that have nothing to do with the
/// user changing their mind: the cable is out, the drive was unmounted, the
/// laptop was undocked. None of that is a decision to stop using that folder,
/// so none of it may behave like one.
///
/// So, exactly as with a server source ([SourceAvailability]), configuration
/// and availability are two separate facts. The selection repository answers
/// "which folders did the user choose?" and keeps saying the same thing while a
/// drive is away; this answers "did the configured path answer just now?".
/// Nothing derived from it is destructive: an unavailable root keeps every
/// catalog row it contributed, keeps its place in the user's folder list, and
/// comes back by being plugged in rather than by being selected again.
enum LocalRootAvailability {
  /// The root is configured and no probe has answered for it yet. Deliberately
  /// distinct from [unavailable]: "we have not looked" must never be presented,
  /// or acted on, as "it is gone".
  checking,

  /// The configured path answered: it is there and it can be listed.
  available,

  /// The configured path is there in the user's selection but not reachable
  /// right now: an unplugged or unmounted drive, a network mount that is down,
  /// a revoked portal document, a folder that was moved away.
  ///
  /// Temporary by assumption. The indexed tracks stay, the selection stays, and
  /// the recovery is the drive coming back.
  unavailable,
}

/// Convenience predicates, kept on the enum so every call site branches on the
/// same rules.
extension LocalRootAvailabilityStatus on LocalRootAvailability {
  bool get isAvailable => this == LocalRootAvailability.available;
  bool get isUnavailable => this == LocalRootAvailability.unavailable;
  bool get isChecking => this == LocalRootAvailability.checking;
}

/// One configured root's availability, plus when that was last established.
///
/// A value type, so a Riverpod rebuild only fires on a real change and tests can
/// compare states directly. It carries the configured root and timestamps and
/// nothing else: no error text, no device identity, no substitute path.
@immutable
class LocalRootState {
  const LocalRootState({
    required this.root,
    required this.availability,
    this.lastCheckedAt,
    this.lastAvailableAt,
  });

  /// A newly tracked root: configured, not yet probed.
  const LocalRootState.checking(this.root)
      : availability = LocalRootAvailability.checking,
        lastCheckedAt = null,
        lastAvailableAt = null;

  /// The folder exactly as the user configured it, spelled the way
  /// [LocalMusicRoots.canonicalize] spells it.
  ///
  /// This is the only path this state ever names. A drive that comes back at a
  /// different mount point is a *different* path, and nothing here may quietly
  /// stand in for the configured one.
  final String root;

  final LocalRootAvailability availability;

  /// When a probe last answered for this root, or null when none has.
  final DateTime? lastCheckedAt;

  /// When this root was last found available, or null if it has not been since
  /// the app started. Lets the UI say "last seen …" rather than implying a root
  /// that was never reachable and one that went away a minute ago are the same.
  final DateTime? lastAvailableAt;

  bool get isAvailable => availability.isAvailable;
  bool get isUnavailable => availability.isUnavailable;
  bool get isChecking => availability.isChecking;

  /// This root after a probe answered [available] at [at].
  LocalRootState settled({required bool available, required DateTime at}) {
    return LocalRootState(
      root: root,
      availability: available
          ? LocalRootAvailability.available
          : LocalRootAvailability.unavailable,
      lastCheckedAt: at,
      lastAvailableAt: available ? at : lastAvailableAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalRootState &&
          other.root == root &&
          other.availability == availability &&
          other.lastCheckedAt == lastCheckedAt &&
          other.lastAvailableAt == lastAvailableAt);

  @override
  int get hashCode =>
      Object.hash(root, availability, lastCheckedAt, lastAvailableAt);

  @override
  String toString() => 'LocalRootState($root, ${availability.name})';
}

/// The availability of every configured local root, keyed by root.
///
/// Keyed per root because that is the promise multi-folder support makes: one
/// unplugged drive says nothing about the other folders, which keep scanning,
/// browsing and playing normally. A root this cannot answer for on this
/// platform (an Android SAF tree off Android, a filesystem path on a platform
/// that does not read paths) is simply absent from [roots] rather than
/// reported as gone.
@immutable
class LocalLibraryAvailability {
  const LocalLibraryAvailability(this.roots);

  /// Nothing tracked yet: the starting point, and what a container that never
  /// started the monitor keeps reading.
  const LocalLibraryAvailability.unknown()
      : roots = const <String, LocalRootState>{};

  final Map<String, LocalRootState> roots;

  /// This root's state, or null when it is not tracked (not configured, or not
  /// answerable here).
  LocalRootState? stateFor(String root) => roots[root];

  /// Whether [root] was last found reachable. False for an untracked root: the
  /// caller asked about a folder nothing here can speak for.
  bool isAvailable(String root) => roots[root]?.isAvailable ?? false;

  /// Whether [root] was proven unreachable. Only a settled probe says yes, so
  /// "not checked yet" never reads as "gone".
  bool isUnavailable(String root) => roots[root]?.isUnavailable ?? false;

  Set<String> get availableRoots => <String>{
        for (final LocalRootState state in roots.values)
          if (state.isAvailable) state.root,
      };

  /// The configured roots that are away right now. What the UI lists, and what
  /// a reconnect is waited on for.
  Set<String> get unavailableRoots => <String>{
        for (final LocalRootState state in roots.values)
          if (state.isUnavailable) state.root,
      };

  bool get hasUnavailableRoots =>
      roots.values.any((LocalRootState state) => state.isUnavailable);

  /// Reachability per root in the shape the Settings card reads: a plain
  /// yes/no, with roots nothing has answered for left out entirely.
  Map<String, bool> get reachability => <String, bool>{
        for (final LocalRootState state in roots.values)
          if (!state.isChecking) state.root: state.isAvailable,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalLibraryAvailability && mapEquals(other.roots, roots));

  @override
  int get hashCode => Object.hashAll(<Object?>[
        for (final MapEntry<String, LocalRootState> entry in roots.entries)
          Object.hash(entry.key, entry.value),
      ]);

  @override
  String toString() => 'LocalLibraryAvailability(${roots.values.join(', ')})';
}
