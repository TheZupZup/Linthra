import 'package:sonara/core/services/folder_picker_service.dart';

/// Returns a fixed folder (or `null` to simulate cancellation) so the
/// pick-and-scan flow can be driven without a real OS folder dialog.
class FakeFolderPickerService implements FolderPickerService {
  FakeFolderPickerService({this.folder});

  /// The folder the picker "returns". `null` simulates the user cancelling.
  final String? folder;

  int pickCount = 0;

  @override
  Future<String?> pickFolder() async {
    pickCount++;
    return folder;
  }
}
