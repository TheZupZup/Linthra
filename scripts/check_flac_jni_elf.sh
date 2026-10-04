#!/usr/bin/env bash
#
# check_flac_jni_elf.sh: check the libflacJNI.so an APK carries, per ABI.
#
# third_party/media3_decoder_flac/src/main/jni/CMakeLists.txt promises a few
# things about the FLAC fallback's native library that none of the source-level
# tests can see, because they only exist once the NDK has linked it. This reads
# them back from the built library:
#
#   * no GNU build ID note. The linker hashes the unstripped library, debug
#     info and its NDK and build-directory paths included, so the ID changes
#     with where the build ran even though nothing else does. F-Droid compares
#     its rebuild with the published APK byte for byte and failed on exactly
#     that (#703).
#   * full RELRO: a GNU_RELRO segment, and BIND_NOW.
#   * every LOAD segment aligned to 16 KB (Android 15+ devices with 16 KB pages).
#   * a non-executable stack.
#   * only JNI entry points exported (hidden visibility, --exclude-libs).
#   * the stack protector in use (__stack_chk_fail is imported).
#
# Usage: scripts/check_flac_jni_elf.sh <apk> [abi...]
#   abi defaults to every ABI Linthra ships: armeabi-v7a arm64-v8a x86_64.
#   A requested ABI that the APK does not carry fails the check.
#
# Needs unzip and readelf (binutils reads every ABI's ELF on any host).

set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <apk> [abi...]" >&2
  exit 2
fi
apk="$1"
shift
if [ "$#" -gt 0 ]; then
  abis=("$@")
else
  abis=(armeabi-v7a arm64-v8a x86_64)
fi
if [ ! -f "$apk" ]; then
  echo "error: no such APK: $apk" >&2
  exit 2
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

failures=0
fail() {
  echo "  FAIL: $1"
  failures=$((failures + 1))
}

for abi in "${abis[@]}"; do
  entry="lib/$abi/libflacJNI.so"
  so="$tmp/$abi-libflacJNI.so"
  echo "$entry"
  if ! unzip -p "$apk" "$entry" >"$so" 2>/dev/null || [ ! -s "$so" ]; then
    fail "$apk carries no $entry"
    continue
  fi

  notes="$(readelf -W -n "$so")"
  segments="$(readelf -W -l "$so")"
  dynamic="$(readelf -W -d "$so")"
  dynsyms="$(readelf -W --dyn-syms "$so")"

  if grep -q 'NT_GNU_BUILD_ID' <<<"$notes"; then
    fail "has a GNU build ID ($(sed -n 's/.*Build ID: *//p' <<<"$notes")); F-Droid's rebuild cannot match it (#703)"
  fi

  grep -q 'GNU_RELRO' <<<"$segments" || fail "no GNU_RELRO segment (-z relro)"
  grep -Eq '\(FLAGS\).*BIND_NOW|\(FLAGS_1\).*NOW' <<<"$dynamic" ||
    fail "not linked with BIND_NOW (-z now)"

  loads=0
  while read -r align; do
    loads=$((loads + 1))
    if [ $((align)) -lt 16384 ]; then
      fail "a LOAD segment is aligned to $align, not 16 KB (-z max-page-size=16384)"
    fi
  done < <(awk '$1 == "LOAD" {print $NF}' <<<"$segments")
  [ "$loads" -gt 0 ] || fail "no LOAD segments found"

  stack="$(awk '$1 == "GNU_STACK"' <<<"$segments")"
  if [ -z "$stack" ]; then
    fail "no GNU_STACK segment, so the stack defaults to executable"
  elif grep -q 'RWE' <<<"$stack"; then
    fail "executable stack"
  fi

  # Defined dynamic symbols with global or weak binding are the library's API.
  exported="$(awk '$7 != "UND" && $7 != "Ndx" && ($5 == "GLOBAL" || $5 == "WEAK") {sub(/@.*/, "", $8); print $8}' <<<"$dynsyms")"
  if [ -z "$exported" ]; then
    fail "exports nothing; the JNI entry points are missing"
  fi
  unexpected="$(grep -Ev '^(Java_|JNI_OnLoad$|JNI_OnUnload$)' <<<"$exported" || true)"
  if [ -n "$unexpected" ]; then
    fail "exports more than its JNI entry points: $(tr '\n' ' ' <<<"$unexpected")"
  fi

  awk '$7 == "UND" {print $8}' <<<"$dynsyms" | grep -q '^__stack_chk_fail\(@\|$\)' ||
    fail "does not use the stack protector (no __stack_chk_fail import)"
done

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed."
  exit 1
fi
echo "OK: libflacJNI.so is hardened and carries no build ID, for ${abis[*]}."
