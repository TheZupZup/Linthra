import '../../models/audio_cd.dart';
import '../../models/optical_media.dart';
import 'audio_cd_toc_service.dart';

/// An [AudioCdTocService] that reads nothing and always answers "unsupported".
///
/// The real implementation on every platform without optical media — Android
/// above all, which #631 must leave exactly as it was — and the default
/// binding everywhere else, so a unit or widget test never reaches a method
/// channel.
///
/// It answers [AudioCdInspectionStatus.unsupported] rather than "no disc" for
/// the same reason [UnsupportedOpticalMediaService] does: a phone has no disc
/// *and* no way to look for one, and only the second is true of every platform
/// this class stands in for.
class UnsupportedAudioCdTocService implements AudioCdTocService {
  const UnsupportedAudioCdTocService();

  @override
  bool get isSupported => false;

  @override
  Future<AudioCdInspection> inspect(OpticalDrive drive) async =>
      const AudioCdInspection.unsupported();
}
