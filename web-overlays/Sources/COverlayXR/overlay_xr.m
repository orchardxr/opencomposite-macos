#define XR_USE_GRAPHICS_API_METAL
#import <Metal/Metal.h>
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>

#include "overlay_xr.h"

#include <math.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define MAX_QUADS 32
#define MAX_IMAGES 8

struct ovxr
{
	uint32_t pw, ph;
	uint32_t linger_ms;
	ovxr_log_fn logfn;

	pthread_t thread;
	pthread_mutex_t lock;
	pthread_cond_t cond;
	bool quit;

	// shared, under lock
	uint8_t *page;      // pw*ph*4, swapchain byte order, linear-premultiplied sRGB
	bool bgr;           // page byte order is BGRA (else RGBA)
	bool dirty;
	ovxr_quad quads[MAX_QUADS];
	uint32_t nquads;
	double last_quads_s;
	ovxr_stats stats;

	// XR thread only
	PFN_xrGetInstanceProcAddr gipa;
	XrInstance instance;
	XrSystemId system;
	XrSession session;
	XrSessionState state;
	bool running;
	bool exit_requested;
	bool has_color_scale;
	XrSpace space;
	XrSwapchain swapchain;
	int64_t sc_format;
	uint32_t nimages;
	id<MTLTexture> images[MAX_IMAGES];
	bool have_image;
	double next_try_s;

	id<MTLDevice> device;
	id<MTLCommandQueue> queue;
	id<MTLBuffer> staging;
	uint8_t *staging_ptr;
};

static uint8_t lut[256 * 256];
static pthread_once_t lut_once = PTHREAD_ONCE_INIT;

static void
lut_init(void)
{
	for (int a = 0; a < 256; a++) {
		for (int c = 0; c < 256; c++) {
			if (a == 0) {
				lut[c] = 0;
				continue;
			}
			double s = c > a ? 1.0 : (double)c / a;
			double l = s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4);
			l *= a / 255.0;
			double e = l <= 0.0031308 ? l * 12.92 : 1.055 * pow(l, 1 / 2.4) - 0.055;
			int v = (int)lround(e * 255);
			lut[a * 256 + c] = (uint8_t)(v < 0 ? 0 : v > 255 ? 255 : v);
		}
	}
}

