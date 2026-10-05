#include "folder_picker_channel.h"

#include <cstring>

// The channel and method names Dart's MethodChannelLinuxFolderPicker uses.
// scripts/check_linux_runner.py holds the two sides to the same strings, so a
// rename on one side fails a check instead of silently making every pick look
// like "no chooser available".
static constexpr const char* kChannelName =
    "io.github.thezupzup.linthra/linux_folder_picker";
static constexpr const char* kPickFolderMethod = "pickFolder";
// Asks where to save a file (#748), on the same channel: one chooser at a time
// for both, and the same way of answering. The reply is the path to write, or
// null when the user cancelled; Dart writes the file itself.
static constexpr const char* kSaveFileMethod = "saveFile";
static constexpr const char* kTitleArgument = "title";
static constexpr const char* kInitialDirectoryArgument = "initialDirectory";
static constexpr const char* kSuggestedNameArgument = "suggestedName";

// Returned when GTK could not create a chooser at all. Dart treats this one
// code (and a missing channel) as "no native chooser here" and falls back to
// the plugin chooser; every other error is just "no folder chosen".
static constexpr const char* kChooserUnavailableError = "chooser_unavailable";
// A second pick while one is already open. Refused rather than stacking two
// dialogs (or, under the portal, two host-side requests).
static constexpr const char* kPickInProgressError = "pick_in_progress";
// The user picked something that is not a local path — a network share or a
// virtual location `dart:io` cannot walk or write.
static constexpr const char* kUnsupportedLocationError = "unsupported_location";

// Only used if Dart sends no title; the user-facing strings live with the rest
// of the app's copy, on the Dart side.
static constexpr const char* kDefaultTitle = "Select a folder";
static constexpr const char* kDefaultSaveTitle = "Save file";

struct _FolderPickerChannel {
  FlMethodChannel* channel;
  GtkWindow* window;
  // The chooser currently on screen, and the call it will answer. Both null
  // when no pick is in flight; they are only ever set and cleared together.
  GtkFileChooserNative* chooser;
  FlMethodCall* pending_call;
};

static void respond_error(FlMethodCall* method_call, const char* code,
                          const char* message) {
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_error_response_new(code, message, nullptr));
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("Failed to send folder picker error: %s", error->message);
  }
}

// Answers the pending call with the chosen path (or null for a cancel) and
// disposes of the chooser.
static void folder_picker_response_cb(GtkNativeDialog* dialog, gint response_id,
                                      gpointer user_data) {
  FolderPickerChannel* self = static_cast<FolderPickerChannel*>(user_data);
  g_autoptr(FlMethodCall) method_call = self->pending_call;
  self->pending_call = nullptr;

  g_autofree gchar* path = nullptr;
  if (response_id == GTK_RESPONSE_ACCEPT) {
    // Inside a Flatpak this is the document-portal path the portal exported
    // for the folder the user chose on the host, which is exactly what the
    // sandbox is allowed to read; on a native build it is the folder itself.
    // Either way it is a real path, so nothing downstream has to know which
    // build it is running in.
    path = gtk_file_chooser_get_filename(GTK_FILE_CHOOSER(dialog));
  }

  if (method_call != nullptr) {
    if (response_id == GTK_RESPONSE_ACCEPT && path == nullptr) {
      // Accepted, but the selection has no local path (a gvfs/network
      // location). Report it rather than passing back a path `dart:io` would
      // fail on.
      respond_error(method_call, kUnsupportedLocationError,
                    "The selected location is not a local path.");
    } else {
      g_autoptr(FlValue) result =
          path != nullptr ? fl_value_new_string(path) : fl_value_new_null();
      g_autoptr(GError) error = nullptr;
      if (!fl_method_call_respond_success(method_call, result, &error)) {
        g_warning("Failed to send folder picker result: %s", error->message);
      }
    }
  }

  gtk_native_dialog_destroy(GTK_NATIVE_DIALOG(dialog));
  g_clear_object(&self->chooser);
}

