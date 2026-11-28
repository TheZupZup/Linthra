//! Reading Subsonic answers, for Dart: `HttpSubsonicClient` and
//! `SubsonicFolderBrowserSource` (lib/core/sources/subsonic/) send the
//! requests and hand each body here (see `subsonic::response`).

use flutter_rust_bridge::frb;

use crate::subsonic::response::{self, Envelope, Outcome};

/// What to read out of an answer, by the request it answers.
pub enum SubsonicRead {
    /// `ping`: the envelope only.
    Envelope,
    Artists,
    AlbumPage,
    AlbumSongs,
    StarredSongIds,
    Playlists,
    PlaylistSongIds,
    CreatedPlaylistId,
    FormPost,
    StructuredLyrics,
    LegacyLyrics,
    MusicFolders,
    Indexes,
    Directory,
}

/// The envelope's verdict.
pub enum SubsonicOutcome {
    /// Not a `subsonic-response` envelope at all.
    NotSubsonic,
    /// A Subsonic error inside the answer; see `error_code`.
    Failed,
    Ok,
}

pub struct SubsonicArtist {
    pub id: String,
    pub name: String,
    pub album_count: i64,
    pub cover_art: Option<String>,
}

pub struct SubsonicAlbum {
    pub id: String,
    pub name: String,
    pub artist: Option<String>,
    pub song_count: i64,
    pub year: Option<i64>,
    /// As the server wrote it.
    pub created: Option<String>,
    pub cover_art: Option<String>,
}

pub struct SubsonicSong {
    pub id: String,
    pub title: String,
    pub album: Option<String>,
    pub album_id: Option<String>,
    pub artist: Option<String>,
    pub track: Option<i64>,
    pub duration_seconds: Option<i64>,
    /// As the server wrote it.
    pub created: Option<String>,
    pub cover_art: Option<String>,
}

/// A playlist, or a folder of the folder browser.
pub struct SubsonicNamed {
    pub id: String,
    pub name: String,
}

pub struct SubsonicLyricLine {
    pub text: String,
    /// None for an untimed line.
    pub start_ms: Option<i64>,
}

/// What an answer said. Only the fields the [SubsonicRead] asked for are
/// filled, and only when `outcome` is ok.
pub struct SubsonicReply {
    pub outcome: SubsonicOutcome,
    pub error_code: Option<i64>,
    pub version: Option<String>,
    pub server_type: Option<String>,
    pub server_version: Option<String>,
    pub artists: Vec<SubsonicArtist>,
    pub albums: Vec<SubsonicAlbum>,
    /// Every entry of an album page, mappable or not: paging stops on it.
    pub entry_count: u32,
    pub songs: Vec<SubsonicSong>,
    pub ids: Vec<String>,
    /// Playlists, or the folder browser's folders.
    pub named: Vec<SubsonicNamed>,
    pub id: Option<String>,
    pub takes_form_posts: bool,
    pub lyrics: Option<Vec<SubsonicLyricLine>>,
    pub text: Option<String>,
}

impl SubsonicReply {
    fn of(envelope: &Envelope) -> Self {
        SubsonicReply {
            outcome: match envelope.outcome {
                Outcome::NotSubsonic => SubsonicOutcome::NotSubsonic,
                Outcome::Failed => SubsonicOutcome::Failed,
                Outcome::Ok => SubsonicOutcome::Ok,
            },
            error_code: envelope.error_code,
            version: envelope.version.clone(),
            server_type: envelope.server_type.clone(),
            server_version: envelope.server_version.clone(),
            artists: Vec::new(),
            albums: Vec::new(),
            entry_count: 0,
            songs: Vec::new(),
            ids: Vec::new(),
            named: Vec::new(),
            id: None,
            takes_form_posts: false,
            lyrics: None,
            text: None,
        }
    }

    /// The safe answer when reading panicked: not something to trust.
    fn not_subsonic() -> Self {
        SubsonicReply::of(&response::envelope(None))
    }
}

