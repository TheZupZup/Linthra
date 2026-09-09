cmake_minimum_required(VERSION 3.16)
project(linthra_desktop LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Pure desktop-shell policy: no GTK, no GDK, no filesystem. The Linux runner
# links these sources straight from linux/runner/CMakeLists.txt; this project
# exists so the same code can be built and tested on its own, without a display
# server or a window manager.
add_library(linthra_desktop STATIC
    src/window_state.cpp
)

target_include_directories(linthra_desktop
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_compile_options(linthra_desktop PRIVATE
    $<$<CXX_COMPILER_ID:Clang,GNU>:-Wall -Wextra -Wpedantic -Werror>
)

add_executable(linthra_desktop_tests tests/window_state_test.cpp)
target_link_libraries(linthra_desktop_tests PRIVATE linthra_desktop)

enable_testing()
add_test(NAME linthra_desktop_tests COMMAND linthra_desktop_tests)
