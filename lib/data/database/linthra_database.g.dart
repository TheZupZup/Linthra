// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'linthra_database.dart';

// ignore_for_file: type=lint
class $TracksTable extends Tracks with TableInfo<$TracksTable, TrackRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TracksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _sourceIdMeta =
      const VerificationMeta('sourceId');
  @override
  late final GeneratedColumn<String> sourceId = GeneratedColumn<String>(
      'source_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
      'title', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _uriMeta = const VerificationMeta('uri');
  @override
  late final GeneratedColumn<String> uri = GeneratedColumn<String>(
      'uri', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _artistNameMeta =
      const VerificationMeta('artistName');
  @override
  late final GeneratedColumn<String> artistName = GeneratedColumn<String>(
      'artist_name', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _albumNameMeta =
      const VerificationMeta('albumName');
  @override
  late final GeneratedColumn<String> albumName = GeneratedColumn<String>(
      'album_name', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _albumIdMeta =
      const VerificationMeta('albumId');
  @override
  late final GeneratedColumn<String> albumId = GeneratedColumn<String>(
      'album_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _albumArtistNameMeta =
      const VerificationMeta('albumArtistName');
  @override
  late final GeneratedColumn<String> albumArtistName = GeneratedColumn<String>(
      'album_artist_name', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _durationMsMeta =
      const VerificationMeta('durationMs');
  @override
  late final GeneratedColumn<int> durationMs = GeneratedColumn<int>(
      'duration_ms', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _trackNumberMeta =
      const VerificationMeta('trackNumber');
  @override
  late final GeneratedColumn<int> trackNumber = GeneratedColumn<int>(
      'track_number', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _artworkUriMeta =
      const VerificationMeta('artworkUri');
  @override
  late final GeneratedColumn<String> artworkUri = GeneratedColumn<String>(
      'artwork_uri', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _fileSizeBytesMeta =
      const VerificationMeta('fileSizeBytes');
  @override
  late final GeneratedColumn<int> fileSizeBytes = GeneratedColumn<int>(
      'file_size_bytes', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _fileModifiedAtMsMeta =
      const VerificationMeta('fileModifiedAtMs');
  @override
  late final GeneratedColumn<int> fileModifiedAtMs = GeneratedColumn<int>(
      'file_modified_at_ms', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        sourceId,
        title,
        uri,
        artistName,
        albumName,
        albumId,
        albumArtistName,
        durationMs,
        trackNumber,
        artworkUri,
        fileSizeBytes,
        fileModifiedAtMs
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'tracks';
  @override
  VerificationContext validateIntegrity(Insertable<TrackRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('source_id')) {
      context.handle(_sourceIdMeta,
          sourceId.isAcceptableOrUnknown(data['source_id']!, _sourceIdMeta));
    } else if (isInserting) {
      context.missing(_sourceIdMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
          _titleMeta, title.isAcceptableOrUnknown(data['title']!, _titleMeta));
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('uri')) {
      context.handle(
          _uriMeta, uri.isAcceptableOrUnknown(data['uri']!, _uriMeta));
    } else if (isInserting) {
      context.missing(_uriMeta);
    }
    if (data.containsKey('artist_name')) {
      context.handle(
          _artistNameMeta,
          artistName.isAcceptableOrUnknown(
              data['artist_name']!, _artistNameMeta));
    }
    if (data.containsKey('album_name')) {
      context.handle(_albumNameMeta,
          albumName.isAcceptableOrUnknown(data['album_name']!, _albumNameMeta));
    }
    if (data.containsKey('album_id')) {
      context.handle(_albumIdMeta,
          albumId.isAcceptableOrUnknown(data['album_id']!, _albumIdMeta));
    }
    if (data.containsKey('album_artist_name')) {
      context.handle(
          _albumArtistNameMeta,
          albumArtistName.isAcceptableOrUnknown(
              data['album_artist_name']!, _albumArtistNameMeta));
    }
    if (data.containsKey('duration_ms')) {
      context.handle(
          _durationMsMeta,
          durationMs.isAcceptableOrUnknown(
              data['duration_ms']!, _durationMsMeta));
    }
    if (data.containsKey('track_number')) {
      context.handle(
          _trackNumberMeta,
          trackNumber.isAcceptableOrUnknown(
              data['track_number']!, _trackNumberMeta));
    }
    if (data.containsKey('artwork_uri')) {
      context.handle(
          _artworkUriMeta,
          artworkUri.isAcceptableOrUnknown(
              data['artwork_uri']!, _artworkUriMeta));
    }
    if (data.containsKey('file_size_bytes')) {
      context.handle(
          _fileSizeBytesMeta,
          fileSizeBytes.isAcceptableOrUnknown(
              data['file_size_bytes']!, _fileSizeBytesMeta));
    }
    if (data.containsKey('file_modified_at_ms')) {
      context.handle(
          _fileModifiedAtMsMeta,
          fileModifiedAtMs.isAcceptableOrUnknown(
              data['file_modified_at_ms']!, _fileModifiedAtMsMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {uri};
  @override
  TrackRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TrackRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      sourceId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}source_id'])!,
      title: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}title'])!,
      uri: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}uri'])!,
      artistName: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}artist_name']),
      albumName: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}album_name']),
      albumId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}album_id']),
      albumArtistName: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}album_artist_name']),
      durationMs: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}duration_ms'])!,
      trackNumber: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}track_number']),
      artworkUri: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}artwork_uri']),
      fileSizeBytes: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}file_size_bytes']),
      fileModifiedAtMs: attachedDatabase.typeMapping.read(
          DriftSqlType.int, data['${effectivePrefix}file_modified_at_ms']),
    );
  }

  @override
  $TracksTable createAlias(String alias) {
    return $TracksTable(attachedDatabase, alias);
  }
}

