/* The reference backend is deliberately separate from the future Nim decoder. */
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <ogg/ogg.h>
#include <vorbis/codec.h>
#include <theora/theoradec.h>
#include "reference.h"

typedef struct {
  ogg_stream_state ogg;
  int kind, headers, eos, ready;
  uint32_t sequence;
  vorbis_info audio_info;
  vorbis_comment audio_comment;
  vorbis_dsp_state audio;
  vorbis_block block;
  th_info video_info;
  th_comment video_comment;
  th_setup_info *setup;
  th_dec_ctx *video;
  int64_t samples, frames;
} reference_stream;

struct ogg_reference {
  const unsigned char *data;
  size_t length, position;
  ogg_sync_state sync;
  reference_stream streams[2];
  int count, active, body, ended;
  const char *error;
  ogg_reference_info info;
};

/* Keep the first error so repeated reads cannot hide a malformed stream. */
static int fail(ogg_reference *d, const char *message) {
  if (!d->error) d->error = message;
  return -1;
}

/* Feed bounded chunks to exercise libogg's incremental page handling. */
static int next_page(ogg_reference *d, ogg_page *page) {
  for (;;) {
    int status = ogg_sync_pageout(&d->sync, page);
    if (status > 0) return 1;
    if (status < 0) return fail(d, "Invalid Ogg capture pattern or checksum.");
    if (d->position == d->length) {
      if (d->sync.fill != d->sync.returned)
        return fail(d, "Truncated Ogg page.");
      return 0;
    }
    size_t count = d->length - d->position;
    if (count > 4096) count = 4096;
    char *buffer = ogg_sync_buffer(&d->sync, (long)count);
    if (!buffer) return fail(d, "Cannot allocate the Ogg input buffer.");
    memcpy(buffer, d->data + d->position, count);
    if (ogg_sync_wrote(&d->sync, (long)count) != 0)
      return fail(d, "Cannot supply Ogg input.");
    d->position += count;
  }
}

/* Preserve packet order within each page without accumulating decoded frames. */
static int next_packet(ogg_reference *d, ogg_packet *packet) {
  for (;;) {
    if (d->active >= 0) {
      int status = ogg_stream_packetout(&d->streams[d->active].ogg, packet);
      if (status > 0) return 1;
      if (status < 0) return fail(d, "Missing or discontinuous Ogg packet.");
      d->active = -1;
    }
    ogg_page page;
    int status = next_page(d, &page);
    if (status < 0) return -1;
    if (!status) {
      for (int i = 0; i < d->count; ++i) {
        if (!d->streams[i].eos)
          return fail(d, "Missing Ogg end-of-stream page.");
      }
      d->ended = 1;
      return 0;
    }
    int serial = ogg_page_serialno(&page);
    int index = -1;
    for (int i = 0; i < d->count; ++i)
      if (d->streams[i].ogg.serialno == serial) index = i;
    if (ogg_page_bos(&page)) {
      if (d->body || index >= 0)
        return fail(d, "Chained or repeated Ogg streams are not supported yet.");
      if (d->count == 2)
        return fail(d, "Only one Vorbis and one Theora stream are supported.");
      index = d->count++;
      reference_stream *s = &d->streams[index];
      if (ogg_stream_init(&s->ogg, serial) != 0)
        return fail(d, "Cannot initialize the Ogg stream.");
      vorbis_info_init(&s->audio_info);
      vorbis_comment_init(&s->audio_comment);
      th_info_init(&s->video_info);
      th_comment_init(&s->video_comment);
    } else {
      d->body = 1;
      if (index < 0) return fail(d, "Ogg page has an unknown stream serial.");
    }
    reference_stream *s = &d->streams[index];
    if (s->eos) return fail(d, "Ogg page follows the end of its stream.");
    if ((uint32_t)ogg_page_pageno(&page) != s->sequence++)
      return fail(d, "Ogg page sequence is discontinuous.");
    s->eos = ogg_page_eos(&page) != 0;
    if (ogg_stream_pagein(&s->ogg, &page) != 0)
      return fail(d, "Invalid Ogg page.");
    d->active = index;
  }
}