static void folder_picker_method_call_cb(FlMethodChannel* channel,
                                         FlMethodCall* method_call,
                                         gpointer user_data) {
  FolderPickerChannel* self = static_cast<FolderPickerChannel*>(user_data);

  const gchar* method = fl_method_call_get_name(method_call);
  const bool save = g_strcmp0(method, kSaveFileMethod) == 0;
  if (!save && g_strcmp0(method, kPickFolderMethod) != 0) {
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
    g_autoptr(GError) error = nullptr;
    if (!fl_method_call_respond(method_call, response, &error)) {
      g_warning("Failed to respond to folder picker call: %s", error->message);
    }
    return;
  }

  if (self->pending_call != nullptr) {
    respond_error(method_call, kPickInProgressError,
                  "A file chooser is already open.");
    return;
  }

  const gchar* title = save ? kDefaultSaveTitle : kDefaultTitle;
  const gchar* initial_directory = nullptr;
  const gchar* suggested_name = nullptr;
  FlValue* args = fl_method_call_get_args(method_call);
  if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
    FlValue* value = fl_value_lookup_string(args, kTitleArgument);
    if (value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_STRING) {
      title = fl_value_get_string(value);
    }
    value = fl_value_lookup_string(args, kInitialDirectoryArgument);
    if (value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_STRING) {
      initial_directory = fl_value_get_string(value);
    }
    value = fl_value_lookup_string(args, kSuggestedNameArgument);
    if (value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_STRING) {
      suggested_name = fl_value_get_string(value);
    }
  }

  // GtkFileChooserNative, not GtkFileChooserDialog: this is the widget GTK
  // redirects to the xdg-desktop-portal FileChooser when the app is sandboxed
  // (it checks for /.flatpak-info itself), and draws in-process otherwise. For
  // a save the portal asks the host where to write, and the path it hands back
  // is one the sandbox may write to, with no filesystem permission at all.
  GtkFileChooserNative* chooser = gtk_file_chooser_native_new(
      title, self->window,
      save ? GTK_FILE_CHOOSER_ACTION_SAVE
           : GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER,
      save ? "_Save" : nullptr, nullptr);
  if (chooser == nullptr) {
    respond_error(method_call, kChooserUnavailableError,
                  "Could not create a file chooser.");
    return;
  }
  gtk_native_dialog_set_modal(GTK_NATIVE_DIALOG(chooser), TRUE);
  if (save) {
    // Choosing an existing file is asked about rather than overwritten
    // silently; the portal does the same on the host.
    gtk_file_chooser_set_do_overwrite_confirmation(GTK_FILE_CHOOSER(chooser),
                                                   TRUE);
    if (suggested_name != nullptr && suggested_name[0] != '\0') {
      gtk_file_chooser_set_current_name(GTK_FILE_CHOOSER(chooser),
                                        suggested_name);
    }
  }
  if (initial_directory != nullptr && initial_directory[0] != '\0') {
    // Only ever a starting point — the user can navigate anywhere. Under the
    // portal the host-side chooser resolves it, so a path that does not exist
    // in this sandbox is not an error, just an unused suggestion.
    gtk_file_chooser_set_current_folder(GTK_FILE_CHOOSER(chooser),
                                        initial_directory);
  }

  self->chooser = chooser;
  self->pending_call = FL_METHOD_CALL(g_object_ref(method_call));
  g_signal_connect(chooser, "response", G_CALLBACK(folder_picker_response_cb),
                   self);
  // Shown, not run: gtk_native_dialog_run() would spin a nested main loop on
  // the platform thread the engine dispatches this call on. The response
  // signal answers the call instead.
  gtk_native_dialog_show(GTK_NATIVE_DIALOG(chooser));
}

FolderPickerChannel* folder_picker_channel_new(FlView* view,
                                               GtkWindow* window) {
  FolderPickerChannel* self = g_new0(FolderPickerChannel, 1);
  self->window = window;

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlEngine* engine = fl_view_get_engine(view);
  self->channel = fl_method_channel_new(fl_engine_get_binary_messenger(engine),
                                        kChannelName, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      self->channel, folder_picker_method_call_cb, self, nullptr);
  return self;
}

void folder_picker_channel_free(FolderPickerChannel* self) {
  if (self == nullptr) {
    return;
  }
  if (self->pending_call != nullptr) {
    g_autoptr(FlMethodCall) method_call = self->pending_call;
    self->pending_call = nullptr;
    respond_error(method_call, kChooserUnavailableError,
                  "The file chooser was closed.");
  }
  if (self->chooser != nullptr) {
    gtk_native_dialog_destroy(GTK_NATIVE_DIALOG(self->chooser));
    g_clear_object(&self->chooser);
  }
  g_clear_object(&self->channel);
  g_free(self);
}
