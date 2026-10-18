import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../app_info.dart';
import '../../models/music_folder.dart';
import '../../models/subsonic_session.dart';
import '../../models/track.dart';
import '../../services/folder_browsable_music_source.dart';
import 'subsonic_api.dart';
import 'subsonic_endpoints.dart';
import 'subsonic_exception.dart';
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
    final SubsonicEnvelope envelope = await _call('getMusicFolders');
    final Object? root = envelope.data['musicFolders'];
    final Object? rawFolders =
        root is Map<String, dynamic> ? root['musicFolder'] : null;
    if (rawFolders is! List) return const <MusicFolder>[];

    final List<MusicFolder> folders = <MusicFolder>[];
    for (final Object? raw in rawFolders) {
      if (raw is! Map<String, dynamic>) continue;
      final String? folderId = _string(raw['id']);
      final String? name = _string(raw['name']);
      if (folderId != null && name != null) {
        folders.add(
          MusicFolder(id: '$_musicFolderPrefix$folderId', name: name),
        );
      }
    }
    folders.sort(_compareFolders);
    return folders;
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
    final SubsonicEnvelope envelope = await _call(
      'getIndexes',
      extra: <String, String>{'musicFolderId': musicFolderId},
    );
    final Object? root = envelope.data['indexes'];
    final Object? indexes = root is Map<String, dynamic> ? root['index'] : null;
    if (indexes is! List) return MusicFolderListing.empty;

    final List<MusicFolder> folders = <MusicFolder>[];
    for (final Object? index in indexes) {
      if (index is! Map<String, dynamic>) continue;
      final Object? artists = index['artist'];
      if (artists is! List) continue;
      for (final Object? raw in artists) {
        if (raw is! Map<String, dynamic>) continue;
        final String? directoryId = _string(raw['id']);
        final String? name = _string(raw['name']);
        if (directoryId != null && name != null) {
          folders.add(
            MusicFolder(id: '$_directoryPrefix$directoryId', name: name),
          );
        }
      }
    }
    folders.sort(_compareFolders);
    return MusicFolderListing(folders: folders);
  }

  Future<MusicFolderListing> _fetchDirectory(String directoryId) async {
    final SubsonicEnvelope envelope = await _call(
      'getMusicDirectory',
      extra: <String, String>{'id': directoryId},
    );
    final Object? root = envelope.data['directory'];
    final Object? children =
        root is Map<String, dynamic> ? root['child'] : null;
    if (children is! List) return MusicFolderListing.empty;

    final List<MusicFolder> folders = <MusicFolder>[];
    final List<Track> tracks = <Track>[];
    for (final Object? raw in children) {
      if (raw is! Map<String, dynamic>) continue;
      if (raw['isDir'] == true) {
        final String? childId = _string(raw['id']);
        final String? name = _string(raw['title']) ?? _string(raw['name']);
        if (childId != null && name != null) {
          folders.add(
            MusicFolder(id: '$_directoryPrefix$childId', name: name),
          );
        }
        continue;
      }
      final SubsonicSongDto? dto = SubsonicSongDto.fromJson(raw);
      if (dto != null) tracks.add(SubsonicTrackMapper.toTrack(dto));
    }
    folders.sort(_compareFolders);
    return MusicFolderListing(folders: folders, tracks: tracks);
  }

  void close() => _client.close();

  Future<SubsonicEnvelope> _call(
    String method, {
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
      queryParams['p'] = session.password!;
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

    final Map<String, dynamic> body;
    try {
      final Object? decoded = jsonDecode(
        utf8.decode(response.bodyBytes, allowMalformed: true),
      );
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException();
      }
      body = decoded;
    } on FormatException {
      throw SubsonicException.notSubsonic();
    }

    final SubsonicEnvelope? envelope = SubsonicEnvelope.fromJson(body);
    if (envelope == null) throw SubsonicException.notSubsonic();
    if (!envelope.isOk) throw _mapErrorCode(envelope.errorCode);
    return envelope;
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

  static String? _string(Object? value) {
    if (value is! String) return null;
    final String trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static int _compareFolders(MusicFolder a, MusicFolder b) =>
      a.name.toLowerCase().compareTo(b.name.toLowerCase());
}
