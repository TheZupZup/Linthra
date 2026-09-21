#include "optical_toc_channel.h"

#include <errno.h>
#include <fcntl.h>
// <linux/cdrom.h> spells CDSL_CURRENT as INT_MAX, which comes from here.
#include <limits.h>
#include <linux/cdrom.h>
#include <scsi/sg.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include <string>
#include <vector>

// The channel, method, argument, reply-key and error-code strings Dart's
// MethodChannelCdromTocSource mirrors.
// test/tooling/optical_toc_channel_contract_test.dart holds the two sides to
// the same values, so a rename on one side fails a check instead of silently
// turning every disc into "this build cannot read discs".
static constexpr const char* kChannelName =
    "io.github.thezupzup.linthra/linux_optical_toc";
static constexpr const char* kReadTocMethod = "readToc";
static constexpr const char* kDeviceArgument = "device";

static constexpr const char* kFirstTrackKey = "firstTrack";
static constexpr const char* kLastTrackKey = "lastTrack";
static constexpr const char* kLeadOutKey = "leadOutLba";
static constexpr const char* kTracksKey = "tracks";
static constexpr const char* kTrackNumberKey = "number";
static constexpr const char* kTrackLbaKey = "lba";
static constexpr const char* kTrackControlKey = "control";
static constexpr const char* kCdTextKey = "cdText";

// The drive is empty, the tray is open, or the disc has not been identified
// yet. An ordinary answer, not a fault.
static constexpr const char* kNoDiscError = "no_disc";
// The disc changed, or left, between the start and the end of the read. The
// numbers gathered describe a disc that is no longer there, so they are
// dropped rather than answered with.
static constexpr const char* kDiscChangedError = "disc_changed";
// There is a disc and its table of contents could not be read.
static constexpr const char* kUnreadableError = "unreadable";
// The device node is gone, or does not name an optical drive.
static constexpr const char* kDriveUnavailableError = "drive_unavailable";
// Opening the device was refused: a missing group membership, a udev rule.
static constexpr const char* kPermissionDeniedError = "permission_denied";
// The two halves of this build disagree about the call's shape.
static constexpr const char* kInvalidArgumentsError = "invalid_arguments";

// How long the drive gets for one SCSI CD-Text read.
static constexpr unsigned int kCdTextTimeoutMs = 10000;

// The most CD-Text a conforming disc can carry: 8 blocks of 256 packs, 18
// bytes each, after a 4-byte header. A drive claiming more is not describing
// CD-Text, so the read is bounded here rather than trusting the length field.
static constexpr int kCdTextHeaderLength = 4;
static constexpr int kCdTextMaxPacks = 2048;
static constexpr int kCdTextPackLength = 18;
static constexpr int kCdTextMaxLength =
    kCdTextHeaderLength + kCdTextMaxPacks * kCdTextPackLength;

// MMC READ TOC/PMA/ATIP, format 0101b: the CD-Text stored in the lead-in.
// Read-only, and on the kernel's default allow-list for an unprivileged
// SG_IO on a device the caller may read, so it needs no capability.
static constexpr unsigned char kReadTocPmaAtipOpcode = 0x43;
static constexpr unsigned char kCdTextFormat = 0x05;

struct _OpticalTocChannel {
  FlMethodChannel* channel;
};

