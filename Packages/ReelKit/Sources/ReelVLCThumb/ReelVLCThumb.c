#include "ReelVLCThumb.h"
#include <TargetConditionals.h>
#include <stdlib.h>
#include <stdio.h>

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

#if TARGET_OS_IPHONE && __has_include(<vlc/vlc.h>)

typedef struct {
    libvlc_media_t *media;
    libvlc_media_player_t *player;
    unsigned char *buffer;
    unsigned width, height;
    reel_grab_frame_cb callback;
    void *context;
    bool closed;
} reel_grab_session;

static void *grab_lock(void *opaque, void **planes) {
    reel_grab_session *s = opaque;
    planes[0] = s->buffer;
    return s->buffer;
}
static void grab_unlock(void *opaque, void *picture, void *const *planes) { (void)opaque; (void)picture; (void)planes; }
static void grab_display(void *opaque, void *picture) {
    reel_grab_session *s = opaque;
    (void)picture;
    if (s->closed) return;
    s->callback(s->context, s->buffer, s->width, s->height, s->width * 4, libvlc_media_player_get_time(s->player));
}

void *reel_grab_open(void *instance, const char *mrl, const char *const *options, int option_count,
                     unsigned width, unsigned height, reel_grab_frame_cb callback, void *context) {
    if (instance == NULL || mrl == NULL || callback == NULL || width == 0 || height == 0) return NULL;
    libvlc_media_t *media = libvlc_media_new_location(mrl);
    if (media == NULL) return NULL;
    for (int i = 0; i < option_count; i++) libvlc_media_add_option(media, options[i]);
    libvlc_media_player_t *player = libvlc_media_player_new_from_media((libvlc_instance_t *)instance, media);
    if (player == NULL) { libvlc_media_release(media); return NULL; }
    reel_grab_session *s = calloc(1, sizeof *s);
    s->media = media; s->player = player; s->width = width; s->height = height;
    s->buffer = calloc((size_t)width * height * 4, 1);
    s->callback = callback; s->context = context;
    libvlc_video_set_callbacks(player, grab_lock, grab_unlock, grab_display, s);
    libvlc_video_set_format(player, "RGBA", width, height, width * 4);
    return s;
}

int reel_grab_play(void *session, long long from_ms, float rate) {
    reel_grab_session *s = session;
    if (s == NULL) return -1;
    char opt[64];
    snprintf(opt, sizeof opt, ":start-time=%.3f", (double)from_ms / 1000.0);
    libvlc_media_add_option(s->media, opt);
    int r = libvlc_media_player_play(s->player);
    if (r == 0 && rate > 0 && rate != 1) libvlc_media_player_set_rate(s->player, rate);
    return r;
}

int reel_grab_seek(void *session, long long time_ms) {
    reel_grab_session *s = session;
    if (s == NULL) return -1;
    return libvlc_media_player_set_time(s->player, (libvlc_time_t)time_ms, false);
}

void reel_grab_set_rate(void *session, float rate) {
    reel_grab_session *s = session;
    if (s) libvlc_media_player_set_rate(s->player, rate);
}

void reel_grab_close(void *session) {
    reel_grab_session *s = session;
    if (s == NULL) return;
    s->closed = true;
    libvlc_media_player_stop_async(s->player);
    libvlc_media_player_release(s->player);   // waits for the stop, and so for the last display callback
    libvlc_media_release(s->media);
    free(s->buffer);
    free(s);
}

#else

void *reel_grab_open(void *instance, const char *mrl, const char *const *options, int option_count,
                     unsigned width, unsigned height, reel_grab_frame_cb callback, void *context) {
    (void)instance; (void)mrl; (void)options; (void)option_count; (void)width; (void)height; (void)callback; (void)context;
    return NULL;
}
int reel_grab_play(void *session, long long from_ms, float rate) { (void)session; (void)from_ms; (void)rate; return -1; }
int reel_grab_seek(void *session, long long time_ms) { (void)session; (void)time_ms; return -1; }
void reel_grab_set_rate(void *session, float rate) { (void)session; (void)rate; }
void reel_grab_close(void *session) { (void)session; }

#endif
