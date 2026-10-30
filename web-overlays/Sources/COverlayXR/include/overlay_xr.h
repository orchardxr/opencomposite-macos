// Overlay compositor of the web helper (the vrcompositor scene-graph role): an XR_EXTX_overlay session on the
// OpenXR runtime that shows rectangles of one page texture as quad layers in STAGE space.
#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ovxr ovxr;

typedef void (*ovxr_log_fn)(const char *line);

typedef struct ovxr_quad
{
	float position[3];
	float orientation[4]; // x y z w
	float width, height;  // metres
	int32_t rect[4];      // x y w h in page pixels
	float color_scale[4]; // premultiplied: rgb * opacity, opacity
} ovxr_quad;

typedef struct ovxr_stats
{
	uint64_t frames;          // xrEndFrame calls
	uint64_t images;          // swapchain images produced
	uint64_t uploads;         // ovxr_upload calls
	uint64_t upload_pixels;   // pixels converted and staged
	double upload_cpu_ms;     // CPU time in ovxr_upload (conversion)
	double copy_gpu_wait_ms;  // CPU time waiting for the staging->swapchain blit
	int session_running;
	int color_scale_bias;
} ovxr_stats;

// Starts the XR thread. The runtime is the active OpenXR runtime, found by the OpenXR loader (XR_RUNTIME_JSON, else
// the active runtime manifest). The session is created when quads are set and ended after `linger_ms` without quads.
// Never blocks on the runtime.
ovxr *ovxr_create(uint32_t page_width, uint32_t page_height, uint32_t linger_ms, ovxr_log_fn log);

// Copies a rect of page pixels (BGRA8, premultiplied, sRGB-encoded, as a WebKit snapshot) into the page texture.
// Converts to premultiplied-in-linear sRGB (the swapchain is sRGB), so edges blend like the browser's
// own premultiplied result over black. Safe from any thread.
void ovxr_upload(ovxr *m, int32_t x, int32_t y, int32_t w, int32_t h, const void *bgra, size_t stride);

// Replaces the layer list (drawn in order, last on top). n = 0 hides everything.
void ovxr_set_quads(ovxr *m, const ovxr_quad *quads, uint32_t n);

void ovxr_get_stats(ovxr *m, ovxr_stats *out);

void ovxr_destroy(ovxr *m);

#ifdef __cplusplus
}
#endif