class TrackRow extends DataClass implements Insertable<TrackRow> {
  final String id;
  final String sourceId;
  final String title;
  final String uri;
  final String? artistName;
  final String? albumName;

  /// The source's provider-namespaced album id (e.g. `jellyfin:al-1`), when
  /// reported — the primary album-grouping key (`library_grouping.dart`).
  /// Nullable: local files and older rows carry none and fall back to
  /// name-based grouping. Added in schema v3.
  final String? albumId;

  /// The album's artist as the source reported it, distinct from the track's
  /// own [artistName] — the second album-grouping tier when [albumId] is
  /// absent. Nullable, added in schema v3.
  final String? albumArtistName;
  final int durationMs;
  final int? trackNumber;
  final String? artworkUri;

  /// The source file's length in bytes the last time its tags were parsed, and
  /// the file's last-modified time as milliseconds since the Unix epoch. Together
  /// they are the stamp an incremental local scan compares against a fresh
  /// `stat` to decide whether a file has to be opened and parsed again. Both
  /// null for anything that is not a plain local file (remote tracks, Android
  /// SAF documents, MediaStore rows) and for rows written before schema v5; a
  /// null stamp means "parse it", i.e. exactly the pre-v5 behavior.
  ///
  /// They live on the track row rather than in a side table because the row
  /// *is* the record of "this path was parsed into this track": one write, one
  /// transaction, and no way for a catalog and a separate stamp index to drift
  /// apart and skip parsing a file whose track was never stored. Added in
  /// schema v5.
  final int? fileSizeBytes;
  final int? fileModifiedAtMs;
  const TrackRow(
      {required this.id,
      required this.sourceId,
      required this.title,
      required this.uri,
      this.artistName,
      this.albumName,
      this.albumId,
      this.albumArtistName,
      required this.durationMs,
      this.trackNumber,
      this.artworkUri,
      this.fileSizeBytes,
      this.fileModifiedAtMs});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['source_id'] = Variable<String>(sourceId);
    map['title'] = Variable<String>(title);
    map['uri'] = Variable<String>(uri);
    if (!nullToAbsent || artistName != null) {
      map['artist_name'] = Variable<String>(artistName);
    }
    if (!nullToAbsent || albumName != null) {
      map['album_name'] = Variable<String>(albumName);
    }
    if (!nullToAbsent || albumId != null) {
      map['album_id'] = Variable<String>(albumId);
    }
    if (!nullToAbsent || albumArtistName != null) {
      map['album_artist_name'] = Variable<String>(albumArtistName);
    }
    map['duration_ms'] = Variable<int>(durationMs);
    if (!nullToAbsent || trackNumber != null) {
      map['track_number'] = Variable<int>(trackNumber);
    }
    if (!nullToAbsent || artworkUri != null) {
      map['artwork_uri'] = Variable<String>(artworkUri);
    }
    if (!nullToAbsent || fileSizeBytes != null) {
      map['file_size_bytes'] = Variable<int>(fileSizeBytes);
    }
    if (!nullToAbsent || fileModifiedAtMs != null) {
      map['file_modified_at_ms'] = Variable<int>(fileModifiedAtMs);
    }
    return map;
  }

  TracksCompanion toCompanion(bool nullToAbsent) {
    return TracksCompanion(
      id: Value(id),
      sourceId: Value(sourceId),
      title: Value(title),
      uri: Value(uri),
      artistName: artistName == null && nullToAbsent
          ? const Value.absent()
          : Value(artistName),
      albumName: albumName == null && nullToAbsent
          ? const Value.absent()
          : Value(albumName),
      albumId: albumId == null && nullToAbsent
          ? const Value.absent()
          : Value(albumId),
      albumArtistName: albumArtistName == null && nullToAbsent
          ? const Value.absent()
          : Value(albumArtistName),
      durationMs: Value(durationMs),
      trackNumber: trackNumber == null && nullToAbsent
          ? const Value.absent()
          : Value(trackNumber),
      artworkUri: artworkUri == null && nullToAbsent
          ? const Value.absent()
          : Value(artworkUri),
      fileSizeBytes: fileSizeBytes == null && nullToAbsent
          ? const Value.absent()
          : Value(fileSizeBytes),
      fileModifiedAtMs: fileModifiedAtMs == null && nullToAbsent
          ? const Value.absent()
          : Value(fileModifiedAtMs),
    );
  }

  factory TrackRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TrackRow(
      id: serializer.fromJson<String>(json['id']),
      sourceId: serializer.fromJson<String>(json['sourceId']),
      title: serializer.fromJson<String>(json['title']),
      uri: serializer.fromJson<String>(json['uri']),
      artistName: serializer.fromJson<String?>(json['artistName']),
      albumName: serializer.fromJson<String?>(json['albumName']),
      albumId: serializer.fromJson<String?>(json['albumId']),
      albumArtistName: serializer.fromJson<String?>(json['albumArtistName']),
      durationMs: serializer.fromJson<int>(json['durationMs']),
      trackNumber: serializer.fromJson<int?>(json['trackNumber']),
      artworkUri: serializer.fromJson<String?>(json['artworkUri']),
      fileSizeBytes: serializer.fromJson<int?>(json['fileSizeBytes']),
      fileModifiedAtMs: serializer.fromJson<int?>(json['fileModifiedAtMs']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'sourceId': serializer.toJson<String>(sourceId),
      'title': serializer.toJson<String>(title),
      'uri': serializer.toJson<String>(uri),
      'artistName': serializer.toJson<String?>(artistName),
      'albumName': serializer.toJson<String?>(albumName),
      'albumId': serializer.toJson<String?>(albumId),
      'albumArtistName': serializer.toJson<String?>(albumArtistName),
      'durationMs': serializer.toJson<int>(durationMs),
      'trackNumber': serializer.toJson<int?>(trackNumber),
      'artworkUri': serializer.toJson<String?>(artworkUri),
      'fileSizeBytes': serializer.toJson<int?>(fileSizeBytes),
      'fileModifiedAtMs': serializer.toJson<int?>(fileModifiedAtMs),
    };
  }

  TrackRow copyWith(
          {String? id,
          String? sourceId,
          String? title,
          String? uri,
          Value<String?> artistName = const Value.absent(),
          Value<String?> albumName = const Value.absent(),
          Value<String?> albumId = const Value.absent(),
          Value<String?> albumArtistName = const Value.absent(),
          int? durationMs,
          Value<int?> trackNumber = const Value.absent(),
          Value<String?> artworkUri = const Value.absent(),
          Value<int?> fileSizeBytes = const Value.absent(),
          Value<int?> fileModifiedAtMs = const Value.absent()}) =>
      TrackRow(
        id: id ?? this.id,
        sourceId: sourceId ?? this.sourceId,
        title: title ?? this.title,
        uri: uri ?? this.uri,
        artistName: artistName.present ? artistName.value : this.artistName,
        albumName: albumName.present ? albumName.value : this.albumName,
        albumId: albumId.present ? albumId.value : this.albumId,
        albumArtistName: albumArtistName.present
            ? albumArtistName.value
            : this.albumArtistName,
        durationMs: durationMs ?? this.durationMs,
        trackNumber: trackNumber.present ? trackNumber.value : this.trackNumber,
        artworkUri: artworkUri.present ? artworkUri.value : this.artworkUri,
        fileSizeBytes:
            fileSizeBytes.present ? fileSizeBytes.value : this.fileSizeBytes,
        fileModifiedAtMs: fileModifiedAtMs.present
            ? fileModifiedAtMs.value
            : this.fileModifiedAtMs,
      );
  TrackRow copyWithCompanion(TracksCompanion data) {
    return TrackRow(
      id: data.id.present ? data.id.value : this.id,
      sourceId: data.sourceId.present ? data.sourceId.value : this.sourceId,
      title: data.title.present ? data.title.value : this.title,
      uri: data.uri.present ? data.uri.value : this.uri,
      artistName:
          data.artistName.present ? data.artistName.value : this.artistName,
      albumName: data.albumName.present ? data.albumName.value : this.albumName,
      albumId: data.albumId.present ? data.albumId.value : this.albumId,
      albumArtistName: data.albumArtistName.present
          ? data.albumArtistName.value
          : this.albumArtistName,
      durationMs:
          data.durationMs.present ? data.durationMs.value : this.durationMs,
      trackNumber:
          data.trackNumber.present ? data.trackNumber.value : this.trackNumber,
      artworkUri:
          data.artworkUri.present ? data.artworkUri.value : this.artworkUri,
      fileSizeBytes: data.fileSizeBytes.present
          ? data.fileSizeBytes.value
          : this.fileSizeBytes,
      fileModifiedAtMs: data.fileModifiedAtMs.present
          ? data.fileModifiedAtMs.value
          : this.fileModifiedAtMs,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TrackRow(')
          ..write('id: $id, ')
          ..write('sourceId: $sourceId, ')
          ..write('title: $title, ')
          ..write('uri: $uri, ')
          ..write('artistName: $artistName, ')
          ..write('albumName: $albumName, ')
          ..write('albumId: $albumId, ')
          ..write('albumArtistName: $albumArtistName, ')
          ..write('durationMs: $durationMs, ')
          ..write('trackNumber: $trackNumber, ')
          ..write('artworkUri: $artworkUri, ')
          ..write('fileSizeBytes: $fileSizeBytes, ')
          ..write('fileModifiedAtMs: $fileModifiedAtMs')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id,
      sourceId,
      title,
      uri,
      artistName,
      albumName,
      albumId,
      albumArtistName,
      durationMs,
      trackNumber,
      artworkUri,
      fileSizeBytes,
      fileModifiedAtMs);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TrackRow &&
          other.id == this.id &&
          other.sourceId == this.sourceId &&
          other.title == this.title &&
          other.uri == this.uri &&
          other.artistName == this.artistName &&
          other.albumName == this.albumName &&
          other.albumId == this.albumId &&
          other.albumArtistName == this.albumArtistName &&
          other.durationMs == this.durationMs &&
          other.trackNumber == this.trackNumber &&
          other.artworkUri == this.artworkUri &&
          other.fileSizeBytes == this.fileSizeBytes &&
          other.fileModifiedAtMs == this.fileModifiedAtMs);
}

