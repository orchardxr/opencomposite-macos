// A stub OpenXR runtime for headless tests: one simulated HMD system with XR_KHR_metal_enable, enough for
// OpenComposite's VR_Init (instance, system, views, a Metal session going IDLE -> READY and STOPPING -> EXITING, reference spaces), no frames. No XR_EXTX_overlay,
// so the web helper's overlay session stops at "runtime lacks XR_EXTX_overlay".
#define XR_USE_GRAPHICS_API_METAL
#include <openxr/openxr.h>
#include <openxr/openxr_loader_negotiation.h>
#include <openxr/openxr_platform.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern void* MTLCreateSystemDefaultDevice(void);

#define EXPORT __attribute__((visibility("default")))

static uint64_t next_handle = 100;
static XrSession session = XR_NULL_HANDLE;
static XrSessionState next_state = 0;
static int stub_log = -1;

static void say(const char* what, const char* name)
{
	if (stub_log < 0)
		stub_log = getenv("STUB_XR_LOG") != NULL;
	if (stub_log)
		fprintf(stderr, "stub-xr: %s %s\n", what, name);
}

static XrResult enum_extensions(const char* layer, uint32_t cap, uint32_t* count, XrExtensionProperties* props)
{
	static const char* names[] = { XR_KHR_METAL_ENABLE_EXTENSION_NAME };
	*count = 1;
	if (cap == 0)
		return XR_SUCCESS;
	if (cap < 1)
		return XR_ERROR_SIZE_INSUFFICIENT;
	strcpy(props[0].extensionName, names[0]);
	props[0].extensionVersion = 1;
	return XR_SUCCESS;
}

static XrResult enum_layers(uint32_t cap, uint32_t* count, XrApiLayerProperties* props)
{
	*count = 0;
	return XR_SUCCESS;
}

static XrResult create_instance(const XrInstanceCreateInfo* info, XrInstance* out)
{
	*out = (XrInstance)next_handle++;
	return XR_SUCCESS;
}

static XrResult destroy_handle(void* h) { return XR_SUCCESS; }

static XrResult get_instance_properties(XrInstance i, XrInstanceProperties* p)
{
	p->runtimeVersion = XR_MAKE_VERSION(1, 0, 0);
	strcpy(p->runtimeName, "stub");
	return XR_SUCCESS;
}

static XrResult get_system(XrInstance i, const XrSystemGetInfo* info, XrSystemId* out)
{
	*out = 1;
	return XR_SUCCESS;
}

static XrResult get_system_properties(XrInstance i, XrSystemId s, XrSystemProperties* p)
{
	p->systemId = s;
	strcpy(p->systemName, "stub HMD");
	p->graphicsProperties.maxSwapchainImageWidth = 4096;
	p->graphicsProperties.maxSwapchainImageHeight = 4096;
	p->graphicsProperties.maxLayerCount = 16;
	p->trackingProperties.orientationTracking = XR_TRUE;
	p->trackingProperties.positionTracking = XR_TRUE;
	return XR_SUCCESS;
}

static XrResult enum_view_config_views(XrInstance i, XrSystemId s, XrViewConfigurationType t, uint32_t cap, uint32_t* count,
    XrViewConfigurationView* views)
{
	*count = 2;
	if (cap == 0)
		return XR_SUCCESS;
	if (cap < 2)
		return XR_ERROR_SIZE_INSUFFICIENT;
	for (int v = 0; v < 2; v++) {
		views[v].recommendedImageRectWidth = views[v].maxImageRectWidth = 1024;
		views[v].recommendedImageRectHeight = views[v].maxImageRectHeight = 1024;
		views[v].recommendedSwapchainSampleCount = views[v].maxSwapchainSampleCount = 1;
	}
	return XR_SUCCESS;
}

static XrResult enum_view_configs(XrInstance i, XrSystemId s, uint32_t cap, uint32_t* count, XrViewConfigurationType* t)
{
	*count = 1;
	if (cap >= 1)
		t[0] = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
	return XR_SUCCESS;
}

static XrResult enum_blend_modes(XrInstance i, XrSystemId s, XrViewConfigurationType t, uint32_t cap, uint32_t* count,
    XrEnvironmentBlendMode* m)
{
	*count = 1;
	if (cap >= 1)
		m[0] = XR_ENVIRONMENT_BLEND_MODE_OPAQUE;
	return XR_SUCCESS;
}

static XrResult metal_requirements(XrInstance i, XrSystemId s, XrGraphicsRequirementsMetalKHR* r)
{
	r->metalDevice = MTLCreateSystemDefaultDevice();
	return r->metalDevice ? XR_SUCCESS : XR_ERROR_RUNTIME_FAILURE;
}

static XrResult create_session(XrInstance i, const XrSessionCreateInfo* info, XrSession* out)
{
	*out = session = (XrSession)next_handle++;
	next_state = XR_SESSION_STATE_IDLE;
	return XR_SUCCESS;
}

static XrResult enum_reference_spaces(XrSession s, uint32_t cap, uint32_t* count, XrReferenceSpaceType* t)
{
	static const XrReferenceSpaceType types[] = { XR_REFERENCE_SPACE_TYPE_VIEW, XR_REFERENCE_SPACE_TYPE_LOCAL,
		XR_REFERENCE_SPACE_TYPE_STAGE };
	*count = 3;
	if (cap == 0)
		return XR_SUCCESS;
	if (cap < 3)
		return XR_ERROR_SIZE_INSUFFICIENT;
	memcpy(t, types, sizeof(types));
	return XR_SUCCESS;
}

static XrResult create_reference_space(XrSession s, const XrReferenceSpaceCreateInfo* info, XrSpace* out)
{
	*out = (XrSpace)next_handle++;
	return XR_SUCCESS;
}

