cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME}
  "main.cc"
  "my_application.cc"
  "folder_picker_channel.cc"
  "window_lifecycle_channel.cc"
  "window_state_store.cc"
  # The pure half of the window-state policy (#383). Compiled straight into the
  # runner rather than linked as a library so the Flutter build stays one
  # CMake invocation; native/linthra_desktop builds and tests the same sources
  # on their own, with no GTK and no display server.
  "${CMAKE_SOURCE_DIR}/../native/linthra_desktop/src/window_state.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# The window-state policy (#383) is C++17: string_view, from_chars, and
# aggregates with default member initialisers. apply_standard_settings asks for
# cxx_std_14, which is a floor rather than a cap, so the standard the runner
# actually compiles with would otherwise be whatever the host compiler defaults
# to. Say it instead of depending on that.
target_compile_features(${BINARY_NAME} PUBLIC cxx_std_17)

# Add preprocessor definitions for the application ID.
add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")

# Add dependency libraries. Add any application-specific dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)

target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
target_include_directories(${BINARY_NAME} PRIVATE
  "${CMAKE_SOURCE_DIR}/../native/linthra_desktop/include")
