// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef HYABRID_CORE_H
#define HYABRID_CORE_H
#include <stdint.h>
#include <stddef.h>
typedef struct hc_context hc_context;
typedef struct { float denoise, dehaze, contrast, saturation, temperature, sharpen; } hc_adjustments;
typedef struct { int32_t dx, dy; float correlation; uint32_t accepted; } hc_alignment;
hc_context *hc_create(void);
void hc_destroy(hc_context *ctx);
int32_t hc_reset(hc_context *ctx);
typedef struct hc_cancel_flag hc_cancel_flag;
const hc_cancel_flag *hc_cancel_token(const hc_context *ctx);
void hc_cancel(const hc_cancel_flag *token);
int32_t hc_add_rgba(hc_context *ctx,uint32_t width,uint32_t height,const uint8_t *data,size_t len);
int32_t hc_set_exposure(hc_context *ctx,float exposure);
int32_t hc_run(hc_context *ctx,uint32_t mode,int32_t radius,const hc_adjustments *settings);
int32_t hc_copy_output(const hc_context *ctx,uint8_t *out,size_t capacity);
int32_t hc_copy_report(const hc_context *ctx,hc_alignment *out,size_t capacity);
// Status: 0 OK, 1 dimensions, 2 parameters, 3 memory, 4 cancelled, 5 no output, 6 panic.
// At most 7 frames, each at most 13M pixels. Same dimensions in one context.
// All methods serial, EXCEPT hc_cancel, which may run concurrently.
// Buffers use straight-alpha RGBA8 sRGB, contiguous width*height*4 bytes.
#endif
