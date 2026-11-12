// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Portuguese (`pt`).
class AppLocalizationsPt extends AppLocalizations {
  AppLocalizationsPt([String locale = 'pt']) : super(locale);

  @override
  String get navigationLibrary => 'Biblioteca';

  @override
  String get navigationFolders => 'Pastas';

  @override
  String get navigationPlaylists => 'Playlists';

  @override
  String get navigationDownloads => 'Downloads';

  @override
  String get navigationSettings => 'Configurações';
}

/// The translations for Portuguese, as used in Brazil (`pt_BR`).
class AppLocalizationsPtBr extends AppLocalizationsPt {
  AppLocalizationsPtBr() : super('pt_BR');

  @override
  String get navigationLibrary => 'Biblioteca';

  @override
  String get navigationFolders => 'Pastas';

  @override
  String get navigationPlaylists => 'Playlists';

  @override
  String get navigationDownloads => 'Downloads';

  @override
  String get navigationSettings => 'Configurações';
}
