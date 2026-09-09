#ifndef RUNNER_WINDOW_STATE_STORE_H_
#define RUNNER_WINDOW_STATE_STORE_H_

#include <gtk/gtk.h>

G_BEGIN_DECLS

// Remembers the window's size, maximized state and (where the session can) its
// position across restarts — issue #383.
//
// The toolkit half only. Every rule about what a saved geometry means lives in
// native/linthra_desktop (`linthra::desktop`), which is pure and unit-tested;
// this file reads and writes the file, asks GDK which monitors exist, and moves
// the window.
//
// Two things are worth knowing about the shape of it:
//
//  * GTK 3 does not remember the *unmaximized* size for you:
//    gtk_window_get_size() on a maximized window returns the maximized size, so
//    restoring it would leave a window that un-maximizes to full screen. The
//    store therefore tracks the last size the window had while it was neither
//    maximized nor fullscreen, and saves that.
//
//  * Position is X11-only. Wayland gives a client neither its own position nor
//    a way to set one, so under Wayland the store saves a size and no position
//    and lets the compositor place the window — which is the behaviour Wayland
//    users expect, not a limitation to work around.
typedef struct _WindowStateStore WindowStateStore;

// Restores `window`'s geometry from disk and starts tracking changes to it.
//
// Call before the window is shown: it sets the default size, so a restored
// window is drawn at its remembered size on the first frame rather than
// resizing in front of the user. Falls back to `default_width`/`default_height`
// for a missing, damaged or unusable saved state, and never returns a size
// below `min_width`/`min_height`. Never returns NULL.
WindowStateStore* window_state_store_new(GtkWindow* window, int min_width,
                                         int min_height, int default_width,
                                         int default_height);

// Writes the tracked geometry to disk. Safe to call more than once; a failure
// to write is logged and otherwise ignored, since losing a window size must
// never take the shutdown with it.
void window_state_store_save(WindowStateStore* self);

// Stops tracking and frees the store. Does not save: call
// window_state_store_save() first if the geometry still matters.
void window_state_store_free(WindowStateStore* self);

G_END_DECLS

#endif  // RUNNER_WINDOW_STATE_STORE_H_