static XrResult get_reference_space_bounds(XrSession s, XrReferenceSpaceType t, XrExtent2Df* b)
{
	b->width = 2;
	b->height = 2;
	return XR_SUCCESS;
}

static XrResult poll_event(XrInstance i, XrEventDataBuffer* ev)
{
	if (!next_state)
		return XR_EVENT_UNAVAILABLE;
	XrEventDataSessionStateChanged* sc = (XrEventDataSessionStateChanged*)ev;
	memset(sc, 0, sizeof(*sc));
	sc->type = XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED;
	sc->session = session;
	sc->state = next_state;
	if (next_state == XR_SESSION_STATE_IDLE)
		next_state = XR_SESSION_STATE_READY;
	else if (next_state == XR_SESSION_STATE_STOPPING)
		next_state = XR_SESSION_STATE_EXITING;
	else
		next_state = 0;
	return XR_SUCCESS;
}

static XrResult request_exit(XrSession s)
{
	next_state = XR_SESSION_STATE_STOPPING;
	return XR_SUCCESS;
}

static char paths[256][256];
static uint32_t npaths = 0;

static XrResult string_to_path(XrInstance i, const char* s, XrPath* out)
{
	for (uint32_t p = 0; p < npaths; p++) {
		if (!strcmp(paths[p], s)) {
			*out = p + 1;
			return XR_SUCCESS;
		}
	}
	if (npaths == 256 || strlen(s) >= 256)
		return XR_ERROR_PATH_COUNT_EXCEEDED;
	strcpy(paths[npaths++], s);
	*out = npaths;
	return XR_SUCCESS;
}

static XrResult path_to_string(XrInstance i, XrPath p, uint32_t cap, uint32_t* count, char* buf)
{
	if (p == 0 || p > npaths)
		return XR_ERROR_PATH_INVALID;
	*count = (uint32_t)strlen(paths[p - 1]) + 1;
	if (cap == 0)
		return XR_SUCCESS;
	if (cap < *count)
		return XR_ERROR_SIZE_INSUFFICIENT;
	strcpy(buf, paths[p - 1]);
	return XR_SUCCESS;
}

static XrResult result_to_string(XrInstance i, XrResult r, char buf[XR_MAX_RESULT_STRING_SIZE])
{
	snprintf(buf, XR_MAX_RESULT_STRING_SIZE, "XrResult_%d", r);
	return XR_SUCCESS;
}

static XrResult structure_to_string(XrInstance i, XrStructureType t, char buf[XR_MAX_STRUCTURE_NAME_SIZE])
{
	snprintf(buf, XR_MAX_STRUCTURE_NAME_SIZE, "XrStructureType_%d", t);
	return XR_SUCCESS;
}

static XrResult create_handle(XrInstance i, const void* info, uint64_t* out)
{
	*out = next_handle++;
	return XR_SUCCESS;
}

static XrResult success(void) { return XR_SUCCESS; }

static const struct {
	const char* name;
	PFN_xrVoidFunction fn;
} functions[] = {
#define F(n, f) { #n, (PFN_xrVoidFunction)f }
	F(xrEnumerateInstanceExtensionProperties, enum_extensions),
	F(xrEnumerateApiLayerProperties, enum_layers),
	F(xrCreateInstance, create_instance),
	F(xrDestroyInstance, destroy_handle),
	F(xrGetInstanceProperties, get_instance_properties),
	F(xrGetSystem, get_system),
	F(xrGetSystemProperties, get_system_properties),
	F(xrEnumerateViewConfigurations, enum_view_configs),
	F(xrEnumerateViewConfigurationViews, enum_view_config_views),
	F(xrEnumerateEnvironmentBlendModes, enum_blend_modes),
	F(xrGetMetalGraphicsRequirementsKHR, metal_requirements),
	F(xrCreateSession, create_session),
	F(xrDestroySession, destroy_handle),
	F(xrEnumerateReferenceSpaces, enum_reference_spaces),
	F(xrCreateReferenceSpace, create_reference_space),
	F(xrGetReferenceSpaceBoundsRect, get_reference_space_bounds),
	F(xrDestroySpace, destroy_handle),
	F(xrPollEvent, poll_event),
	F(xrRequestExitSession, request_exit),
	F(xrBeginSession, success),
	F(xrEndSession, success),
	F(xrStringToPath, string_to_path),
	F(xrPathToString, path_to_string),
	F(xrResultToString, result_to_string),
	F(xrStructureTypeToString, structure_to_string),
	F(xrCreateActionSet, create_handle),
	F(xrCreateAction, create_handle),
	F(xrDestroyActionSet, destroy_handle),
	F(xrDestroyAction, destroy_handle),
	F(xrSuggestInteractionProfileBindings, success),
	F(xrAttachSessionActionSets, success),
#undef F
};

static XrResult XRAPI_CALL get_instance_proc_addr(XrInstance instance, const char* name, PFN_xrVoidFunction* fn)
{
	for (size_t i = 0; i < sizeof(functions) / sizeof(functions[0]); i++) {
		if (!strcmp(functions[i].name, name)) {
			*fn = functions[i].fn;
			return XR_SUCCESS;
		}
	}
	say("unsupported", name);
	*fn = NULL;
	return XR_ERROR_FUNCTION_UNSUPPORTED;
}

EXPORT XrResult xrNegotiateLoaderRuntimeInterface(const XrNegotiateLoaderInfo* loaderInfo, XrNegotiateRuntimeRequest* request)
{
	request->runtimeInterfaceVersion = XR_CURRENT_LOADER_RUNTIME_VERSION;
	request->runtimeApiVersion = XR_MAKE_VERSION(1, 0, 0);
	request->getInstanceProcAddr = get_instance_proc_addr;
	return XR_SUCCESS;
}
