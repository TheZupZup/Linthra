#include "window_lifecycle_channel.h"

// The channel and method names Dart's MethodChannelLinuxWindow uses.
// scripts/check_linux_runner.py holds the two sides to the same strings, so a
// rename on one side fails a check instead of silently leaving every window
// close doing whatever it did before the preference existed.
static constexpr const char* kChannelName =
    "io.github.thezupzup.linthra/linux_window_lifecycle";
static constexpr const char* kSetHideOnCloseMethod = "setHideOnClose";
static constexpr const char* kShowWindowMethod = "showWindow";
static constexpr const char* kQuitMethod = "quit";
static constexpr const char* kWindowHiddenMethod = "windowHidden";
static constexpr const char* kWindowShownMethod = "windowShown";
static constexpr const char* kHideOnCloseArgument = "hideOnClose";

// Sent back when `setHideOnClose` arrives without the boolean it is named
// after. Dart never does that; a build whose two halves disagree would, and it
// should say so rather than quietly keeping the old behaviour.
static constexpr const char* kInvalidArgumentsError = "invalid_arguments";
// There is no window to act on: it has already been destroyed, or the app is
// on its way out.
static constexpr const char* kNoWindowError = "no_window";

struct _WindowLifecycleChannel {
  FlMethodChannel* channel;
  // The application window. Cleared when GTK destroys it, so nothing here can
  // reach a window that is already gone.
  GtkWindow* window;
  // What the next close does. FALSE (quit) until Dart says otherwise, which is
  // deliberate: a runner that has not heard from the app behaves exactly like
  // the one that shipped before this feature.
  gboolean hide_on_close;
  gulong delete_event_handler;
  gulong destroy_handler;
  // A pending `quit`, so it can be cancelled if the app goes away first.
  guint quit_source;
};

// Tells Dart the window is now hidden / visible again. Fire-and-forget: this
// is a notification, and there is nothing useful to do about a failure to
// deliver one.
static void notify_visibility(WindowLifecycleChannel* self,
                              const char* method) {
  g_autoptr(FlValue) args = fl_value_new_null();
  fl_method_channel_invoke_method(self->channel, method, args, nullptr, nullptr,
                                  nullptr);
}

static void respond_error(FlMethodCall* method_call, const char* code,
                          const char* message) {
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_error_response_new(code, message, nullptr));
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("Failed to send window lifecycle error: %s", error->message);
  }
}

static void respond_success(FlMethodCall* method_call) {
  g_autoptr(FlValue) result = fl_value_new_null();
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond_success(method_call, result, &error)) {
    g_warning("Failed to send window lifecycle result: %s", error->message);
  }
}

// The close button, the window menu, Alt+F4 and a compositor's close request
// all arrive here.
static gboolean window_delete_event_cb(GtkWidget* widget, GdkEvent* event,
                                       gpointer user_data) {
  WindowLifecycleChannel* self =
      static_cast<WindowLifecycleChannel*>(user_data);
  if (!self->hide_on_close) {
    // Let GTK destroy the window. That takes the engine down with it, which is
    // where Dart's own graceful shutdown runs.
    return FALSE;
  }

  // Hidden, not destroyed: the window stays a GtkApplication window, so the
  // application keeps running, the audio engine is untouched, and the MPRIS
  // name stays on the bus.
  gtk_widget_hide(widget);
  notify_visibility(self, kWindowHiddenMethod);
  return TRUE;
}

static void window_destroy_cb(GtkWidget* widget, gpointer user_data) {
  WindowLifecycleChannel* self =
      static_cast<WindowLifecycleChannel*>(user_data);
  self->window = nullptr;
  self->delete_event_handler = 0;
  self->destroy_handler = 0;
}

