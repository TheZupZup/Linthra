import 'package:flutter/foundation.dart';

/// How far along the cast subsystem is, independent of any cast SDK.
///
/// [unavailable] is the honest default in this build: no cast backend is wired
/// yet, so the UI shows a cast affordance but never pretends a device is
/// reachable. The remaining values are the seam a real backend
/// (Chromecast/Cast SDK, AirPlay, …) fills in once it lands.
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
  });

  /// The honest default: no cast backend wired, nothing reachable.
  static const CastState unavailable = CastState();

  final CastAvailability availability;

  /// Devices found so far while discovering. Empty until a backend reports any.
  final List<CastDevice> devices;

  /// The device a session is established with, or null when not connected.
  final CastDevice? connectedDevice;

  /// Whether the platform can cast at all. False in this build (no backend),
  /// which is what the UI uses to show an honest "coming soon" state rather than
  /// an empty device picker.
  bool get isAvailable => availability != CastAvailability.unavailable;

  bool get isConnected => availability == CastAvailability.connected;

  bool get isDiscovering => availability == CastAvailability.discovering;

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
          other.connectedDevice == connectedDevice);

  @override
  int get hashCode =>
      Object.hash(availability, Object.hashAll(devices), connectedDevice);
}
