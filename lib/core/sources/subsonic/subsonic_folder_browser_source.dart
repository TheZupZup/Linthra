import 'dart:async';

import 'package:http/http.dart' as http;

import '../../app_info.dart';
import '../../models/music_folder.dart';
import '../../models/subsonic_session.dart';
import '../../models/track.dart';
import '../../services/folder_browsable_music_source.dart';
import 'subsonic_auth.dart';
import 'subsonic_endpoints.dart';
import 'subsonic_exception.dart';
import 'subsonic_reply.dart';
import 'subsonic_track_mapper.dart';

/// Folder-hierarchy browsing for a signed-in Subsonic-compatible server.
///
/// Subsonic's old-style browsing API has two levels of opaque identifiers:
/// music folders lead to an index, and index/directory entries lead to
/// `getMusicDirectory`. Prefixing those ids locally keeps the two namespaces
/// unambiguous without ever persisting a credential-bearing URL.
class SubsonicFolderBrowserSource implements FolderBrowsableMusicSource {
  SubsonicFolderBrowserSource({
    required this.session,
    http.Client? httpClient,
  }) : _client = httpClient ?? http.Client();

  final SubsonicSession session;
  final http.Client _client;

  static const Duration _timeout = Duration(seconds: 20);
  static const String _musicFolderPrefix = 'music-folder:';
  static const String _directoryPrefix = 'directory:';

  @override
  String get id => 'subsonic';

  @override
  String get displayName {
    final String? type = session.serverType;
    if (type == null || type.isEmpty) return 'Subsonic';
    return type[0].toUpperCase() + type.substring(1);
  }

  @override
  Future<List<MusicFolder>> fetchRootFolders() async {
    final SubsonicReply reply =
        await _call('getMusicFolders', SubsonicRead.musicFolders);
    return <MusicFolder>[
      for (final folder in reply.named)
        MusicFolder(id: '$_musicFolderPrefix${folder.id}', name: folder.name),
    ]..sort(_compareFolders);
  }

  @override
  Future<MusicFolderListing> fetchFolder(String folderId) {
    if (folderId.startsWith(_musicFolderPrefix)) {
      return _fetchIndex(folderId.substring(_musicFolderPrefix.length));
    }
    if (folderId.startsWith(_directoryPrefix)) {
      return _fetchDirectory(folderId.substring(_directoryPrefix.length));
    }
    throw SubsonicException.unsupportedResponse();
  }

  Future<MusicFolderListing> _fetchIndex(String musicFolderId) async {
    final SubsonicReply reply = await _call(
      'getIndexes',
      SubsonicRead.indexes,
      extra: <String, String>{'musicFolderId': musicFolderId},
    );
    if (reply.named.isEmpty) return MusicFolderListing.empty;
    return MusicFolderListing(
      folders: <MusicFolder>[
        for (final folder in reply.named)
          MusicFolder(id: '$_directoryPrefix${folder.id}', name: folder.name),
      ]..sort(_compareFolders),
    );
  }

  Future<MusicFolderListing> _fetchDirectory(String directoryId) async {
    final SubsonicReply reply = await _call(
      'getMusicDirectory',
      SubsonicRead.directory,
      extra: <String, String>{'id': directoryId},
    );
    if (reply.named.isEmpty && reply.songs.isEmpty) {
      return MusicFolderListing.empty;
    }
    return MusicFolderListing(
      folders: <MusicFolder>[
        for (final folder in reply.named)
          MusicFolder(id: '$_directoryPrefix${folder.id}', name: folder.name),
      ]..sort(_compareFolders),
      tracks: <Track>[
        for (final song in reply.songs)
          SubsonicTrackMapper.toTrack(songDto(song)),
      ],
    );
  }

  void close() => _client.close();

  Future<SubsonicReply> _call(
    String method,
    SubsonicRead what, {
    Map<String, String> extra = const <String, String>{},
  }) async {
    final Map<String, String> queryParams = <String, String>{
      'u': session.username,
      'v': SubsonicEndpoints.apiVersion,
      'c': AppInfo.name,
      'f': 'json',
      ...extra,
    };

    if (session.isLegacy) {
      queryParams['p'] = SubsonicAuth.encodePassword(session.password!);
    } else {
      queryParams['t'] = session.token!;
      queryParams['s'] = session.salt!;
    }

    final Uri uri = Uri.parse('${session.baseUrl}/rest/$method.view').replace(
      queryParameters: queryParams,
    );

    final http.Response response;
    try {
      response = await (session.isLegacy
              ? _getUnredirected(uri)
              : _client.get(
                  uri,
                  headers: const <String, String>{'Accept': 'application/json'},
                ))
          .timeout(_timeout);
    } on TimeoutException {
      throw SubsonicException.notReachable();
    } on Exception {
      // The URI carries a salt/token, so never echo the low-level exception.
      throw SubsonicException.notReachable();
    }

    final int status = response.statusCode;
    if (session.isLegacy && status >= 300 && status < 400) {
      throw SubsonicException.passwordRedirectRefused();
    }
    if (status == 401 || status == 403) {
      throw SubsonicException.unauthorized();
    }
    if (status >= 500) {
      throw SubsonicException.serverError(status);
    }
    if (status < 200 || status >= 300) {
      throw SubsonicException.notSubsonic();
    }

    return okOrThrow(
      await readSubsonicAnswer(response.bodyBytes, what),
      _mapErrorCode,
    );
  }

  /// GETs [uri] without following a redirect: it carries the legacy password,
  /// which goes only to the address the user entered.
  Future<http.Response> _getUnredirected(Uri uri) async {
    final http.Request request = http.Request('GET', uri)
      ..followRedirects = false
      ..headers['Accept'] = 'application/json';
    return http.Response.fromStream(await _client.send(request));
  }

  SubsonicException _mapErrorCode(int? code) {
    switch (code) {
      case 40:
      case 41:
      case 44:
      case 45:
      case 50:
        return SubsonicException.unauthorized();
      case 20:
      case 30:
        return SubsonicException.unsupportedResponse();
      default:
        return SubsonicException.serverError();
    }
  }

  static int _compareFolders(MusicFolder a, MusicFolder b) =>
      a.name.toLowerCase().compareTo(b.name.toLowerCase());
}
