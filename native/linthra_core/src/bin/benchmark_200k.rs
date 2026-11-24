use std::time::{Duration, Instant};

use linthra_core::{LibraryIndex, TrackRecord};

const TRACK_COUNT: usize = 200_000;
const SEARCH_ITERATIONS: usize = 500;
const BROAD_ITERATIONS: usize = 40;

fn main() {
    let tracks = synthetic_library(TRACK_COUNT);

    let build_started = Instant::now();
    let index = LibraryIndex::build(tracks);
    let build_elapsed = build_started.elapsed();

    let queries = [
        "artist 421 track 199421",
        "album 311 artist 731",
        "navidrome track 150000",
        "jellyfin album 42",
        "local artist 11",
    ];

    let search_started = Instant::now();
    let mut hit_count = 0usize;
    for iteration in 0..SEARCH_ITERATIONS {
        let query = queries[iteration % queries.len()];
        hit_count += index.search(query, 50).len();
    }
    let search_elapsed = search_started.elapsed();
    let average = search_elapsed / SEARCH_ITERATIONS as u32;

    println!("Linthra large-library benchmark");
    println!("tracks: {TRACK_COUNT}");
    println!("index build: {} ms", build_elapsed.as_millis());
    println!(
        "{SEARCH_ITERATIONS} searches: {} ms (avg {} µs)",
        search_elapsed.as_millis(),
        average.as_micros()
    );
    println!("total returned hits: {hit_count}");

    // Queries that match (nearly) the whole catalog, like the first letter
    // typed into a search box. Ranking is what costs here: every candidate is
    // scored, and only the best 50 may be ordered.
    let broad_queries = ["m", "midnight", "track", "midnight signal"];
    let broad_started = Instant::now();
    let mut broad_hits = 0usize;
    for iteration in 0..BROAD_ITERATIONS {
        let query = broad_queries[iteration % broad_queries.len()];
        broad_hits += index.search(query, 50).len();
    }
    let broad_average = broad_started.elapsed() / BROAD_ITERATIONS as u32;
    println!(
        "{BROAD_ITERATIONS} broad searches (whole catalog matches): avg {} µs, {broad_hits} hits",
        broad_average.as_micros()
    );

    // Queries whose words start no token, so each is matched within its
    // typos: the token range sharing its first letter is scanned for near
    // spellings before the postings are read.
    let typo_queries = ["midnigth", "sginal midnight", "trakc 1994", "albmu 42"];
    let typo_started = Instant::now();
    let mut typo_hits = 0usize;
    for iteration in 0..BROAD_ITERATIONS {
        let query = typo_queries[iteration % typo_queries.len()];
        typo_hits += index.search(query, 50).len();
    }
    let typo_average = typo_started.elapsed() / BROAD_ITERATIONS as u32;
    println!(
        "{BROAD_ITERATIONS} searches with typos: avg {} µs, {typo_hits} hits",
        typo_average.as_micros()
    );
    assert!(typo_hits > 0, "no search with typos found anything");

    // This is a regression smoke threshold, not a marketing benchmark. It is
    // deliberately generous enough for shared CI runners while still catching
    // an accidental O(catalog × query) implementation.
    assert!(
        average < Duration::from_millis(50),
        "average search exceeded the 50 ms large-library budget: {average:?}"
    );
    assert!(
        typo_average < Duration::from_millis(50),
        "average search with typos exceeded the 50 ms budget: {typo_average:?}"
    );
}

fn synthetic_library(count: usize) -> Vec<TrackRecord> {
    (0..count)
        .map(|index| {
            let provider = match index % 4 {
                0 => "local",
                1 => "jellyfin",
                2 => "navidrome",
                _ => "plex",
            };
            TrackRecord::new(
                format!("track-{index}"),
                format!("Track {index} Midnight Signal"),
                format!("Artist {}", index % 1_500),
                format!("Album {}", index % 2_500),
                Some(format!("Artist {}", index % 1_500)),
                provider,
            )
        })
        .collect()
}