namespace {

// One entry of a disc's table of contents, as the kernel reported it.
struct TocEntry {
  int number;
  int lba;
  int control;
};

// Everything one successful read produced.
struct Toc {
  int first_track;
  int last_track;
  int lead_out_lba;
  std::vector<TocEntry> tracks;
  std::vector<unsigned char> cd_text;
};

// A read that did not produce a table of contents: one of the error codes
// above, and nothing else. No errno string, no device node — a failure
// travelling up into a UI or a bug report must not carry the user's hardware
// with it.
struct ReadResult {
  bool ok;
  const char* error;
  Toc toc;
};

ReadResult Failure(const char* error) { return ReadResult{false, error, Toc{}}; }

// Whether `device` is a Linux optical-drive device node.
//
// The value comes from UDisks2 by way of Dart rather than from a person, so
// this is a guard against a bug rather than against an attacker — but what is
// on the other side of it is open() on a path, so it is worth spending. The
// name is only the first of three checks: what is opened must also be a block
// device, and must answer as a CD-ROM.
bool IsOpticalDeviceNode(const std::string& device) {
  std::string digits;
  if (device.rfind("/dev/sr", 0) == 0) {
    digits = device.substr(strlen("/dev/sr"));
  } else if (device.rfind("/dev/scd", 0) == 0) {
    digits = device.substr(strlen("/dev/scd"));
  } else {
    return false;
  }
  if (digits.empty() || digits.size() > 3) return false;
  for (char c : digits) {
    if (c < '0' || c > '9') return false;
  }
  return true;
}

// Which failure an errno from open() or an ioctl describes.
const char* ErrorForErrno(int err) {
  switch (err) {
    case EACCES:
    case EPERM:
      return kPermissionDeniedError;
    case ENOENT:
    case ENODEV:
    case ENXIO:
      return kDriveUnavailableError;
    case ENOMEDIUM:
      return kNoDiscError;
    default:
      return kUnreadableError;
  }
}

// Whether the drive says it currently holds a readable disc.
bool HasDisc(int fd) {
  const int status = ioctl(fd, CDROM_DRIVE_STATUS, CDSL_CURRENT);
  return status == CDS_DISC_OK;
}

// Reads the TOC header: the first and last track numbers on the disc.
bool ReadTocHeader(int fd, int* first, int* last) {
  struct cdrom_tochdr header;
  memset(&header, 0, sizeof(header));
  if (ioctl(fd, CDROMREADTOCHDR, &header) < 0) return false;
  *first = header.cdth_trk0;
  *last = header.cdth_trk1;
  return true;
}

// Reads one TOC entry as a logical block address. `track` is a track number,
// or CDROM_LEADOUT for where the disc's audio ends.
bool ReadTocEntry(int fd, int track, TocEntry* entry) {
  struct cdrom_tocentry tocentry;
  memset(&tocentry, 0, sizeof(tocentry));
  tocentry.cdte_track = static_cast<__u8>(track);
  tocentry.cdte_format = CDROM_LBA;
  if (ioctl(fd, CDROMREADTOCENTRY, &tocentry) < 0) return false;
  if (tocentry.cdte_format != CDROM_LBA) return false;
  entry->number = track;
  entry->lba = tocentry.cdte_addr.lba;
  entry->control = tocentry.cdte_ctrl;
  return true;
}

// Issues one READ TOC/PMA/ATIP in CD-Text format, asking for `length` bytes.
//
// Best-effort throughout: a drive with no CD-Text support, a disc with no
// CD-Text, and a kernel that declines the pass-through all end up here
// returning false, and the disc is then described without CD-Text rather than
// reported as unreadable.
bool ReadCdTextBytes(int fd, int length, std::vector<unsigned char>* out) {
  if (length < kCdTextHeaderLength || length > kCdTextMaxLength) return false;
  std::vector<unsigned char> buffer(static_cast<size_t>(length), 0);
  unsigned char command[10];
  memset(command, 0, sizeof(command));
  command[0] = kReadTocPmaAtipOpcode;
  command[2] = kCdTextFormat;
  command[7] = static_cast<unsigned char>((length >> 8) & 0xff);
  command[8] = static_cast<unsigned char>(length & 0xff);

  unsigned char sense[32];
  memset(sense, 0, sizeof(sense));

  sg_io_hdr_t io;
  memset(&io, 0, sizeof(io));
  io.interface_id = 'S';
  io.dxfer_direction = SG_DXFER_FROM_DEV;
  io.cmd_len = sizeof(command);
  io.mx_sb_len = sizeof(sense);
  io.dxfer_len = static_cast<unsigned int>(length);
  io.dxferp = buffer.data();
  io.cmdp = command;
  io.sbp = sense;
  io.timeout = kCdTextTimeoutMs;

  if (ioctl(fd, SG_IO, &io) < 0) return false;
  if (io.status != 0 || io.host_status != 0 || io.driver_status != 0) {
    return false;
  }
  *out = std::move(buffer);
  return true;
}

// Reads the disc's CD-Text, or leaves `out` empty.
//
// Two passes: the four-byte header first, to learn how much there is, then the
// data itself. Asking for the maximum straight away would make every drive
// transfer 36 KB for a disc that usually has a couple of hundred bytes of
// text, and some drives refuse an allocation length far past what they hold.
void ReadCdText(int fd, std::vector<unsigned char>* out) {
  std::vector<unsigned char> header;
  if (!ReadCdTextBytes(fd, kCdTextHeaderLength, &header)) return;
  if (header.size() < 2) return;
  const int declared = (header[0] << 8) | header[1];
  // The length field counts everything after itself.
  const int total = declared + 2;
  if (total <= kCdTextHeaderLength || total > kCdTextMaxLength) return;
  std::vector<unsigned char> data;
  if (!ReadCdTextBytes(fd, total, &data)) return;
  *out = std::move(data);
}

// Reads the whole table of contents of the disc in `device`.
//
// Runs on a worker thread: a drive that has been idle takes seconds to spin
// up, focus and read a lead-in, and the GTK main loop is where Linthra's
// window is drawn.
ReadResult ReadToc(const std::string& device) {
  if (!IsOpticalDeviceNode(device)) return Failure(kDriveUnavailableError);

  // O_NONBLOCK is not an optimisation. Opening a CD-ROM without it blocks
  // until there is a disc — and on a drive with an open tray, it can make the
  // kernel close the tray on the user's fingers.
  const int fd = open(device.c_str(), O_RDONLY | O_NONBLOCK | O_CLOEXEC);
  if (fd < 0) return Failure(ErrorForErrno(errno));

  ReadResult result = Failure(kUnreadableError);
  struct stat info;
  if (fstat(fd, &info) < 0 || !S_ISBLK(info.st_mode)) {
    result = Failure(kDriveUnavailableError);
  } else if (ioctl(fd, CDROM_GET_CAPABILITY, 0) < 0) {
    // Not a CD-ROM, whatever its name says.
    result = Failure(kDriveUnavailableError);
  } else if (!HasDisc(fd)) {
    result = Failure(kNoDiscError);
  } else {
    int first = 0;
    int last = 0;
    TocEntry lead_out;
    if (!ReadTocHeader(fd, &first, &last)) {
      result = Failure(ErrorForErrno(errno));
    } else if (first < 1 || last < first || last > 99) {
      result = Failure(kUnreadableError);
    } else {
      Toc toc;
      toc.first_track = first;
      toc.last_track = last;
      bool read_every_entry = true;
      for (int track = first; track <= last; track++) {
        TocEntry entry;
        if (!ReadTocEntry(fd, track, &entry)) {
          read_every_entry = false;
          break;
        }
        toc.tracks.push_back(entry);
      }
      if (!read_every_entry || !ReadTocEntry(fd, CDROM_LEADOUT, &lead_out)) {
        result = Failure(ErrorForErrno(errno));
      } else {
        toc.lead_out_lba = lead_out.lba;
        ReadCdText(fd, &toc.cd_text);

        // The disc can be ejected — or swapped — at any point above: it is a
        // button on the hardware. Reading the table of contents again is what
        // turns "the numbers we gathered describe a disc that has gone" into
        // an answer, instead of into a track list for a disc nobody has any
        // more.
        //
        // The header alone is not enough: two different discs can easily have
        // the same first and last track. The lead-out is where they differ —
        // two discs agreeing on their track range *and* on where the music
        // ends, to the frame, are the same disc for every purpose here.
        int first_again = 0;
        int last_again = 0;
        TocEntry lead_out_again;
        if (!HasDisc(fd) || !ReadTocHeader(fd, &first_again, &last_again) ||
            !ReadTocEntry(fd, CDROM_LEADOUT, &lead_out_again)) {
          result = Failure(kDiscChangedError);
        } else if (first_again != first || last_again != last ||
                   lead_out_again.lba != lead_out.lba) {
          result = Failure(kDiscChangedError);
        } else {
          result = ReadResult{true, nullptr, std::move(toc)};
        }
      }
    }
  }

  close(fd);
  return result;
}

// The reply Dart's MethodChannelCdromTocSource decodes.
FlValue* TocToValue(const Toc& toc) {
  g_autoptr(FlValue) tracks = fl_value_new_list();
  for (const TocEntry& entry : toc.tracks) {
    g_autoptr(FlValue) track = fl_value_new_map();
    fl_value_set_string_take(track, kTrackNumberKey,
                             fl_value_new_int(entry.number));
    fl_value_set_string_take(track, kTrackLbaKey, fl_value_new_int(entry.lba));
    fl_value_set_string_take(track, kTrackControlKey,
                             fl_value_new_int(entry.control));
    fl_value_append(tracks, track);
  }

  FlValue* result = fl_value_new_map();
  fl_value_set_string_take(result, kFirstTrackKey,
                           fl_value_new_int(toc.first_track));
  fl_value_set_string_take(result, kLastTrackKey,
                           fl_value_new_int(toc.last_track));
  fl_value_set_string_take(result, kLeadOutKey,
                           fl_value_new_int(toc.lead_out_lba));
  fl_value_set_string_take(result, kTracksKey,
                           fl_value_ref(tracks));
  if (!toc.cd_text.empty()) {
    fl_value_set_string_take(
        result, kCdTextKey,
        fl_value_new_uint8_list(toc.cd_text.data(), toc.cd_text.size()));
  }
  return result;
}

void RespondError(FlMethodCall* method_call, const char* code,
                  const char* message) {
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_error_response_new(code, message, nullptr));
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("Failed to send optical TOC error: %s", error->message);
  }
}

