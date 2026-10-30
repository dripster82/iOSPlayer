#include "ReelVLCThumb.h"
#include <TargetConditionals.h>
#include <stdlib.h>

#if TARGET_OS_IPHONE && __has_include(<vlc/vlc.h>)
#include <vlc/vlc.h>

typedef struct {
    libvlc_media_t *media;
    libvlc_media_thumbnail_request_t *request;
    reel_thumb_callback callback;
    void *context;
    bool done;
} reel_thumb_job;

static void on_thumbnail(const libvlc_event_t *event, void *data) {
    reel_thumb_job *job = data;
    if (job->done) return;
    job->done = true;
    libvlc_picture_t *pic = event->u.media_thumbnail_generated.p_thumbnail;
    if (pic == NULL) { job->callback(job->context, NULL, 0, 0, 0, 0); return; }
    size_t size = 0;
    const unsigned char *buf = libvlc_picture_get_buffer(pic, &size);
    job->callback(job->context, buf, libvlc_picture_get_width(pic), libvlc_picture_get_height(pic), libvlc_picture_get_stride(pic), libvlc_picture_get_time(pic));
}

void *reel_thumb_request(void *instance, const char *mrl, const char *const *options, int option_count,
                         long long time_ms, unsigned width, unsigned height, long long timeout_ms,
                         reel_thumb_callback callback, void *context) {
    if (instance == NULL || mrl == NULL || callback == NULL) return NULL;
    libvlc_media_t *media = libvlc_media_new_location(mrl);
    if (media == NULL) return NULL;
    for (int i = 0; i < option_count; i++) libvlc_media_add_option(media, options[i]);
    reel_thumb_job *job = calloc(1, sizeof *job);
    job->media = media; job->callback = callback; job->context = context;
    libvlc_event_attach(libvlc_media_event_manager(media), libvlc_MediaThumbnailGenerated, on_thumbnail, job);
    job->request = libvlc_media_thumbnail_request_by_time((libvlc_instance_t *)instance, media, (libvlc_time_t)time_ms,
                                                          libvlc_media_thumbnail_seek_precise, width, height, false,
                                                          libvlc_picture_Rgba, (libvlc_time_t)timeout_ms);
    if (job->request == NULL) {
        libvlc_event_detach(libvlc_media_event_manager(media), libvlc_MediaThumbnailGenerated, on_thumbnail, job);
        libvlc_media_release(media);
        free(job);
        return NULL;
    }
    return job;
}

void reel_thumb_finish(void *handle) {
    reel_thumb_job *job = handle;
    if (job == NULL) return;
    job->done = true;   // a late event is ignored
    libvlc_media_thumbnail_request_destroy(job->request);   // cancels if still running; waits for the callback otherwise
    libvlc_event_detach(libvlc_media_event_manager(job->media), libvlc_MediaThumbnailGenerated, on_thumbnail, job);
    libvlc_media_release(job->media);
    free(job);
}

bool reel_thumb_available(void) { return true; }

#else

void *reel_thumb_request(void *instance, const char *mrl, const char *const *options, int option_count,
                         long long time_ms, unsigned width, unsigned height, long long timeout_ms,
                         reel_thumb_callback callback, void *context) {
    (void)instance; (void)mrl; (void)options; (void)option_count; (void)time_ms; (void)width; (void)height; (void)timeout_ms; (void)callback; (void)context;
    return NULL;
}
void reel_thumb_finish(void *handle) { (void)handle; }
bool reel_thumb_available(void) { return false; }

#endif
