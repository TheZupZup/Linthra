cmake_minimum_required(VERSION 3.16)
project(linthra_audio LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_library(linthra_audio STATIC
    src/dsp.cpp
    src/c_api.cpp
)

target_include_directories(linthra_audio
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_compile_options(linthra_audio PRIVATE
    $<$<CXX_COMPILER_ID:Clang,GNU>:-Wall -Wextra -Wpedantic -Werror>
)

add_executable(linthra_audio_tests tests/dsp_test.cpp)
target_link_libraries(linthra_audio_tests PRIVATE linthra_audio)

# Limiter response (#337) and bypass transparency (#342) are their own binaries
# rather than more of dsp_test.cpp: each is a focused contract, and a failure
# names which one broke. The allocation test has to be separate: it replaces
# global operator new, which is program-wide.
add_executable(linthra_audio_limiter_tests tests/limiter_test.cpp)
target_link_libraries(linthra_audio_limiter_tests PRIVATE linthra_audio)

add_executable(linthra_audio_bypass_tests tests/bypass_test.cpp)
target_link_libraries(linthra_audio_bypass_tests PRIVATE linthra_audio)

add_executable(linthra_audio_allocation_tests tests/realtime_allocation_test.cpp)
target_link_libraries(linthra_audio_allocation_tests PRIVATE linthra_audio)

# Replacing operator new only covers the C++ half of "allocation-free": a
# scratch buffer taken with std::malloc would go unseen, and the test would
# certify a contract it had not checked. --wrap redirects the C entry points at
# link time and reaches into the static library, so it covers linthra_audio
# itself rather than only the test translation unit.
#
# GNU ld and lld only. Elsewhere the test still runs and still checks the C++
# paths; it reports which half it covered rather than claiming both.
if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang" AND UNIX AND NOT APPLE)
    target_link_options(linthra_audio_allocation_tests PRIVATE
        -Wl,--wrap=malloc
        -Wl,--wrap=calloc
        -Wl,--wrap=realloc
        -Wl,--wrap=aligned_alloc
        -Wl,--wrap=posix_memalign
    )
    target_compile_definitions(linthra_audio_allocation_tests
        PRIVATE LINTHRA_WRAP_C_ALLOCATOR=1
    )
    # The sanity block deliberately allocates so the counter can be seen
    # working. Treated as builtins, those calls are dead code the optimiser is
    # entitled to delete (Clang at -O2 removes the whole malloc/realloc/calloc
    # sequence), and the check meant to prove the counter works reports zero.
    # This says "these are ordinary function calls here", which is exactly what
    # a test that counts them needs.
    target_compile_options(linthra_audio_allocation_tests PRIVATE
        -fno-builtin-malloc
        -fno-builtin-calloc
        -fno-builtin-realloc
        -fno-builtin-free
    )
endif()

add_executable(linthra_audio_benchmark tests/realtime_benchmark.cpp)
target_link_libraries(linthra_audio_benchmark PRIVATE linthra_audio)

enable_testing()
add_test(NAME linthra_audio_tests COMMAND linthra_audio_tests)
add_test(NAME linthra_audio_limiter COMMAND linthra_audio_limiter_tests)
add_test(NAME linthra_audio_bypass COMMAND linthra_audio_bypass_tests)
add_test(NAME linthra_audio_allocation COMMAND linthra_audio_allocation_tests)
add_test(NAME linthra_audio_realtime_budget COMMAND linthra_audio_benchmark)
