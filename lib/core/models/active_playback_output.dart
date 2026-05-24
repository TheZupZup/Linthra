/// Which output is actually producing sound right now.
///
/// The app can play through the on-device engine ([local]) or hand off to a
/// cast receiver ([cast], e.g. a Chromecast). Only one is ever active: when
/// [cast] is active the phone is a remote controller and the local engine is
/// silenced, so the two never fight over the speakers. The
/// `ActivePlaybackController` routes commands and merges state based on this.
enum ActivePlaybackOutput {
  /// The on-device `just_audio` engine is the source of sound.
  local,

  /// A cast receiver is playing; the phone only controls and mirrors it.
  cast,
}