// Destroying the window ends the process, so it happens after the reply to
// `quit` has been sent rather than inside the call that asked for it.
static gboolean quit_in_idle_cb(gpointer user_data) {
  WindowLifecycleChannel* self =
      static_cast<WindowLifecycleChannel*>(user_data);
  self->quit_source = 0;
  if (self->window == nullptr) return G_SOURCE_REMOVE;
  // Past this point a close must never be turned into a hide.
  self->hide_on_close = FALSE;
  gtk_widget_destroy(GTK_WIDGET(self->window));
  return G_SOURCE_REMOVE;
}

static void handle_set_hide_on_close(WindowLifecycleChannel* self,
                                     FlMethodCall* method_call) {
  FlValue* args = fl_method_call_get_args(method_call);
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    respond_error(method_call, kInvalidArgumentsError,
                  "setHideOnClose expects a map argument.");
    return;
  }
  FlValue* value = fl_value_lookup_string(args, kHideOnCloseArgument);
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_BOOL) {
    respond_error(method_call, kInvalidArgumentsError,
                  "setHideOnClose expects a bool hideOnClose.");
    return;
  }
  self->hide_on_close = fl_value_get_bool(value) ? TRUE : FALSE;
  respond_success(method_call);
}

static void window_lifecycle_method_call_cb(FlMethodChannel* channel,
                                            FlMethodCall* method_call,
                                            gpointer user_data) {
  WindowLifecycleChannel* self =
      static_cast<WindowLifecycleChannel*>(user_data);
  const gchar* name = fl_method_call_get_name(method_call);

  if (g_strcmp0(name, kSetHideOnCloseMethod) == 0) {
    handle_set_hide_on_close(self, method_call);
    return;
  }

  if (g_strcmp0(name, kShowWindowMethod) == 0) {
    if (!window_lifecycle_channel_present(self)) {
      respond_error(method_call, kNoWindowError,
                    "There is no window to show.");
      return;
    }
    respond_success(method_call);
    return;
  }

  if (g_strcmp0(name, kQuitMethod) == 0) {
    if (self->window == nullptr) {
      respond_error(method_call, kNoWindowError,
                    "There is no window to close.");
      return;
    }
    if (self->quit_source == 0) {
      self->quit_source = g_idle_add(quit_in_idle_cb, self);
    }
    respond_success(method_call);
    return;
  }

  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("Failed to respond to window lifecycle call: %s", error->message);
  }
}

WindowLifecycleChannel* window_lifecycle_channel_new(FlView* view,
                                                     GtkWindow* window) {
  WindowLifecycleChannel* self = g_new0(WindowLifecycleChannel, 1);
  self->window = window;
  self->hide_on_close = FALSE;

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlEngine* engine = fl_view_get_engine(view);
  self->channel = fl_method_channel_new(fl_engine_get_binary_messenger(engine),
                                        kChannelName, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      self->channel, window_lifecycle_method_call_cb, self, nullptr);

  self->delete_event_handler =
      g_signal_connect(window, "delete-event",
                       G_CALLBACK(window_delete_event_cb), self);
  self->destroy_handler =
      g_signal_connect(window, "destroy", G_CALLBACK(window_destroy_cb), self);
  return self;
}

gboolean window_lifecycle_channel_present(WindowLifecycleChannel* self) {
  if (self == nullptr || self->window == nullptr) return FALSE;
  gtk_window_present(self->window);
  notify_visibility(self, kWindowShownMethod);
  return TRUE;
}

void window_lifecycle_channel_free(WindowLifecycleChannel* self) {
  if (self == nullptr) return;
  if (self->quit_source != 0) {
    g_source_remove(self->quit_source);
    self->quit_source = 0;
  }
  if (self->window != nullptr) {
    if (self->delete_event_handler != 0) {
      g_signal_handler_disconnect(self->window, self->delete_event_handler);
    }
    if (self->destroy_handler != 0) {
      g_signal_handler_disconnect(self->window, self->destroy_handler);
    }
    self->window = nullptr;
  }
  g_clear_object(&self->channel);
  g_free(self);
}
