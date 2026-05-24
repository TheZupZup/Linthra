import 'package:flutter/foundation.dart';

/// How far along the cast subsystem is, independent of any cast SDK.
///
/// [unavailable] is the honest state when no cast backend is wired (the shipped
/// default on platforms without Chromecast support, and in tests). The
/// remaining values are driven by the real backend
/// ([DefaultCastService] over a [CastTransport]) once it is active.
enum CastAvailability {
  /// No cast backend is present, so casting cannot be started at all.
  unavailable,

  /// A backend exists and is ready, but no discovery/connection is in progress.
  idle,

  /// Actively scanning for nearby cast devices.
  discovering,

  /// A device was picked and a session is being established.
  connecting,

  /// Connected to a device; playback should be handed off to it.
  connected,

  /// Discovery or connection failed. [CastState.message] carries a friendly,
  /// secret-free explanation for the sheet to show.
  error,
}

/// A discoverable cast target (e.g. a Chromecast). Identity is its [id] so the
/// UI can highlight the connected device regardless of list reordering.
@immutable
class CastDevice {
  const CastDevice({required this.id, required this.name});

  final String id;
  final String name;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is CastDevice && other.id == id);

  @override
  int get hashCode => id.hashCode;
}

/// An immutable snapshot of the cast subsystem the UI renders from, mirroring
/// the shape of [PlaybackState]: the UI reads this and drives a [CastService],
/// never a cast SDK directly. That keeps the now-playing screen identical
/// whether casting is a stubbed foundation (today) or a live backend (later).
@immutable
class CastState {
  const CastState({
    this.availability = CastAvailability.unavailable,
    this.devices = const <CastDevice>[],
    this.connectedDevice,
    this.message,
  });

  /// The honest default: no cast backend wired, nothing reachable.
  static const CastState unavailable = CastState();

  final CastAvailability availability;

  /// Devices found so far while discovering. Empty until a backend reports any.
  final List<CastDevice> devices;

  /// The device a session is being established with or is established with
  /// ([CastAvailability.connecting] / [CastAvailability.connected]); null
  /// otherwise.
  final CastDevice? connectedDevice;

  /// A friendly, secret-free note for the sheet to show: the [error]
  /// explanation, or a non-fatal notice while connected (e.g. the current track
  /// is a local file that cannot be cast). Never carries a token or an
  /// authenticated URL.
  final String? message;

  /// Whether the platform can cast at all. False when no backend is wired,
  /// which is what the UI uses to show an honest unavailable state rather than
  /// an empty device picker.
  bool get isAvailable => availability != CastAvailability.unavailable;

  bool get isConnected => availability == CastAvailability.connected;

  bool get isConnecting => availability == CastAvailability.connecting;

  bool get isDiscovering => availability == CastAvailability.discovering;

  bool get hasError => availability == CastAvailability.error;

  CastState copyWith({
    CastAvailability? availability,
    List<CastDevice>? devices,
    CastDevice? connectedDevice,
  }) {
    return CastState(
      availability: availability ?? this.availability,
      devices: devices ?? this.devices,
      connectedDevice: connectedDevice ?? this.connectedDevice,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CastState &&
          other.availability == availability &&
          listEquals(other.devices, devices) &&
          other.connectedDevice == connectedDevice &&
          other.message == message);

  @override
  int get hashCode => Object.hash(
        availability,
        Object.hashAll(devices),
        connectedDevice,
        message,
      );
}
