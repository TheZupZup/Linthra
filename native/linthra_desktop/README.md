# linthra_desktop

The parts of Linthra's Linux desktop shell that are pure decisions rather than
toolkit calls, so they can be tested without a display server.

Today that is the window-state policy behind #383: what a saved geometry means,
when it is too damaged to trust, and whether a remembered position still lands
on a monitor that exists. `linux/runner/` does the GTK/GDK half — reading the
config file, asking GDK for the monitors, moving the window — and calls in here
for every rule.

Build and test it on its own:

```sh
cmake -S native/linthra_desktop -B build/linthra_desktop
cmake --build build/linthra_desktop --parallel
ctest --test-dir build/linthra_desktop --output-on-failure
```

CI runs exactly that, in Debug and Release, from
`.github/workflows/cpp-desktop-window.yml`.
