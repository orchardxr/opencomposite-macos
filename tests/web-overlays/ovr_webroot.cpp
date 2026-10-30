// Plays a game's side of the web overlays through <runtime>/bin/osx64/vrclient.dylib, as Half-Life: Alyx does:
// RegisterMailbox("test/mailbox"), IVRControlPanel_006::RegisterExternalWebRoot(<webroot>) (vtable slot 26), then
// ReadMessage until the page's "ready" arrives.
//   ovr_webroot <runtime dir> <webroot dir> [seconds]
// Exit status 0 when the page's real "ready" arrived, 1 otherwise.
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <string>

class IVRClientCore {
public:
	virtual int Init(int eApplicationType, const char* pStartupInfo) = 0;
	virtual void Cleanup() = 0;
	virtual int IsInterfaceVersionValid(const char* pchInterfaceVersion) = 0;
	virtual void* GetGenericInterface(const char* pchNameAndVersion, int* peError) = 0;
	virtual bool BIsHmdPresent() = 0;
	virtual const char* GetEnglishStringForHmdError(int eError) = 0;
	virtual const char* GetIDForVRInitError(int eError) = 0;
};
typedef void* (*VRClientCoreFactoryFn)(const char* pInterfaceName, int* pReturnCode);

class IVRMailbox {
public:
	virtual int RegisterMailbox(const char* name, uint64_t* handle) = 0;
	virtual int UnregisterMailbox(uint64_t handle) = 0;
	virtual int SendMessage(uint64_t handle, const char* type, const char* message) = 0;
	virtual int ReadMessage(uint64_t mbox, char* outBuf, uint32_t outBufLen, uint32_t* msgLen) = 0;
};

static int RegisterExternalWebRoot(void* panel, const char* path)
{
	typedef int (*fn_t)(void*, const char*);
	return ((fn_t*)*(void**)panel)[26](panel, path);
}

static double now()
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec * 1e-9;
}

int main(int argc, char** argv)
{
	if (argc < 3) {
		fprintf(stderr, "usage: %s <runtime dir> <webroot dir> [seconds]\n", argv[0]);
		return 2;
	}
	setvbuf(stdout, nullptr, _IOLBF, 0);
	std::string lib = std::string(argv[1]) + "/bin/osx64/vrclient.dylib";
	double seconds = argc > 3 ? atof(argv[3]) : 20;
	void* dl = dlopen(lib.c_str(), RTLD_NOW | RTLD_LOCAL);
	if (!dl) {
		fprintf(stderr, "dlopen %s: %s\n", lib.c_str(), dlerror());
		return 1;
	}
	auto factory = (VRClientCoreFactoryFn)dlsym(dl, "VRClientCoreFactory");
	int rc = 0;
	auto core = factory ? (IVRClientCore*)factory("IVRClientCore_003", &rc) : nullptr;
	if (!core) {
		fprintf(stderr, "no IVRClientCore_003 in %s\n", lib.c_str());
		return 1;
	}
	int err = core->Init(1 /* VRApplication_Scene */, nullptr);
	if (err) {
		fprintf(stderr, "Init failed: %s\n", core->GetEnglishStringForHmdError(err));
		return 1;
	}
	auto mailbox = (IVRMailbox*)core->GetGenericInterface("IVRMailbox_001", &err);
	void* panel = core->GetGenericInterface("IVRControlPanel_006", &err);
	if (!mailbox || !panel) {
		fprintf(stderr, "no IVRMailbox_001 / IVRControlPanel_006\n");
		return 1;
	}

	double t0 = now();
	uint64_t handle = 0;
	mailbox->RegisterMailbox("test/mailbox", &handle);
	printf("RegisterMailbox(test/mailbox) -> handle %llu in %.0f ms\n", (unsigned long long)handle, (now() - t0) * 1e3);
	t0 = now();
	rc = RegisterExternalWebRoot(panel, argv[2]);
	printf("RegisterExternalWebRoot(%s) -> %d in %.0f ms\n", argv[2], rc, (now() - t0) * 1e3);

	bool ready = false;
	char buf[4096];
	while (!ready && now() - t0 < seconds) {
		uint32_t len = 0;
		if (mailbox->ReadMessage(handle, buf, sizeof(buf), &len) == 0) {
			printf("ReadMessage: %s\n", buf);
			// The fake ready (no broker) is '{ "type": "ready", }'; the page's is JSON.stringify'd.
			ready = strstr(buf, "{\"type\":\"ready\"}") != nullptr;
			if (strstr(buf, "\"ready\", }")) {
				printf("fake ready: no broker\n");
				break;
			}
		} else {
			usleep(20000);
		}
	}
	printf("%s after %.0f ms\n", ready ? "page ready" : "no ready from the page", (now() - t0) * 1e3);
	mailbox->UnregisterMailbox(handle);
	core->Cleanup();
	return ready ? 0 : 1;
}
