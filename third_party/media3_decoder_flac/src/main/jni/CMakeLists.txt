# Linthra's build for Media3's FLAC JNI wrapper (libflacJNI.so).
#
# This file is Linthra's own, not upstream Media3's: upstream builds all of
# libFLAC through libFLAC's CMake project, cloned from its default branch. Here
# the decoder-only subset vendored in third_party/libflac (pinned to 1.5.0, see
# its PATCHES.md) is compiled directly, with fixed definitions instead of a
# generated config.h, so the build needs nothing outside this repository.
#
# The source list is the link closure of the FLAC__stream_decoder_* API the JNI
# glue calls. If a libFLAC update adds a dependency, the link fails loudly on
# `--no-undefined` rather than silently picking something up.

cmake_minimum_required(VERSION 3.18.1)

project(flacJNI C CXX)

set(CMAKE_CXX_STANDARD 11)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
# gnu99 rather than c99: stream_decoder.c uses POSIX fileno() for its FILE*
# entry points (unused by the JNI glue, but compiled).
set(CMAKE_C_STANDARD 99)
set(CMAKE_C_EXTENSIONS ON)

set(LIBFLAC_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../../libflac")
if(NOT EXISTS "${LIBFLAC_ROOT}/src/libFLAC/stream_decoder.c")
  message(FATAL_ERROR "Vendored libFLAC not found at ${LIBFLAC_ROOT}")
endif()

# The NDK toolchain already passes -D_FORTIFY_SOURCE=2 on Android. Elsewhere
# (the host sanitizer build that validates this file) set it here, only for
# optimized builds, where it has an effect.
if(NOT ANDROID)
  add_compile_definitions($<$<NOT:$<CONFIG:Debug>>:_FORTIFY_SOURCE=2>)
endif()

add_library(flac_decoder STATIC
  "${LIBFLAC_ROOT}/src/libFLAC/bitmath.c"
  "${LIBFLAC_ROOT}/src/libFLAC/bitreader.c"
  "${LIBFLAC_ROOT}/src/libFLAC/cpu.c"
  "${LIBFLAC_ROOT}/src/libFLAC/crc.c"
  "${LIBFLAC_ROOT}/src/libFLAC/fixed.c"
  "${LIBFLAC_ROOT}/src/libFLAC/format.c"
  "${LIBFLAC_ROOT}/src/libFLAC/lpc.c"
  "${LIBFLAC_ROOT}/src/libFLAC/md5.c"
  "${LIBFLAC_ROOT}/src/libFLAC/memory.c"
  "${LIBFLAC_ROOT}/src/libFLAC/stream_decoder.c")

# Linked into a shared library. The NDK already defaults to PIC; stated so
# the host sanitizer build behaves the same.
set_target_properties(flac_decoder PROPERTIES POSITION_INDEPENDENT_CODE ON)

target_include_directories(flac_decoder
  PUBLIC "${LIBFLAC_ROOT}/include"
  PRIVATE "${LIBFLAC_ROOT}/src/libFLAC/include")

target_compile_definitions(flac_decoder
  PUBLIC
    FLAC__NO_DLL
  PRIVATE
    PACKAGE_VERSION="1.5.0"
    # Portable C only: no SSE/AVX/NEON paths and no runtime CPU dispatch, so
    # every ABI runs the same, fuzzed reference code.
    FLAC__NO_ASM
    FLAC__HAS_X86INTRIN=0
    FLAC__HAS_NEONINTRIN=0
    FLAC__HAS_A64NEONINTRIN=0
    # Media3's OggExtractor unwraps Ogg FLAC before it reaches this decoder.
    FLAC__HAS_OGG=0
    # Every Android ABI Linthra ships is little-endian.
    CPU_IS_BIG_ENDIAN=0
    ENABLE_64_BIT_WORDS=0
    HAVE_LROUND=1
    HAVE_STDINT_H
    HAVE_INTTYPES_H
    HAVE_SYS_PARAM_H)

# The repository root, stripped from every path the compiler records (the JNI
# glue's TRESPASS() uses __FILE__), so the library does not depend on where the
# checkout lives. F-Droid verifies that its rebuild matches the published APK
# byte for byte; this keeps the checkout path from ever being the difference.
get_filename_component(LINTHRA_REPO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../../.." ABSOLUTE)

set(LINTHRA_HARDENING_FLAGS
  -fstack-protector-strong
  -fvisibility=hidden
  "-ffile-prefix-map=${LINTHRA_REPO_ROOT}/="
  -Wno-cast-align)

target_compile_options(flac_decoder PRIVATE
  ${LINTHRA_HARDENING_FLAGS}
  # A crafted file can push libFLAC's LPC/channel-decorrelation sums past
  # INT32_MAX. Upstream treats that as expected on bogus input (audio values
  # only, never sizes or indices) and silences it only in OSS-Fuzz builds.
  # -fwrapv makes the wraparound defined behaviour instead of leaving it
  # undefined, so the optimizer can never exploit it. Garbage in, garbage
  # samples out; nothing else.
  -fwrapv)

add_library(flacJNI SHARED
  flac_jni.cc
  flac_parser.cc)

# flac_parser.h includes "include/data_source.h" relative to this directory.
target_include_directories(flacJNI PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
target_compile_options(flacJNI PRIVATE ${LINTHRA_HARDENING_FLAGS})

target_link_libraries(flacJNI PRIVATE flac_decoder)

if(ANDROID)
  find_library(android_log_lib log)
  target_link_libraries(flacJNI PRIVATE ${android_log_lib})
  # Only the JNIEXPORT entry points leave the library; libFLAC's symbols stay
  # internal. Full RELRO, and fail the build on any unresolved symbol.
  target_link_options(flacJNI PRIVATE
    -Wl,--exclude-libs,ALL
    -Wl,-z,relro
    -Wl,-z,now
    -Wl,--no-undefined
    # 16 KB page alignment (required on Android 15+ devices with 16 KB pages).
    # NDK r28+ does this by default; stated explicitly so an older NDK cannot
    # quietly produce 4 KB-aligned segments.
    -Wl,-z,max-page-size=16384)
endif()
