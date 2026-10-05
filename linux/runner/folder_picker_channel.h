#ifndef RUNNER_FOLDER_PICKER_CHANNEL_H_
#define RUNNER_FOLDER_PICKER_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

G_BEGIN_DECLS

// The native half of Linthra's Linux folder chooser (issue #438).
//
// Dart's `MethodChannelLinuxFolderPicker` asks this channel for a music folder
// and gets back a filesystem path the `dart:io` scanner can walk, or null when
// the user cancelled. `MethodChannelLinuxFileSaver` asks it where to save a
// file (#748), a bug report or a diagnostics snapshot, and gets back a path to
// write, or null for a cancel. One chooser is open at a time, for either.
//
// Why the runner and not a plugin: `file_picker` on Linux shells out to
// `zenity`/`qarma`/`kdialog`, none of which exist inside the Flatpak sandbox,
// so folder selection there fails before a dialog ever appears. GTK's
// `GtkFileChooserNative` is the supported path for both builds at once — it
// opens the normal GTK dialog on a native build, and inside a sandbox GTK
// routes it to the xdg-desktop-portal FileChooser, which runs the picker on
// the host and hands back a document-portal path the sandbox may read (or, for
// a save, write). That needs no filesystem finish-arg: the user's explicit
// choice is the grant.
typedef struct _FolderPickerChannel FolderPickerChannel;

// Registers the folder-picker channel on `view`'s engine, parenting the
// chooser on `window` so it opens modal to the app (and, under the portal, is
// correctly associated with Linthra's window). Never returns NULL.
FolderPickerChannel* folder_picker_channel_new(FlView* view, GtkWindow* window);

// Tears the channel down, answering an in-flight pick (if any) so the Dart
// side never waits forever on a chooser that is going away.
void folder_picker_channel_free(FolderPickerChannel* self);

G_END_DECLS

#endif  // RUNNER_FOLDER_PICKER_CHANNEL_H_
