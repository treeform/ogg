#ifndef NIM_OGG_REFERENCE_H
#define NIM_OGG_REFERENCE_H
#include <stddef.h>

typedef struct ogg_reference ogg_reference;
typedef struct {
  int channels, sample_rate;
  int width, height, offset_x, offset_y, pixel_format;
  unsigned int fps_numerator, fps_denominator;
} ogg_reference_info;
typedef struct {
  int kind, samples;
  double time;
  float **pcm;
  unsigned char *planes[3];
  int widths[3], heights[3], strides[3];
} ogg_reference_frame;

ogg_reference *ogg_reference_open(const unsigned char *data, size_t length);
const char *ogg_reference_error(ogg_reference *decoder);
ogg_reference_info ogg_reference_get_info(ogg_reference *decoder);
int ogg_reference_read(ogg_reference *decoder, ogg_reference_frame *frame);
void ogg_reference_close(ogg_reference *decoder);
#endif