/* Identify the codec and consume its three mandatory headers. */
static int read_header(ogg_reference *d, ogg_packet *packet) {
  reference_stream *s = &d->streams[d->active];
  if (!s->kind) {
    if (vorbis_synthesis_idheader(packet)) s->kind = 1;
    else if (packet->bytes >= 7 && packet->packet[0] == 0x80 &&
             memcmp(packet->packet + 1, "theora", 6) == 0) s->kind = 2;
    else return fail(d, "Unsupported Ogg codec. Expected Vorbis or Theora.");
    for (int i = 0; i < d->count; ++i)
      if (i != d->active && d->streams[i].kind == s->kind)
        return fail(d, "Duplicate audio or video streams are not supported yet.");
  }
  if (s->headers == 3)
    return fail(d, "Media packet precedes another stream's headers.");
  if (s->kind == 1) {
    if (vorbis_synthesis_headerin(&s->audio_info, &s->audio_comment, packet))
      return fail(d, "Invalid Vorbis header.");
  } else {
    if (th_decode_headerin(&s->video_info, &s->video_comment,
                          &s->setup, packet) <= 0)
      return fail(d, "Invalid Theora header.");
  }
  if (++s->headers != 3) return 0;
  if (s->kind == 1) {
    if (s->audio_info.channels < 1 || s->audio_info.channels > 8 ||
        s->audio_info.rate < 1 || s->audio_info.rate > 384000)
      return fail(d, "Vorbis channel count or sample rate exceeds supported limits.");
    if (vorbis_synthesis_init(&s->audio, &s->audio_info))
      return fail(d, "Cannot initialize the Vorbis decoder.");
    s->ready = 1;
    if (vorbis_block_init(&s->audio, &s->block))
      return fail(d, "Cannot initialize the Vorbis block.");
    d->info.channels = s->audio_info.channels;
    d->info.sample_rate = (int)s->audio_info.rate;
  } else {
    th_info *info = &s->video_info;
    if (!info->fps_numerator || !info->fps_denominator ||
        !info->pic_width || !info->pic_height ||
        info->frame_width > 4096 || info->frame_height > 4096)
      return fail(d, "Invalid Theora dimensions or frame rate (maximum 4096x4096).");
    s->video = th_decode_alloc(info, s->setup);
    th_setup_free(s->setup);
    s->setup = NULL;
    if (!s->video) return fail(d, "Cannot initialize the Theora decoder.");
    /* Disable postprocessing so the planes form a reproducible decode oracle. */
    int postprocessing = 0;
    th_decode_ctl(s->video, TH_DECCTL_SET_PPLEVEL,
                  &postprocessing, sizeof(postprocessing));
    d->info.width = info->pic_width;
    d->info.height = info->pic_height;
    d->info.offset_x = info->pic_x;
    d->info.offset_y = info->pic_y;
    d->info.pixel_format = info->pixel_fmt;
    d->info.fps_numerator = info->fps_numerator;
    d->info.fps_denominator = info->fps_denominator;
  }
  return 0;
}

/* The caller retains the compressed bytes until close. */
ogg_reference *ogg_reference_open(const unsigned char *data, size_t length) {
  ogg_reference *d = calloc(1, sizeof(*d));
  if (!d) return NULL;
  d->data = data;
  d->length = length;
  d->active = -1;
  ogg_sync_init(&d->sync);
  for (;;) {
    ogg_packet packet;
    int status = next_packet(d, &packet);
    if (status <= 0) {
      fail(d, "Missing Ogg codec headers.");
      return d;
    }
    if (read_header(d, &packet) < 0) return d;
    int ready = d->body;
    for (int i = 0; i < d->count; ++i)
      ready = ready && d->streams[i].headers == 3;
    if (ready) return d;
  }
}

/* Return borrowed native buffers, valid until the next read or close. */
int ogg_reference_read(ogg_reference *d, ogg_reference_frame *frame) {
  if (d->error) return -1;
  if (d->ended) return 0;
  for (;;) {
    ogg_packet packet;
    int status = next_packet(d, &packet);
    if (status <= 0) return status;
    reference_stream *s = &d->streams[d->active];
    memset(frame, 0, sizeof(*frame));
    frame->kind = s->kind;
    if (s->kind == 1) {
      if (vorbis_synthesis(&s->block, &packet) != 0 ||
          vorbis_synthesis_blockin(&s->audio, &s->block) != 0)
        return fail(d, "Invalid Vorbis audio packet.");
      int count = vorbis_synthesis_pcmout(&s->audio, &frame->pcm);
      if (count < 0) return fail(d, "Cannot read Vorbis samples.");
      if (!count) continue;
      frame->samples = count;
      frame->time = (double)s->samples / s->audio_info.rate;
      s->samples += count;
      vorbis_synthesis_read(&s->audio, count);
      return 1;
    }
    ogg_int64_t granule;
    status = th_decode_packetin(s->video, &packet, &granule);
    if (status < 0) return fail(d, "Invalid Theora video packet.");
    th_ycbcr_buffer planes;
    if (th_decode_ycbcr_out(s->video, planes) != 0)
      return fail(d, "Cannot read Theora planes.");
    /* Sequential playback starts at zero; seeking and spliced clips come later. */
    frame->time = (double)s->frames++ * s->video_info.fps_denominator /
                  s->video_info.fps_numerator;
    for (int i = 0; i < 3; ++i) {
      frame->planes[i] = planes[i].data;
      frame->widths[i] = planes[i].width;
      frame->heights[i] = planes[i].height;
      frame->strides[i] = planes[i].stride;
    }
    return 1;
  }
}

/* Report errors without exposing upstream structure layouts to Nim. */
const char *ogg_reference_error(ogg_reference *d) {
  return d ? d->error : "Cannot allocate the Ogg decoder.";
}

/* Copy metadata after all stream headers have been consumed. */
ogg_reference_info ogg_reference_get_info(ogg_reference *d) {
  return d->info;
}

/* Release partially initialized contexts as well as complete decoders. */
void ogg_reference_close(ogg_reference *d) {
  if (!d) return;
  for (int i = 0; i < d->count; ++i) {
    reference_stream *s = &d->streams[i];
    if (s->ready) {
      vorbis_block_clear(&s->block);
      vorbis_dsp_clear(&s->audio);
    }
    if (s->video) th_decode_free(s->video);
    if (s->setup) th_setup_free(s->setup);
    vorbis_comment_clear(&s->audio_comment);
    vorbis_info_clear(&s->audio_info);
    th_comment_clear(&s->video_comment);
    th_info_clear(&s->video_info);
    ogg_stream_clear(&s->ogg);
  }
  ogg_sync_clear(&d->sync);
  free(d);
}
