#ifndef REEL_VLC_THUMB_H
#define REEL_VLC_THUMB_H

#include <stdbool.h>

/// One frame at an exact time, through libvlc's thumbnailer with a precise seek: VLCKit's own
/// VLCMediaThumbnailer seeks fast, which hands back the keyframe before the time asked for, up
/// to a dozen seconds early on an AVI. Reel's intro and credits fingerprints need the frame itself.
///
/// `pixels` is RGBA, `stride` bytes per row, valid only for the duration of the callback, or NULL
/// when the frame could not be made. `time_ms` is the frame's own time.
typedef void (*reel_thumb_callback)(void *context, const unsigned char *pixels, unsigned width, unsigned height, unsigned stride, long long time_ms);

/// Starts a request; `options` are libvlc media options (":no-audio" and the like). Returns an
/// opaque handle to pass to reel_thumb_finish once the callback has run (or to cancel), or NULL
/// when libvlc is not available on this platform.
void *reel_thumb_request(void *libvlc_instance, const char *mrl, const char *const *options, int option_count,
                         long long time_ms, unsigned width, unsigned height, long long timeout_ms,
                         reel_thumb_callback callback, void *context);

/// Releases the request and its media. Safe after the callback, and before it (cancels).
void reel_thumb_finish(void *handle);

/// Whether precise thumbnails are available (true on iOS builds that carry libvlc).
bool reel_thumb_available(void);

#endif

/// A grab session: the file opened once, frames delivered as they are decoded. For a run of
/// frames (the intro's prints) the session plays from a time at several times normal speed with
/// the audio off; for single frames (the search) it seeks precisely and the next frame arrives.
/// Frames come on libvlc's thread, RGBA at the size asked for, with the player's time.
typedef void (*reel_grab_frame_cb)(void *context, const unsigned char *pixels, unsigned width, unsigned height, unsigned stride, long long time_ms);

void *reel_grab_open(void *libvlc_instance, const char *mrl, const char *const *options, int option_count,
                     unsigned width, unsigned height, reel_grab_frame_cb callback, void *context);
/// Starts playing from `from_ms` at `rate` (1 is normal). Returns 0 on success.
int reel_grab_play(void *session, long long from_ms, float rate);
/// A seek while playing: `fast` lands on the keyframe before the time (the decoder then plays
/// cleanly from there), precise asks for the exact time. Returns 0 on success.
int reel_grab_seek(void *session, long long time_ms, bool fast);
void reel_grab_set_rate(void *session, float rate);
/// Stops and releases the session. Blocks until libvlc has let go; call off the main thread.
void reel_grab_close(void *session);
/// Where the grab's libvlc writes its messages (warnings and up), or NULL for none.
void reel_grab_set_log_path(const char *path);
