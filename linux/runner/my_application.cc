#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"
#include "folder_picker_channel.h"

// The user-visible application name. Kept as one constant so the header bar,
// the fallback title bar, and anything added later can never drift apart — and
// so it stays greppable against the Dart-side `AppInfo.name` and the Android
// `android:label`. scripts/check_linux_runner.py enforces that agreement.
static constexpr const char* kApplicationName = "Linthra";

// Opening window size on a desktop. Wide enough to feel like a desktop app
// rather than a stretched phone, without pretending the desktop layout (a later
// PR) already exists.
static constexpr int kDefaultWindowWidth = 1180;
static constexpr int kDefaultWindowHeight = 780;

// The narrowest/shortest the window may be dragged. Roughly a large phone, the
// shape the current shared layout is written for.
static constexpr int kMinimumWindowWidth = 420;
static constexpr int kMinimumWindowHeight = 600;

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  // The GTK/portal folder chooser Dart asks for a music folder (#438). Owned
  // here because it needs the application's own window as the dialog parent,
  // which a plugin registrant does not have.
  FolderPickerChannel* folder_picker;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Set the icon on the concrete toplevel as well as keeping the application
  // default below. The default is only a fallback; explicitly naming the icon
  // here makes GTK materialize the window icon on X11 so _NET_WM_ICON is
  // available to panels and task switchers, while Wayland continues to resolve
  // the same icon from the application id.
  gtk_window_set_icon_name(window, APPLICATION_ID);

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, kApplicationName);
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, kApplicationName);
  }

  gtk_window_set_default_size(window, kDefaultWindowWidth,
                              kDefaultWindowHeight);

  // Floor the window at a size the current (phone-first) Flutter layout can
  // still render without overflowing. Linthra's desktop layout lands in a later
  // PR; until then this keeps a dragged-narrow window usable for development
  // rather than letting it collapse into a wall of overflow errors.
  GdkGeometry geometry;
  geometry.min_width = kMinimumWindowWidth;
  geometry.min_height = kMinimumWindowHeight;
  gtk_window_set_geometry_hints(window, nullptr, &geometry, GDK_HINT_MIN_SIZE);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  // Registered alongside the plugins, on the same engine: the folder chooser
  // is Linthra's own channel rather than a plugin, so that a Flatpak build
  // gets the xdg-desktop-portal chooser instead of `file_picker`'s
  // zenity/kdialog, which the sandbox does not contain. See
  // folder_picker_channel.h.
  self->folder_picker = folder_picker_channel_new(view, window);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Chain up first. GtkApplication::startup is what calls gtk_init(), and
  // gtk_init() reaches gdk_pre_parse(), which unconditionally resets GDK's
  // program class from g_get_prgname(). Anything set below before this line
  // would be silently overwritten, so the order here is part of the fix rather
  // than a style choice.
  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);

  // === Desktop identity (#554) ===
  //
  // Several different names leave this process, and a desktop only groups the
  // running window under the installed launcher when they all agree with
  // io.github.thezupzup.linthra: the id of the desktop entry, the icon, the
  // AppStream component and the Flatpak. Each one below is derived from
  // APPLICATION_ID (linux/CMakeLists.txt) rather than written out again, so
  // there is no second copy of the id that can drift.
  // scripts/check_linux_runner.py enforces the calls and this ordering.
  //
  // The Wayland half is already handled in my_application_new(): GTK 3 sends
  // xdg_toplevel.set_app_id() from g_get_prgname().

  // The human-readable name. Without it, g_get_application_name() falls back to
  // g_get_prgname(), which my_application_new() has deliberately set to the
  // reverse-DNS id, so portal dialogs and GTK's own "application is not
  // responding" prompt would say "io.github.thezupzup.linthra" at the user.
  g_set_application_name(kApplicationName);

  // X11, including XWayland under the Flatpak's --socket=fallback-x11. GTK
  // stamps WM_CLASS from g_get_prgname() and gdk_get_program_class() when each
  // GtkWindow is constructed, and the class half defaults to the program name
  // with its first letter upper-cased ("Io.github.thezupzup.linthra"), which is
  // not a string any launcher indexes. Shells that lower-case as a fallback
  // still find us; ones that compare exactly do not, and the window then drops
  // out of its launcher group. Setting the class explicitly makes both halves
  // of WM_CLASS the application id, which is also what the desktop entry's
  // StartupWMClass= declares.
  gdk_set_program_class(APPLICATION_ID);

  // The themed window icon. GTK never sets one by itself, so the window carried
  // no _NET_WM_ICON at all and every task switcher, panel and window list that
  // reads the window's own icon instead of resolving a desktop entry fell back
  // to a generic placeholder. This resolves
  // hicolor/scalable/apps/io.github.thezupzup.linthra.svg, the icon the Flatpak
  // installs from tool/branding/linthra_icon.svg, through the ordinary icon
  // theme lookup: it works wherever the icon is installed and is a harmless
  // no-op where it is not. Wayland has no window-icon protocol and keeps
  // resolving the same file from the app id instead.
  gtk_window_set_default_icon_name(APPLICATION_ID);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_pointer(&self->folder_picker, folder_picker_channel_free);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  //
  // Concretely (#554): this is the Wayland half of the identity. GTK 3 sends
  // xdg_toplevel.set_app_id() straight from g_get_prgname(), so this call is
  // what makes GNOME and KDE Plasma resolve the running window to
  // io.github.thezupzup.linthra.desktop under Wayland. It also supplies the
  // instance half of X11's WM_CLASS; my_application_startup() sets the class
  // half, which GDK would otherwise derive from this name.
  //
  // It has to happen before gtk_init(), which GtkApplication::startup calls,
  // because GDK reads the program name there.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