/// Reads `body`, a Subsonic server's answer, for `what`.
///
/// A panic while reading gets the safe answer: not a Subsonic answer, which
/// Dart reports as one it can't use, and nothing of it is kept.
///
/// Synchronous, as `jsonDecode` was where this ran before: the answer is
/// read in the order it arrived, and nothing waits on another thread.
#[frb(sync)]
pub fn read_subsonic(body: Vec<u8>, what: SubsonicRead) -> SubsonicReply {
    crate::ffi::fail_safe(|| read(&body, what), SubsonicReply::not_subsonic)
}

fn read(body: &[u8], what: SubsonicRead) -> SubsonicReply {
    let mut slot = None;
    let envelope = response::read(body, &mut slot);
    let mut reply = SubsonicReply::of(&envelope);
    let (Outcome::Ok, Some(root)) = (envelope.outcome, envelope.root) else {
        return reply;
    };
    match what {
        SubsonicRead::Envelope => {}
        SubsonicRead::Artists => {
            reply.artists = response::artists(root).into_iter().map(artist).collect()
        }
        SubsonicRead::AlbumPage => {
            let (albums, count) = response::album_page(root);
            reply.albums = albums.into_iter().map(album).collect();
            reply.entry_count = u32::try_from(count).unwrap_or(u32::MAX);
        }
        SubsonicRead::AlbumSongs => {
            reply.songs = response::album_songs(root).into_iter().map(song).collect()
        }
        SubsonicRead::StarredSongIds => reply.ids = response::starred_song_ids(root),
        SubsonicRead::Playlists => {
            reply.named = response::playlists(root)
                .into_iter()
                .map(|p| SubsonicNamed {
                    id: p.id,
                    name: p.name,
                })
                .collect();
        }
        SubsonicRead::PlaylistSongIds => reply.ids = response::playlist_song_ids(root),
        SubsonicRead::CreatedPlaylistId => reply.id = response::created_playlist_id(root),
        SubsonicRead::FormPost => reply.takes_form_posts = response::takes_form_posts(root),
        SubsonicRead::StructuredLyrics => {
            reply.lyrics = response::structured_lyrics(root).map(|lines| {
                lines
                    .into_iter()
                    .map(|l| SubsonicLyricLine {
                        text: l.text,
                        start_ms: l.start_ms,
                    })
                    .collect()
            });
        }
        SubsonicRead::LegacyLyrics => reply.text = response::legacy_lyrics(root),
        SubsonicRead::MusicFolders => {
            reply.named = response::music_folders(root)
                .into_iter()
                .map(named)
                .collect()
        }
        SubsonicRead::Indexes => {
            reply.named = response::indexes(root).into_iter().map(named).collect()
        }
        SubsonicRead::Directory => {
            let (folders, songs) = response::directory(root);
            reply.named = folders.into_iter().map(named).collect();
            reply.songs = songs.into_iter().map(song).collect();
        }
    }
    reply
}

fn artist(a: response::Artist) -> SubsonicArtist {
    SubsonicArtist {
        id: a.id,
        name: a.name,
        album_count: a.album_count,
        cover_art: a.cover_art,
    }
}

fn album(a: response::Album) -> SubsonicAlbum {
    SubsonicAlbum {
        id: a.id,
        name: a.name,
        artist: a.artist,
        song_count: a.song_count,
        year: a.year,
        created: a.created,
        cover_art: a.cover_art,
    }
}

fn song(s: response::Song) -> SubsonicSong {
    SubsonicSong {
        id: s.id,
        title: s.title,
        album: s.album,
        album_id: s.album_id,
        artist: s.artist,
        track: s.track,
        duration_seconds: s.duration_seconds,
        created: s.created,
        cover_art: s.cover_art,
    }
}

fn named(f: response::Folder) -> SubsonicNamed {
    SubsonicNamed {
        id: f.id,
        name: f.name,
    }
}
