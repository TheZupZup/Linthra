#include "window_state_store.h"

#include <gdk/gdk.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include <string>
#include <string_view>
#include <vector>

#include "linthra_desktop/window_state.hpp"

using linthra::desktop::FormatWindowState;
using linthra::desktop::ResolveWindowState;
using linthra::desktop::WindowGeometry;
using linthra::desktop::WindowLimits;
using linthra::desktop::WorkArea;

// Name of the state file inside the app's own config directory. A plain file
// rather than GSettings: the geometry is a local convenience, not a preference
// worth a schema that has to be installed before the app can start.
static constexpr const char* kStateFileName = "window-state";

struct _WindowStateStore {
    GtkWindow* window;
    WindowLimits limits;

    // The last size the window had while it was an ordinary, restored window.
    // See the header: GTK will not tell us this after the fact.
    WindowGeometry tracked;

    gboolean maximized;
    gboolean fullscreen;

    gulong configure_handler;
    gulong state_handler;
    gulong destroy_handler;
};

namespace {

// Whether this session can report and set window positions at all.
bool SessionHasWindowPositions(GtkWindow* window) {
#ifdef GDK_WINDOWING_X11
    GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(window));
    return display != nullptr && GDK_IS_X11_DISPLAY(display);
#else
    (void)window;
    return false;
#endif
}

gchar* StateFilePath() {
    return g_build_filename(g_get_user_config_dir(), APPLICATION_ID,
                            kStateFileName, nullptr);
}

WindowGeometry LoadSavedState() {
    g_autofree gchar* path = StateFilePath();
    g_autofree gchar* contents = nullptr;
    gsize length = 0;
    if (!g_file_get_contents(path, &contents, &length, nullptr)) {
        // No file yet is the ordinary first-launch case, not a failure worth
        // logging at the user.
        return WindowGeometry{};
    }
    return linthra::desktop::ParseWindowState(
        std::string_view(contents, length));
}

// The work areas of every monitor attached right now, so a saved position can
// be checked against the desktop as it *is* rather than as it was.
std::vector<WorkArea> CurrentWorkAreas(GtkWindow* window) {
    std::vector<WorkArea> areas;
    GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(window));
    if (display == nullptr) {
        return areas;
    }
    const int count = gdk_display_get_n_monitors(display);
    for (int i = 0; i < count; ++i) {
        GdkMonitor* monitor = gdk_display_get_monitor(display, i);
        if (monitor == nullptr) {
            continue;
        }
        GdkRectangle rectangle;
        gdk_monitor_get_workarea(monitor, &rectangle);
        areas.push_back(
            WorkArea{rectangle.x, rectangle.y, rectangle.width,
                     rectangle.height});
    }
    return areas;
}

gboolean OnConfigure(GtkWidget* widget, GdkEventConfigure* event,
                     gpointer user_data) {
    (void)widget;
    WindowStateStore* self = static_cast<WindowStateStore*>(user_data);
    // Only an ordinary window's geometry is worth remembering: a maximized or
    // fullscreen one describes the screen, not the size to come back to.
    if (self->maximized || self->fullscreen) {
        return FALSE;
    }
    self->tracked.width = event->width;
    self->tracked.height = event->height;
    if (self->tracked.has_position) {
        gtk_window_get_position(self->window, &self->tracked.x,
                                &self->tracked.y);
    }
    return FALSE;  // Never stop the event: GTK still has to lay the window out.
}

gboolean OnWindowState(GtkWidget* widget, GdkEventWindowState* event,
                       gpointer user_data) {
    (void)widget;
    WindowStateStore* self = static_cast<WindowStateStore*>(user_data);
    if (event->changed_mask & GDK_WINDOW_STATE_MAXIMIZED) {
        self->maximized =
            (event->new_window_state & GDK_WINDOW_STATE_MAXIMIZED) != 0;
    }
    if (event->changed_mask & GDK_WINDOW_STATE_FULLSCREEN) {
        self->fullscreen =
            (event->new_window_state & GDK_WINDOW_STATE_FULLSCREEN) != 0;
    }
    return FALSE;
}

// The window is destroyed before GApplication::shutdown runs, so the store
// outlives it. Forgetting it here is what lets the teardown stay simple:
// nothing after this point touches a dead object, and the geometry still to be
// written is tracked in the store rather than read back off the window.
void OnDestroy(GtkWidget* widget, gpointer user_data) {
    (void)widget;
    WindowStateStore* self = static_cast<WindowStateStore*>(user_data);
    self->window = nullptr;
}

}  // namespace

WindowStateStore* window_state_store_new(GtkWindow* window, int min_width,
                                         int min_height, int default_width,
                                         int default_height) {
    WindowStateStore* self = g_new0(WindowStateStore, 1);
    self->window = window;
    self->limits =
        WindowLimits{min_width, min_height, default_width, default_height};

    const WindowGeometry resolved = ResolveWindowState(
        LoadSavedState(), self->limits,
        SessionHasWindowPositions(window) ? CurrentWorkAreas(window)
                                          : std::vector<WorkArea>{});

    gtk_window_set_default_size(window, resolved.width, resolved.height);
    if (resolved.has_position) {
        gtk_window_move(window, resolved.x, resolved.y);
    }
    if (resolved.maximized) {
        gtk_window_maximize(window);
    }

    self->tracked = resolved;
    // Whether *future* positions are worth recording is a property of the
    // session, not of what happened to be saved: a first launch under X11 has
    // no saved position and still wants to remember the one it ends up with.
    self->tracked.has_position = SessionHasWindowPositions(window);
    self->maximized = resolved.maximized ? TRUE : FALSE;
    self->fullscreen = FALSE;

    self->configure_handler = g_signal_connect(
        window, "configure-event", G_CALLBACK(OnConfigure), self);
    self->state_handler = g_signal_connect(
        window, "window-state-event", G_CALLBACK(OnWindowState), self);
    self->destroy_handler =
        g_signal_connect(window, "destroy", G_CALLBACK(OnDestroy), self);
    return self;
}

void window_state_store_save(WindowStateStore* self) {
    if (self == nullptr) {
        return;
    }
    WindowGeometry geometry = self->tracked;
    geometry.maximized = self->maximized != FALSE;

    g_autofree gchar* path = StateFilePath();
    g_autofree gchar* directory = g_path_get_dirname(path);
    if (g_mkdir_with_parents(directory, 0755) != 0) {
        g_warning("Could not create %s, so the window size will not be "
                  "remembered",
                  directory);
        return;
    }

    const std::string contents = FormatWindowState(geometry);
    g_autoptr(GError) error = nullptr;
    if (!g_file_set_contents(path, contents.c_str(),
                             static_cast<gssize>(contents.size()), &error)) {
        // A window size is never worth failing a shutdown over.
        g_warning("Could not save the window state: %s", error->message);
    }
}

void window_state_store_free(WindowStateStore* self) {
    if (self == nullptr) {
        return;
    }
    // Only where the window is still alive: a destroyed one dropped its
    // handlers with itself, and OnDestroy has already cleared the pointer.
    //
    // The destroy handler goes with the other two rather than being left
    // behind. Freeing the store while its window is still alive is the unusual
    // order — a disposal, or a startup unwound before GTK destroys anything —
    // and leaving that one handler registered would hand OnDestroy this freed
    // struct the moment the window did go away.
    if (self->window != nullptr) {
        for (const gulong handler : {self->configure_handler,
                                     self->state_handler,
                                     self->destroy_handler}) {
            if (handler != 0) {
                g_signal_handler_disconnect(self->window, handler);
            }
        }
    }
    g_free(self);
}
