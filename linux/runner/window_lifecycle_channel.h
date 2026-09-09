#ifndef RUNNER_WINDOW_LIFECYCLE_CHANNEL_H_
#define RUNNER_WINDOW_LIFECYCLE_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

G_BEGIN_DECLS

// The native half of Linthra's configurable close-window behaviour (#401).
//
// A GTK `delete-event` handler has to answer *now*: there is no way to ask
// Dart what to do and keep the window alive while the answer travels. So the
// decision is pushed the other way round. Dart's
// `DesktopWindowLifecycleService` recomputes "should the next close hide the
// window?" whenever the user's preference or playback changes and sends it
// here, and this channel then answers each close locally and instantly, with
// the answer the app would have given.
//
// The channel carries three calls in (`setHideOnClose`, `showWindow`, `quit`)
// and two out (`windowHidden`, `windowShown`), so Dart knows when it is
// running with no window on screen. That is what lets it quit itself once the
// queue ends instead of leaving an invisible process behind.
typedef struct _WindowLifecycleChannel WindowLifecycleChannel;

// Registers the window-lifecycle channel on `view`'s engine and takes over
// `window`'s close handling. Never returns NULL.
WindowLifecycleChannel* window_lifecycle_channel_new(FlView* view,
                                                     GtkWindow* window);

// Brings the window back and tells Dart it is visible again. Returns FALSE if
// there is no window left to present, which is the caller's cue to build one.
//
// This is what a *second launch* of an already-running Linthra ends up in: the
// runner is single-instance, so GTK forwards the launch to the running process
// as an activation instead of starting a duplicate.
gboolean window_lifecycle_channel_present(WindowLifecycleChannel* self);

// Tears the channel down: drops the signal handlers it installed and cancels a
// quit it had not got round to yet.
void window_lifecycle_channel_free(WindowLifecycleChannel* self);

G_END_DECLS

#endif  // RUNNER_WINDOW_LIFECYCLE_CHANNEL_H_
