#!/usr/bin/env bash
# Fills corpus/<target>/ with the test fixtures each target starts from, so a
# fuzz run begins from real files instead of from nothing.
set -euo pipefail
cd "$(dirname "$0")"
fixtures=../../../test/fixtures/tags
seed() {
  local target=$1; shift
  mkdir -p "corpus/$target"
  for f in "$@"; do
    if [ -f "$f" ]; then cp "$f" "corpus/$target/"; fi
  done
}
seed tags_flac "$fixtures"/*.flac
seed tags_ogg "$fixtures"/*.ogg "$fixtures"/*.opus
seed tags_mp3 "$fixtures"/*.mp3
seed tags_mp4 "$fixtures"/*.m4a "$fixtures"/*.mp4
seed tags_wav "$fixtures"/*.wav
seed tags_aiff "$fixtures"/*.aiff "$fixtures"/*.aifc
seed tags_ape "$fixtures"/*.ape
seed tags_any "$fixtures"/*
seed tags_id3v2 seeds/id3v2/*
seed tags_vorbis_comments seeds/vorbis_comments/*
seed tags_picture seeds/picture/*
seed cue_sheet seeds/cue_sheet/*
seed subsonic_response seeds/subsonic_response/*
