#![no_main]

use linthra_core::subsonic::response;

libfuzzer_sys::fuzz_target!(|data: &[u8]| {
    // A server's answer as the Subsonic client reads it: the envelope, then
    // every list Linthra reads out of one.
    let mut slot = None;
    let envelope = response::read(data, &mut slot);
    if let Some(root) = envelope.root {
        let _ = response::artists(root);
        let _ = response::album_page(root);
        let _ = response::album_songs(root);
        let _ = response::starred_song_ids(root);
        let _ = response::playlists(root);
        let _ = response::playlist_song_ids(root);
        let _ = response::created_playlist_id(root);
        let _ = response::takes_form_posts(root);
        let _ = response::structured_lyrics(root);
        let _ = response::legacy_lyrics(root);
        let _ = response::music_folders(root);
        let _ = response::indexes(root);
        let _ = response::directory(root);
    }
});