class TracksCompanion extends UpdateCompanion<TrackRow> {
  final Value<String> id;
  final Value<String> sourceId;
  final Value<String> title;
  final Value<String> uri;
  final Value<String?> artistName;
  final Value<String?> albumName;
  final Value<String?> albumId;
  final Value<String?> albumArtistName;
  final Value<int> durationMs;
  final Value<int?> trackNumber;
  final Value<String?> artworkUri;
  final Value<int?> fileSizeBytes;
  final Value<int?> fileModifiedAtMs;
  final Value<int> rowid;
  const TracksCompanion({
    this.id = const Value.absent(),
    this.sourceId = const Value.absent(),
    this.title = const Value.absent(),
    this.uri = const Value.absent(),
    this.artistName = const Value.absent(),
    this.albumName = const Value.absent(),
    this.albumId = const Value.absent(),
    this.albumArtistName = const Value.absent(),
    this.durationMs = const Value.absent(),
    this.trackNumber = const Value.absent(),
    this.artworkUri = const Value.absent(),
    this.fileSizeBytes = const Value.absent(),
    this.fileModifiedAtMs = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TracksCompanion.insert({
    required String id,
    required String sourceId,
    required String title,
    required String uri,
    this.artistName = const Value.absent(),
    this.albumName = const Value.absent(),
    this.albumId = const Value.absent(),
    this.albumArtistName = const Value.absent(),
    this.durationMs = const Value.absent(),
    this.trackNumber = const Value.absent(),
    this.artworkUri = const Value.absent(),
    this.fileSizeBytes = const Value.absent(),
    this.fileModifiedAtMs = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        sourceId = Value(sourceId),
        title = Value(title),
        uri = Value(uri);
  static Insertable<TrackRow> custom({
    Expression<String>? id,
    Expression<String>? sourceId,
    Expression<String>? title,
    Expression<String>? uri,
    Expression<String>? artistName,
    Expression<String>? albumName,
    Expression<String>? albumId,
    Expression<String>? albumArtistName,
    Expression<int>? durationMs,
    Expression<int>? trackNumber,
    Expression<String>? artworkUri,
    Expression<int>? fileSizeBytes,
    Expression<int>? fileModifiedAtMs,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (sourceId != null) 'source_id': sourceId,
      if (title != null) 'title': title,
      if (uri != null) 'uri': uri,
      if (artistName != null) 'artist_name': artistName,
      if (albumName != null) 'album_name': albumName,
      if (albumId != null) 'album_id': albumId,
      if (albumArtistName != null) 'album_artist_name': albumArtistName,
      if (durationMs != null) 'duration_ms': durationMs,
      if (trackNumber != null) 'track_number': trackNumber,
      if (artworkUri != null) 'artwork_uri': artworkUri,
      if (fileSizeBytes != null) 'file_size_bytes': fileSizeBytes,
      if (fileModifiedAtMs != null) 'file_modified_at_ms': fileModifiedAtMs,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TracksCompanion copyWith(
      {Value<String>? id,
      Value<String>? sourceId,
      Value<String>? title,
      Value<String>? uri,
      Value<String?>? artistName,
      Value<String?>? albumName,
      Value<String?>? albumId,
      Value<String?>? albumArtistName,
      Value<int>? durationMs,
      Value<int?>? trackNumber,
      Value<String?>? artworkUri,
      Value<int?>? fileSizeBytes,
      Value<int?>? fileModifiedAtMs,
      Value<int>? rowid}) {
    return TracksCompanion(
      id: id ?? this.id,
      sourceId: sourceId ?? this.sourceId,
      title: title ?? this.title,
      uri: uri ?? this.uri,
      artistName: artistName ?? this.artistName,
      albumName: albumName ?? this.albumName,
      albumId: albumId ?? this.albumId,
      albumArtistName: albumArtistName ?? this.albumArtistName,
      durationMs: durationMs ?? this.durationMs,
      trackNumber: trackNumber ?? this.trackNumber,
      artworkUri: artworkUri ?? this.artworkUri,
      fileSizeBytes: fileSizeBytes ?? this.fileSizeBytes,
      fileModifiedAtMs: fileModifiedAtMs ?? this.fileModifiedAtMs,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (sourceId.present) {
      map['source_id'] = Variable<String>(sourceId.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (uri.present) {
      map['uri'] = Variable<String>(uri.value);
    }
    if (artistName.present) {
      map['artist_name'] = Variable<String>(artistName.value);
    }
    if (albumName.present) {
      map['album_name'] = Variable<String>(albumName.value);
    }
    if (albumId.present) {
      map['album_id'] = Variable<String>(albumId.value);
    }
    if (albumArtistName.present) {
      map['album_artist_name'] = Variable<String>(albumArtistName.value);
    }
    if (durationMs.present) {
      map['duration_ms'] = Variable<int>(durationMs.value);
    }
    if (trackNumber.present) {
      map['track_number'] = Variable<int>(trackNumber.value);
    }
    if (artworkUri.present) {
      map['artwork_uri'] = Variable<String>(artworkUri.value);
    }
    if (fileSizeBytes.present) {
      map['file_size_bytes'] = Variable<int>(fileSizeBytes.value);
    }
    if (fileModifiedAtMs.present) {
      map['file_modified_at_ms'] = Variable<int>(fileModifiedAtMs.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TracksCompanion(')
          ..write('id: $id, ')
          ..write('sourceId: $sourceId, ')
          ..write('title: $title, ')
          ..write('uri: $uri, ')
          ..write('artistName: $artistName, ')
          ..write('albumName: $albumName, ')
          ..write('albumId: $albumId, ')
          ..write('albumArtistName: $albumArtistName, ')
          ..write('durationMs: $durationMs, ')
          ..write('trackNumber: $trackNumber, ')
          ..write('artworkUri: $artworkUri, ')
          ..write('fileSizeBytes: $fileSizeBytes, ')
          ..write('fileModifiedAtMs: $fileModifiedAtMs, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$LinthraDatabase extends GeneratedDatabase {
  _$LinthraDatabase(QueryExecutor e) : super(e);
  $LinthraDatabaseManager get managers => $LinthraDatabaseManager(this);
  late final $TracksTable tracks = $TracksTable(this);
  late final Index tracksSourceId = Index('tracks_source_id',
      'CREATE INDEX tracks_source_id ON tracks (source_id)');
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [tracks, tracksSourceId];
}

typedef $$TracksTableCreateCompanionBuilder = TracksCompanion Function({
  required String id,
  required String sourceId,
  required String title,
  required String uri,
  Value<String?> artistName,
  Value<String?> albumName,
  Value<String?> albumId,
  Value<String?> albumArtistName,
  Value<int> durationMs,
  Value<int?> trackNumber,
  Value<String?> artworkUri,
  Value<int?> fileSizeBytes,
  Value<int?> fileModifiedAtMs,
  Value<int> rowid,
});
typedef $$TracksTableUpdateCompanionBuilder = TracksCompanion Function({
  Value<String> id,
  Value<String> sourceId,
  Value<String> title,
  Value<String> uri,
  Value<String?> artistName,
  Value<String?> albumName,
  Value<String?> albumId,
  Value<String?> albumArtistName,
  Value<int> durationMs,
  Value<int?> trackNumber,
  Value<String?> artworkUri,
  Value<int?> fileSizeBytes,
  Value<int?> fileModifiedAtMs,
  Value<int> rowid,
});

class $$TracksTableFilterComposer
    extends Composer<_$LinthraDatabase, $TracksTable> {
  $$TracksTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get sourceId => $composableBuilder(
      column: $table.sourceId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get uri => $composableBuilder(
      column: $table.uri, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get artistName => $composableBuilder(
      column: $table.artistName, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get albumName => $composableBuilder(
      column: $table.albumName, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get albumId => $composableBuilder(
      column: $table.albumId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get albumArtistName => $composableBuilder(
      column: $table.albumArtistName,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get durationMs => $composableBuilder(
      column: $table.durationMs, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get trackNumber => $composableBuilder(
      column: $table.trackNumber, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get artworkUri => $composableBuilder(
      column: $table.artworkUri, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get fileSizeBytes => $composableBuilder(
      column: $table.fileSizeBytes, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get fileModifiedAtMs => $composableBuilder(
      column: $table.fileModifiedAtMs,
      builder: (column) => ColumnFilters(column));
}

class $$TracksTableOrderingComposer
    extends Composer<_$LinthraDatabase, $TracksTable> {
  $$TracksTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get sourceId => $composableBuilder(
      column: $table.sourceId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get uri => $composableBuilder(
      column: $table.uri, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get artistName => $composableBuilder(
      column: $table.artistName, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get albumName => $composableBuilder(
      column: $table.albumName, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get albumId => $composableBuilder(
      column: $table.albumId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get albumArtistName => $composableBuilder(
      column: $table.albumArtistName,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get durationMs => $composableBuilder(
      column: $table.durationMs, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get trackNumber => $composableBuilder(
      column: $table.trackNumber, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get artworkUri => $composableBuilder(
      column: $table.artworkUri, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get fileSizeBytes => $composableBuilder(
      column: $table.fileSizeBytes,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get fileModifiedAtMs => $composableBuilder(
      column: $table.fileModifiedAtMs,
      builder: (column) => ColumnOrderings(column));
}

class $$TracksTableAnnotationComposer
    extends Composer<_$LinthraDatabase, $TracksTable> {
  $$TracksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get sourceId =>
      $composableBuilder(column: $table.sourceId, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get uri =>
      $composableBuilder(column: $table.uri, builder: (column) => column);

  GeneratedColumn<String> get artistName => $composableBuilder(
      column: $table.artistName, builder: (column) => column);

  GeneratedColumn<String> get albumName =>
      $composableBuilder(column: $table.albumName, builder: (column) => column);

  GeneratedColumn<String> get albumId =>
      $composableBuilder(column: $table.albumId, builder: (column) => column);

  GeneratedColumn<String> get albumArtistName => $composableBuilder(
      column: $table.albumArtistName, builder: (column) => column);

  GeneratedColumn<int> get durationMs => $composableBuilder(
      column: $table.durationMs, builder: (column) => column);

  GeneratedColumn<int> get trackNumber => $composableBuilder(
      column: $table.trackNumber, builder: (column) => column);

  GeneratedColumn<String> get artworkUri => $composableBuilder(
      column: $table.artworkUri, builder: (column) => column);

  GeneratedColumn<int> get fileSizeBytes => $composableBuilder(
      column: $table.fileSizeBytes, builder: (column) => column);

  GeneratedColumn<int> get fileModifiedAtMs => $composableBuilder(
      column: $table.fileModifiedAtMs, builder: (column) => column);
}

class $$TracksTableTableManager extends RootTableManager<
    _$LinthraDatabase,
    $TracksTable,
    TrackRow,
    $$TracksTableFilterComposer,
    $$TracksTableOrderingComposer,
    $$TracksTableAnnotationComposer,
    $$TracksTableCreateCompanionBuilder,
    $$TracksTableUpdateCompanionBuilder,
    (TrackRow, BaseReferences<_$LinthraDatabase, $TracksTable, TrackRow>),
    TrackRow,
    PrefetchHooks Function()> {
  $$TracksTableTableManager(_$LinthraDatabase db, $TracksTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TracksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TracksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TracksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> sourceId = const Value.absent(),
            Value<String> title = const Value.absent(),
            Value<String> uri = const Value.absent(),
            Value<String?> artistName = const Value.absent(),
            Value<String?> albumName = const Value.absent(),
            Value<String?> albumId = const Value.absent(),
            Value<String?> albumArtistName = const Value.absent(),
            Value<int> durationMs = const Value.absent(),
            Value<int?> trackNumber = const Value.absent(),
            Value<String?> artworkUri = const Value.absent(),
            Value<int?> fileSizeBytes = const Value.absent(),
            Value<int?> fileModifiedAtMs = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              TracksCompanion(
            id: id,
            sourceId: sourceId,
            title: title,
            uri: uri,
            artistName: artistName,
            albumName: albumName,
            albumId: albumId,
            albumArtistName: albumArtistName,
            durationMs: durationMs,
            trackNumber: trackNumber,
            artworkUri: artworkUri,
            fileSizeBytes: fileSizeBytes,
            fileModifiedAtMs: fileModifiedAtMs,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String sourceId,
            required String title,
            required String uri,
            Value<String?> artistName = const Value.absent(),
            Value<String?> albumName = const Value.absent(),
            Value<String?> albumId = const Value.absent(),
            Value<String?> albumArtistName = const Value.absent(),
            Value<int> durationMs = const Value.absent(),
            Value<int?> trackNumber = const Value.absent(),
            Value<String?> artworkUri = const Value.absent(),
            Value<int?> fileSizeBytes = const Value.absent(),
            Value<int?> fileModifiedAtMs = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              TracksCompanion.insert(
            id: id,
            sourceId: sourceId,
            title: title,
            uri: uri,
            artistName: artistName,
            albumName: albumName,
            albumId: albumId,
            albumArtistName: albumArtistName,
            durationMs: durationMs,
            trackNumber: trackNumber,
            artworkUri: artworkUri,
            fileSizeBytes: fileSizeBytes,
            fileModifiedAtMs: fileModifiedAtMs,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$TracksTableProcessedTableManager = ProcessedTableManager<
    _$LinthraDatabase,
    $TracksTable,
    TrackRow,
    $$TracksTableFilterComposer,
    $$TracksTableOrderingComposer,
    $$TracksTableAnnotationComposer,
    $$TracksTableCreateCompanionBuilder,
    $$TracksTableUpdateCompanionBuilder,
    (TrackRow, BaseReferences<_$LinthraDatabase, $TracksTable, TrackRow>),
    TrackRow,
    PrefetchHooks Function()>;

class $LinthraDatabaseManager {
  final _$LinthraDatabase _db;
  $LinthraDatabaseManager(this._db);
  $$TracksTableTableManager get tracks =>
      $$TracksTableTableManager(_db, _db.tracks);
}