// Runs on a worker thread. Holds the method call alive until the main loop has
// answered it.
void ReadTocInThread(GTask* task, gpointer, gpointer task_data,
                     GCancellable*) {
  const std::string* device = static_cast<const std::string*>(task_data);
  ReadResult* result = new ReadResult(ReadToc(*device));
  g_task_return_pointer(task, result, [](gpointer data) {
    delete static_cast<ReadResult*>(data);
  });
}

// Runs back on the main loop, where a method channel may be answered.
void ReadTocFinished(GObject*, GAsyncResult* async_result,
                     gpointer user_data) {
  g_autoptr(FlMethodCall) method_call = FL_METHOD_CALL(user_data);
  ReadResult* result = static_cast<ReadResult*>(
      g_task_propagate_pointer(G_TASK(async_result), nullptr));
  if (result == nullptr) {
    RespondError(method_call, kUnreadableError,
                 "The table of contents could not be read.");
    return;
  }

  if (!result->ok) {
    RespondError(method_call, result->error,
                 "The table of contents could not be read.");
  } else {
    g_autoptr(FlValue) value = TocToValue(result->toc);
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_success_response_new(value));
    g_autoptr(GError) error = nullptr;
    if (!fl_method_call_respond(method_call, response, &error)) {
      g_warning("Failed to send optical TOC result: %s", error->message);
    }
  }
  delete result;
}