static double
now_s(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void
logf_(ovxr *m, const char *fmt, ...)
{
	char buf[1024];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	if (m->logfn)
		m->logfn(buf);
	else
		fprintf(stderr, "overlay-xr: %s\n", buf);
}

#define XRF(name) PFN_##name name = NULL; m->gipa(m->instance, #name, (PFN_xrVoidFunction *)&name)

static XrResult
xr_check(ovxr *m, XrResult r, const char *what)
{
	if (XR_FAILED(r))
		logf_(m, "%s failed: %d", what, r);
	return r;
}

static void
destroy_metal(ovxr *m)
{
	[m->staging release];
	[m->queue release];
	[m->device release];
	m->staging = nil;
	m->staging_ptr = NULL;
	m->queue = nil;
	m->device = nil;
}

static void
destroy_session(ovxr *m)
{
	if (m->swapchain) {
		XRF(xrDestroySwapchain);
		xrDestroySwapchain(m->swapchain);
	}
	if (m->space) {
		XRF(xrDestroySpace);
		xrDestroySpace(m->space);
	}
	if (m->session) {
		XRF(xrDestroySession);
		xrDestroySession(m->session);
	}
	m->swapchain = XR_NULL_HANDLE;
	m->space = XR_NULL_HANDLE;
	m->session = XR_NULL_HANDLE;
	m->running = false;
	m->exit_requested = false;
	m->have_image = false;
	m->nimages = 0;
	m->state = XR_SESSION_STATE_UNKNOWN;
}

static void
destroy_all(ovxr *m)
{
	destroy_session(m);
	destroy_metal(m);
	if (m->instance) {
		XRF(xrDestroyInstance);
		xrDestroyInstance(m->instance);
		logf_(m, "instance destroyed");
	}
	m->instance = XR_NULL_HANDLE;
	pthread_mutex_lock(&m->lock);
	m->stats.session_running = 0;
	pthread_mutex_unlock(&m->lock);
}

static bool
create_instance(ovxr *m)
{
	m->instance = XR_NULL_HANDLE;
	XRF(xrEnumerateInstanceExtensionProperties);
	XRF(xrCreateInstance);
	if (!xrEnumerateInstanceExtensionProperties || !xrCreateInstance)
		return false;
	uint32_t n = 0;
	if (XR_FAILED(xrEnumerateInstanceExtensionProperties(NULL, 0, &n, NULL)))
		return false;
	XrExtensionProperties *props = calloc(n, sizeof(*props));
	for (uint32_t i = 0; i < n; i++)
		props[i].type = XR_TYPE_EXTENSION_PROPERTIES;
	xrEnumerateInstanceExtensionProperties(NULL, n, &n, props);
	bool overlay = false, metal = false;
	m->has_color_scale = false;
	for (uint32_t i = 0; i < n; i++) {
		overlay |= strcmp(props[i].extensionName, XR_EXTX_OVERLAY_EXTENSION_NAME) == 0;
		metal |= strcmp(props[i].extensionName, XR_KHR_METAL_ENABLE_EXTENSION_NAME) == 0;
		m->has_color_scale |= strcmp(props[i].extensionName, XR_KHR_COMPOSITION_LAYER_COLOR_SCALE_BIAS_EXTENSION_NAME) == 0;
	}
	free(props);
	if (!overlay || !metal) {
		logf_(m, "runtime lacks %s", !overlay ? "XR_EXTX_overlay" : "XR_KHR_metal_enable");
		return false;
	}
	const char *exts[3] = {XR_KHR_METAL_ENABLE_EXTENSION_NAME, XR_EXTX_OVERLAY_EXTENSION_NAME,
	                       XR_KHR_COMPOSITION_LAYER_COLOR_SCALE_BIAS_EXTENSION_NAME};
	XrInstanceCreateInfo ici = {
	    .type = XR_TYPE_INSTANCE_CREATE_INFO,
	    .applicationInfo = {.applicationName = "OpenComposite web overlays", .apiVersion = XR_API_VERSION_1_0},
	    .enabledExtensionCount = m->has_color_scale ? 3 : 2,
	    .enabledExtensionNames = exts,
	};
	strcpy(ici.applicationInfo.engineName, "oc-webhelper");
	XrResult r = xrCreateInstance(&ici, &m->instance);
	if (XR_FAILED(r)) {
		m->instance = XR_NULL_HANDLE;
		return false;
	}
	XRF(xrGetSystem);
	XrSystemGetInfo sgi = {.type = XR_TYPE_SYSTEM_GET_INFO, .formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY};
	if (XR_FAILED(xr_check(m, xrGetSystem(m->instance, &sgi, &m->system), "xrGetSystem"))) {
		destroy_all(m);
		return false;
	}
	logf_(m, "instance created (color_scale_bias %d)", m->has_color_scale);
	return true;
}

static bool
create_metal(ovxr *m)
{
	XRF(xrGetMetalGraphicsRequirementsKHR);
	if (!xrGetMetalGraphicsRequirementsKHR)
		return false;
	XrGraphicsRequirementsMetalKHR req = {.type = XR_TYPE_GRAPHICS_REQUIREMENTS_METAL_KHR};
	if (XR_FAILED(xr_check(m, xrGetMetalGraphicsRequirementsKHR(m->instance, m->system, &req), "graphics requirements")))
		return false;
	m->device = [(id<MTLDevice>)req.metalDevice retain];
	if (!m->device) {
		logf_(m, "runtime gave no Metal device");
		return false;
	}
	m->queue = [m->device newCommandQueue];
	m->staging = [m->device newBufferWithLength:(NSUInteger)m->pw * m->ph * 4 options:MTLResourceStorageModeShared];
	if (!m->queue || !m->staging)
		return false;
	m->staging_ptr = m->staging.contents;
	return true;
}

static bool
create_session(ovxr *m)
{
	if (!m->device && !create_metal(m))
		return false;
	XRF(xrCreateSession);
	XRF(xrCreateReferenceSpace);
	XRF(xrEnumerateSwapchainFormats);
	XRF(xrCreateSwapchain);
	XRF(xrEnumerateSwapchainImages);

	XrGraphicsBindingMetalKHR binding = {.type = XR_TYPE_GRAPHICS_BINDING_METAL_KHR, .commandQueue = m->queue};
	XrSessionCreateInfoOverlayEXTX ov = {
	    .type = XR_TYPE_SESSION_CREATE_INFO_OVERLAY_EXTX,
	    .next = &binding,
	    .sessionLayersPlacement = 1,
	};
	XrSessionCreateInfo sci = {.type = XR_TYPE_SESSION_CREATE_INFO, .next = &ov, .systemId = m->system};
	if (XR_FAILED(xr_check(m, xrCreateSession(m->instance, &sci, &m->session), "xrCreateSession"))) {
		m->session = XR_NULL_HANDLE;
		return false;
	}
	XrReferenceSpaceCreateInfo rsci = {
	    .type = XR_TYPE_REFERENCE_SPACE_CREATE_INFO,
	    .referenceSpaceType = XR_REFERENCE_SPACE_TYPE_STAGE,
	    .poseInReferenceSpace = {.orientation = {.w = 1}},
	};
	if (XR_FAILED(xr_check(m, xrCreateReferenceSpace(m->session, &rsci, &m->space), "STAGE space")))
		return false;

	int64_t formats[64];
	uint32_t nf = 0;
	xrEnumerateSwapchainFormats(m->session, 64, &nf, formats);
	m->sc_format = 0;
	for (uint32_t i = 0; i < nf && !m->sc_format; i++)
		if (formats[i] == MTLPixelFormatRGBA8Unorm_sRGB || formats[i] == MTLPixelFormatBGRA8Unorm_sRGB)
			m->sc_format = formats[i];
	if (!m->sc_format) {
		logf_(m, "no sRGB swapchain format");
		return false;
	}
	XrSwapchainCreateInfo swci = {
	    .type = XR_TYPE_SWAPCHAIN_CREATE_INFO,
	    .usageFlags = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT | XR_SWAPCHAIN_USAGE_TRANSFER_DST_BIT |
	                  XR_SWAPCHAIN_USAGE_SAMPLED_BIT,
	    .format = m->sc_format,
	    .sampleCount = 1,
	    .width = m->pw,
	    .height = m->ph,
	    .faceCount = 1,
	    .arraySize = 1,
	    .mipCount = 1,
	};
	if (XR_FAILED(xr_check(m, xrCreateSwapchain(m->session, &swci, &m->swapchain), "xrCreateSwapchain")))
		return false;
	XrSwapchainImageMetalKHR imgs[MAX_IMAGES];
	for (int i = 0; i < MAX_IMAGES; i++)
		imgs[i] = (XrSwapchainImageMetalKHR){.type = XR_TYPE_SWAPCHAIN_IMAGE_METAL_KHR};
	xrEnumerateSwapchainImages(m->swapchain, MAX_IMAGES, &m->nimages, (XrSwapchainImageBaseHeader *)imgs);
	for (uint32_t i = 0; i < m->nimages; i++)
		m->images[i] = (id<MTLTexture>)imgs[i].texture;

	bool bgr = m->sc_format == MTLPixelFormatBGRA8Unorm_sRGB;
	pthread_mutex_lock(&m->lock);
	if (bgr != m->bgr) {
		for (size_t i = 0; i < (size_t)m->pw * m->ph; i++) {
			uint8_t t = m->page[i * 4];
			m->page[i * 4] = m->page[i * 4 + 2];
			m->page[i * 4 + 2] = t;
		}
		m->bgr = bgr;
	}
	m->dirty = true;
	m->stats.color_scale_bias = m->has_color_scale;
	pthread_mutex_unlock(&m->lock);
	logf_(m, "overlay session created: %ux%u swapchain format %lld, %u images", m->pw, m->ph,
	      (long long)m->sc_format, m->nimages);
	return true;
}

// Copies every quad's rect (plus a 1 px border for filtering) from the page into a new swapchain image.
static bool
produce_image(ovxr *m, const ovxr_quad *q, uint32_t n)
{
	XRF(xrAcquireSwapchainImage);
	XRF(xrWaitSwapchainImage);
	XRF(xrReleaseSwapchainImage);
	uint32_t idx;
	if (XR_FAILED(xr_check(m, xrAcquireSwapchainImage(m->swapchain, NULL, &idx), "acquire")))
		return false;
	XrSwapchainImageWaitInfo wi = {.type = XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO, .timeout = XR_INFINITE_DURATION};
	if (XR_FAILED(xr_check(m, xrWaitSwapchainImage(m->swapchain, &wi), "wait image")))
		return false;

	struct { int32_t x, y, w, h; } regions[MAX_QUADS];
	uint32_t nr = 0;
	pthread_mutex_lock(&m->lock);
	for (uint32_t i = 0; i < n; i++) {
		int32_t x0 = q[i].rect[0] - 1, y0 = q[i].rect[1] - 1;
		int32_t x1 = q[i].rect[0] + q[i].rect[2] + 1, y1 = q[i].rect[1] + q[i].rect[3] + 1;
		x0 = x0 < 0 ? 0 : x0;
		y0 = y0 < 0 ? 0 : y0;
		x1 = x1 > (int32_t)m->pw ? (int32_t)m->pw : x1;
		y1 = y1 > (int32_t)m->ph ? (int32_t)m->ph : y1;
		if (x1 <= x0 || y1 <= y0)
			continue;
		for (int32_t y = y0; y < y1; y++) {
			size_t o = ((size_t)y * m->pw + x0) * 4;
			memcpy(m->staging_ptr + o, m->page + o, (size_t)(x1 - x0) * 4);
		}
		regions[nr].x = x0;
		regions[nr].y = y0;
		regions[nr].w = x1 - x0;
		regions[nr].h = y1 - y0;
		nr++;
	}
	m->dirty = false;
	pthread_mutex_unlock(&m->lock);

	double t0 = now_s();
	@autoreleasepool {
		id<MTLCommandBuffer> cb = [m->queue commandBuffer];
		id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
		for (uint32_t i = 0; i < nr; i++) {
			[blit copyFromBuffer:m->staging
			           sourceOffset:((NSUInteger)regions[i].y * m->pw + regions[i].x) * 4
			      sourceBytesPerRow:(NSUInteger)m->pw * 4
			    sourceBytesPerImage:(NSUInteger)m->pw * 4 * regions[i].h
			             sourceSize:MTLSizeMake(regions[i].w, regions[i].h, 1)
			              toTexture:m->images[idx]
			       destinationSlice:0
			       destinationLevel:0
			      destinationOrigin:MTLOriginMake(regions[i].x, regions[i].y, 0)];
		}
		[blit endEncoding];
		[cb commit];
		[cb waitUntilCompleted];
	}
	double waited = (now_s() - t0) * 1e3;

	xr_check(m, xrReleaseSwapchainImage(m->swapchain, NULL), "release");
	m->have_image = true;
	pthread_mutex_lock(&m->lock);
	m->stats.images++;
	m->stats.copy_gpu_wait_ms += waited;
	pthread_mutex_unlock(&m->lock);
	return true;
}

static void
poll_events(ovxr *m)
{
	XRF(xrPollEvent);
	XRF(xrBeginSession);
	XRF(xrEndSession);
	XrEventDataBuffer ev = {.type = XR_TYPE_EVENT_DATA_BUFFER};
	while (xrPollEvent(m->instance, &ev) == XR_SUCCESS) {
		if (ev.type == XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED) {
			XrEventDataSessionStateChanged *sc = (XrEventDataSessionStateChanged *)&ev;
			m->state = sc->state;
			if (sc->state == XR_SESSION_STATE_READY) {
				XrSessionBeginInfo sbi = {.type = XR_TYPE_SESSION_BEGIN_INFO,
				                          .primaryViewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO};
				if (XR_SUCCEEDED(xr_check(m, xrBeginSession(m->session, &sbi), "xrBeginSession"))) {
					m->running = true;
					pthread_mutex_lock(&m->lock);
					m->stats.session_running = 1;
					pthread_mutex_unlock(&m->lock);
					logf_(m, "overlay session running");
				}
			} else if (sc->state == XR_SESSION_STATE_STOPPING) {
				xrEndSession(m->session);
				m->running = false;
			} else if (sc->state == XR_SESSION_STATE_EXITING || sc->state == XR_SESSION_STATE_LOSS_PENDING) {
				logf_(m, "session state %d: closing", sc->state);
				destroy_all(m);
				return;
			}
		} else if (ev.type == XR_TYPE_EVENT_DATA_INSTANCE_LOSS_PENDING) {
			logf_(m, "instance loss pending");
			destroy_all(m);
			return;
		}
		ev = (XrEventDataBuffer){.type = XR_TYPE_EVENT_DATA_BUFFER};
	}
}

static void
run_frame(ovxr *m)
{
	XRF(xrWaitFrame);
	XRF(xrBeginFrame);
	XRF(xrEndFrame);
	XrFrameState fs = {.type = XR_TYPE_FRAME_STATE};
	XrResult r = xrWaitFrame(m->session, NULL, &fs);
	if (XR_FAILED(r)) {
		logf_(m, "xrWaitFrame %d: closing", r);
		destroy_all(m);
		return;
	}
	xrBeginFrame(m->session, NULL);

	ovxr_quad q[MAX_QUADS];
	pthread_mutex_lock(&m->lock);
	uint32_t n = m->nquads;
	memcpy(q, m->quads, n * sizeof(*q));
	bool dirty = m->dirty;
	pthread_mutex_unlock(&m->lock);

	if (fs.shouldRender && n && (dirty || !m->have_image))
		produce_image(m, q, n);

	XrCompositionLayerQuad layers[MAX_QUADS];
	XrCompositionLayerColorScaleBiasKHR csb[MAX_QUADS];
	const XrCompositionLayerBaseHeader *lp[MAX_QUADS];
	uint32_t nl = 0;
	if (fs.shouldRender && m->have_image) {
		for (uint32_t i = 0; i < n; i++) {
			if (q[i].rect[2] <= 0 || q[i].rect[3] <= 0 || q[i].width <= 0 || q[i].height <= 0 ||
			    q[i].color_scale[3] <= 0)
				continue;
			layers[nl] = (XrCompositionLayerQuad){
			    .type = XR_TYPE_COMPOSITION_LAYER_QUAD,
			    .layerFlags = XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT,
			    .space = m->space,
			    .eyeVisibility = XR_EYE_VISIBILITY_BOTH,
			    .subImage = {.swapchain = m->swapchain,
			                 .imageRect = {{q[i].rect[0], q[i].rect[1]}, {q[i].rect[2], q[i].rect[3]}}},
			    .pose = {.orientation = {q[i].orientation[0], q[i].orientation[1], q[i].orientation[2],
			                             q[i].orientation[3]},
			             .position = {q[i].position[0], q[i].position[1], q[i].position[2]}},
			    .size = {q[i].width, q[i].height},
			};
			const float *s = q[i].color_scale;
			if (m->has_color_scale && (s[0] != 1 || s[1] != 1 || s[2] != 1 || s[3] != 1)) {
				csb[nl] = (XrCompositionLayerColorScaleBiasKHR){
				    .type = XR_TYPE_COMPOSITION_LAYER_COLOR_SCALE_BIAS_KHR,
				    .colorScale = {s[0], s[1], s[2], s[3]},
				};
				layers[nl].next = &csb[nl];
			}
			lp[nl] = (const XrCompositionLayerBaseHeader *)&layers[nl];
			nl++;
		}
	}
	XrFrameEndInfo fei = {
	    .type = XR_TYPE_FRAME_END_INFO,
	    .displayTime = fs.predictedDisplayTime,
	    .environmentBlendMode = XR_ENVIRONMENT_BLEND_MODE_OPAQUE,
	    .layerCount = nl,
	    .layers = lp,
	};
	r = xrEndFrame(m->session, &fei);
	if (XR_FAILED(r))
		logf_(m, "xrEndFrame %d", r);
	pthread_mutex_lock(&m->lock);
	m->stats.frames++;
	pthread_mutex_unlock(&m->lock);
}

static void *
xr_thread(void *arg)
{
	ovxr *m = arg;
	pthread_setname_np("overlay-xr");
	for (;;) @autoreleasepool {
		pthread_mutex_lock(&m->lock);
		bool quit = m->quit;
		bool want = m->nquads > 0 || now_s() - m->last_quads_s < m->linger_ms / 1e3;
		if (!quit && !m->instance && !want) {
			pthread_cond_wait(&m->cond, &m->lock);
			pthread_mutex_unlock(&m->lock);
			continue;
		}
		pthread_mutex_unlock(&m->lock);
		if (quit)
			break;

		if (!m->instance) {
			if (now_s() < m->next_try_s || !create_instance(m)) {
				if (now_s() >= m->next_try_s)
					m->next_try_s = now_s() + 2;
				struct timespec ts = {0, 100 * 1000 * 1000};
				nanosleep(&ts, NULL);
				continue;
			}
		}
		if (!m->session) {
			if (!want) {
				destroy_all(m);
				continue;
			}
			if (!create_session(m)) {
				destroy_all(m);
				m->next_try_s = now_s() + 2;
				continue;
			}
		}
		poll_events(m);
		if (!m->instance)
			continue;
		if (!want && m->running && !m->exit_requested) {
			XRF(xrRequestExitSession);
			xrRequestExitSession(m->session);
			m->exit_requested = true;
		}
		if (m->running) {
			run_frame(m);
		} else if (m->state == XR_SESSION_STATE_IDLE && m->exit_requested) {
			logf_(m, "overlay session ended");
			destroy_all(m);
		} else {
			struct timespec ts = {0, 10 * 1000 * 1000};
			nanosleep(&ts, NULL);
		}
	}
	destroy_all(m);
	return NULL;
}

ovxr *
ovxr_create(uint32_t page_width, uint32_t page_height, uint32_t linger_ms, ovxr_log_fn log)
{
	pthread_once(&lut_once, lut_init);
	ovxr *m = calloc(1, sizeof(*m));
	m->pw = page_width;
	m->ph = page_height;
	m->linger_ms = linger_ms;
	m->logfn = log;
	m->gipa = xrGetInstanceProcAddr;
	m->page = calloc((size_t)page_width * page_height, 4);
	m->bgr = false;
	pthread_mutex_init(&m->lock, NULL);
	pthread_cond_init(&m->cond, NULL);
	pthread_create(&m->thread, NULL, xr_thread, m);
	return m;
}

void
ovxr_upload(ovxr *m, int32_t x, int32_t y, int32_t w, int32_t h, const void *bgra, size_t stride)
{
	if (x < 0) {
		w += x;
		bgra = (const uint8_t *)bgra - x * 4;
		x = 0;
	}
	if (y < 0) {
		h += y;
		bgra = (const uint8_t *)bgra - (ptrdiff_t)y * stride;
		y = 0;
	}
	if (x + w > (int32_t)m->pw)
		w = (int32_t)m->pw - x;
	if (y + h > (int32_t)m->ph)
		h = (int32_t)m->ph - y;
	if (w <= 0 || h <= 0)
		return;
	double t0 = now_s();
	pthread_mutex_lock(&m->lock);
	int ri = m->bgr ? 2 : 0, bi = m->bgr ? 0 : 2;
	for (int32_t row = 0; row < h; row++) {
		const uint8_t *s = (const uint8_t *)bgra + (size_t)row * stride;
		uint8_t *d = m->page + ((size_t)(y + row) * m->pw + x) * 4;
		for (int32_t i = 0; i < w; i++, s += 4, d += 4) {
			const uint8_t *l = lut + s[3] * 256;
			d[bi] = l[s[0]];
			d[1] = l[s[1]];
			d[ri] = l[s[2]];
			d[3] = s[3];
		}
	}
	m->dirty = true;
	m->stats.uploads++;
	m->stats.upload_pixels += (uint64_t)w * h;
	m->stats.upload_cpu_ms += (now_s() - t0) * 1e3;
	pthread_mutex_unlock(&m->lock);
}

void
ovxr_set_quads(ovxr *m, const ovxr_quad *quads, uint32_t n)
{
	if (n > MAX_QUADS)
		n = MAX_QUADS;
	pthread_mutex_lock(&m->lock);
	bool changed = n != m->nquads;
	for (uint32_t i = 0; i < n && !changed; i++)
		changed = memcmp(m->quads[i].rect, quads[i].rect, sizeof(quads[i].rect)) != 0;
	memcpy(m->quads, quads, n * sizeof(*quads));
	m->nquads = n;
	if (changed)
		m->dirty = true;
	if (n)
		m->last_quads_s = now_s();
	else if (changed)
		m->last_quads_s = now_s();
	pthread_cond_signal(&m->cond);
	pthread_mutex_unlock(&m->lock);
}

void
ovxr_get_stats(ovxr *m, ovxr_stats *out)
{
	pthread_mutex_lock(&m->lock);
	*out = m->stats;
	pthread_mutex_unlock(&m->lock);
}

void
ovxr_destroy(ovxr *m)
{
	pthread_mutex_lock(&m->lock);
	m->quit = true;
	pthread_cond_signal(&m->cond);
	pthread_mutex_unlock(&m->lock);
	pthread_join(m->thread, NULL);
	free(m->page);
	pthread_mutex_destroy(&m->lock);
	pthread_cond_destroy(&m->cond);
	free(m);
}
