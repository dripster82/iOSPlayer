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
