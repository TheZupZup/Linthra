import 'package:flutter/material.dart';

import '../../core/sources/source_availability.dart';

/// The visual weight one source's status carries in the sidebar.
///
/// Only ever mapped to theme tokens by the widget that renders it, so the brand
/// palette stays the single source of truth for colour. It is deliberately a
/// three-value scale rather than a colour: "this needs you" and "this is fine"
/// are the only distinctions the sidebar has room to make.
enum SourceStatusTone {
  /// Everything is answering. Rendered quietly — a healthy sidebar should read
  /// as no news at all.
  healthy,

  /// Nothing is wrong, but nothing is settled either.
  neutral,

  /// The source cannot serve music right now and the user is the fix.
  attention,
}

/// What the sidebar says about one configured source: a glyph, a short word,
/// and the sentence a tooltip and a screen reader both read.
///
/// This is the one place a [SourceAvailability] becomes something a person can
/// see, so Jellyfin, Navidrome and Plex cannot drift into describing the same
/// state three different ways. A provider-specific widget conditional is
/// exactly what this exists to prevent: a source that starts publishing
/// availability gets its indicator, its tooltip and its semantics for free.
///
/// **Security.** The only source-identifying text that ever reaches here is the
/// caller's [sourceName], which callers take from `PlaybackSourceLabel`'s fixed
/// vocabulary ("Jellyfin", "Navidrome", "Plex"). There is no field a server URL,
/// hostname, username, token or exception string could travel in, and
/// [describe] composes its sentence from that name and a constant — so no
/// call site can widen it by passing something richer.
@immutable
class SourceStatusPresentation {
  const SourceStatusPresentation({
    required this.icon,
    required this.tone,
    required this.label,
    required this.description,
    required this.needsAttention,
  });

  /// The status glyph. Shares its vocabulary with the library row's
  /// `TrackStatusGlyph` on purpose: a row saying "Jellyfin unavailable" and a
  /// sidebar saying the same thing should not use two different clouds.
  final IconData icon;

  final SourceStatusTone tone;

  /// One word for the state ("Connected", "Unreachable"), for a compact chip or
  /// a test to assert on.
  final String label;

  /// The full sentence — "Jellyfin unavailable" — used as the tooltip and as
  /// the accessible label. Already contains the source name.
  final String description;

  /// Whether this state is the user's to fix. Drives whether the sidebar draws
  /// a coloured badge or stays quiet, and whether the row offers to open the
  /// connection settings.
  final bool needsAttention;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SourceStatusPresentation &&
          other.icon == icon &&
          other.tone == tone &&
          other.label == label &&
          other.description == description &&
          other.needsAttention == needsAttention);

  @override
  int get hashCode =>
      Object.hash(icon, tone, label, description, needsAttention);

  @override
  String toString() => 'SourceStatusPresentation($label)';
}

/// How [availability] should read for a source called [sourceName], or `null`
/// when there is nothing to show.
///
/// `null` is returned only for [SourceAvailability.notConfigured] — a source the
/// user never set up has no status, and the sidebar must not list it at all
/// (an empty row saying "not connected" is the visual noise this feature is
/// supposed to avoid). Every other state resolves, so the switch cannot rot
/// when a new availability lands.
///
/// Pure and total: no clock, no network, no provider lookup. Whatever staged
/// this state — a real probe, a test, a source that publishes nothing yet — the
/// answer is the same, which is what lets a widget test cover the states a real
/// server is awkward to hold in.
SourceStatusPresentation? sourceStatusPresentation(
  SourceAvailability availability, {
  required String sourceName,
}) {
  switch (availability) {
    case SourceAvailability.notConfigured:
      return null;
    case SourceAvailability.available:
      return SourceStatusPresentation(
        icon: Icons.cloud_done_outlined,
        tone: SourceStatusTone.healthy,
        label: 'Connected',
        description: '$sourceName connected',
        needsAttention: false,
      );
    case SourceAvailability.checking:
      return SourceStatusPresentation(
        icon: Icons.cloud_sync_outlined,
        tone: SourceStatusTone.neutral,
        label: 'Checking',
        description: 'Checking $sourceName',
        needsAttention: false,
      );
    case SourceAvailability.unreachable:
      return SourceStatusPresentation(
        icon: Icons.cloud_off_outlined,
        tone: SourceStatusTone.attention,
        label: 'Unreachable',
        description: '$sourceName unavailable',
        needsAttention: true,
      );
    case SourceAvailability.authenticationError:
      return SourceStatusPresentation(
        icon: Icons.lock_outline,
        tone: SourceStatusTone.attention,
        label: 'Sign-in needed',
        description: '$sourceName sign-in needed',
        needsAttention: true,
      );
  }
}
