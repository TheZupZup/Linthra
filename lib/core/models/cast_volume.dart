import 'package:flutter/foundation.dart';

/// The volume of a connected cast receiver, as reported by (and set on) the
/// device — not the phone's media volume.
///
/// Emitted by a [CastSessionHandle] as the receiver's status changes and folded
/// by [DefaultCastService] into [CastState] (its `volume`, `muted`, and
/// `supportsVolumeControl`). [level] is the Cast `0.0–1.0` scale. [controllable]
/// is false when the receiver reports a fixed volume (Cast `controlType: fixed`),
/// so the UI can show an honest disabled state instead of a slider that does
/// nothing.
@immutable
class CastVolume {
  const CastVolume({
    required this.level,
    required this.muted,
    this.controllable = true,
  });

  /// The honest "we don't know the device volume" value: not controllable and
  /// unmuted at zero, used before the first receiver status arrives.
  static const CastVolume unknown =
      CastVolume(level: 0, muted: false, controllable: false);

  /// Device volume on the Cast `0.0–1.0` scale.
  final double level;

  /// Whether the receiver is muted.
  final bool muted;

  /// Whether the receiver allows volume changes (false for a fixed-volume
  /// device).
  final bool controllable;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CastVolume &&
          other.level == level &&
          other.muted == muted &&
          other.controllable == controllable);

  @override
  int get hashCode => Object.hash(level, muted, controllable);

  @override
  String toString() =>
      'CastVolume(level: $level, muted: $muted, controllable: $controllable)';
}