void HandleReadToc(FlMethodCall* method_call) {
  FlValue* args = fl_method_call_get_args(method_call);
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    RespondError(method_call, kInvalidArgumentsError,
                 "readToc expects a map argument.");
    return;
  }
  FlValue* device_value = fl_value_lookup_string(args, kDeviceArgument);
  if (device_value == nullptr ||
      fl_value_get_type(device_value) != FL_VALUE_TYPE_STRING) {
    RespondError(method_call, kInvalidArgumentsError,
                 "readToc expects a string device.");
    return;
  }

  std::string* device = new std::string(fl_value_get_string(device_value));
  GTask* task = g_task_new(nullptr, nullptr, ReadTocFinished,
                           g_object_ref(method_call));
  g_task_set_task_data(task, device, [](gpointer data) {
    delete static_cast<std::string*>(data);
  });
  g_task_run_in_thread(task, ReadTocInThread);
  g_object_unref(task);
}

void MethodCallCb(FlMethodChannel*, FlMethodCall* method_call, gpointer) {
  if (strcmp(fl_method_call_get_name(method_call), kReadTocMethod) == 0) {
    HandleReadToc(method_call);
    return;
  }
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("Failed to send optical TOC response: %s", error->message);
  }
}

}  // namespace

OpticalTocChannel* optical_toc_channel_new(FlView* view) {
  OpticalTocChannel* self = g_new0(OpticalTocChannel, 1);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)), kChannelName,
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->channel, MethodCallCb, self,
                                            nullptr);
  return self;
}

void optical_toc_channel_free(OpticalTocChannel* self) {
  if (self == nullptr) return;
  g_clear_object(&self->channel);
  g_free(self);
}
