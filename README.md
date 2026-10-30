# opencomposite-macos

Native macOS [OpenComposite](https://gitlab.com/znixian/OpenOVR): an OpenVR runtime (`vrclient.dylib`) that
translates OpenVR to OpenXR, with a Metal compositor (`vr::TextureType_Metal` submits, `XR_KHR_metal_enable`
swapchains). It is installed once per user as the shared OpenVR runtime, the way OpenComposite is used on Linux, and
any OpenVR client on the Mac loads it:

- Native macOS OpenVR games (`vr::TextureType_Metal`) use this runtime directly through `openvr_api`. This path is
  barely tested so far.
- Windows games reach it through [orchardxr/varbor](https://github.com/orchardxr/varbor), whose vrclient bridge
  forwards to it.

Frames go to an OpenXR runtime with `XR_KHR_metal_enable`, such as WiVRn's server from
[orchardxr/wivrn-macos](https://github.com/orchardxr/wivrn-macos), which streams to any WiVRn-supported headset
(tested on Quest 3S).

Builds are universal (arm64 + x86_64) and ad-hoc signed.

Part of orchardxr: vibe-coded support for VR on macOS: native and Windows games, on Apple Silicon, streamed via WiVRn.

## Layout

| Path | What |
|---|---|
| `third_party/opencomposite` | upstream OpenComposite (submodule, pinned; its own submodules glm, libunwind, openxr-sdk 1.0.12 are recursive) |
| `third_party/openxr-sdk` | OpenXR-SDK-Source `release-1.1.65`, for the OpenXR loader shipped next to `vrclient.dylib` |
| `patches/opencomposite` | our patch stack, applied (staged, never committed) on top of the pin |
| `scripts/patches.sh` | `apply` / `reset` / `status` / `new <name>` for the patch stack |
| `scripts/build.sh` | builds the install tree and the test app |
| `scripts/install.sh` | per-user install / uninstall / status |
| `scripts/package.sh` | release zip |
| `scripts/run-ovr-metal.sh` | runs the Metal test app against an OpenXR runtime |
| `tests/openvr-metal` | native OpenVR app submitting Metal textures |
| `tests/install` | installer test against a throwaway `HOME` |

### Patches

The numbering follows the stack these patches came from; 0001 (`mingw-build`) and 0005
(`msvc-aggregate-returns-on-mingw`) only served a Windows `vrclient_x64.dll` built with llvm-mingw and are not part
of this repo.

| Patch | Why |
|---|---|
| 0002 log-stream-construct-on-first-use | log stream usable from other static initialisers |
| 0003 vulkan-without-win32-memory-and-core-1-1 | Vulkan: only device extensions that exist (no Win32 external memory), no core-1.1 entry points on 1.0 instances |
| 0004 openvr-sdk-2.15.6-interfaces | interfaces of OpenVR 2.15.6 (current games) |
| 0006 copy-submitted-bounds-and-runtime-refresh-rate | copy only the submitted texture bounds; display refresh rate from the runtime (XR_FB_display_refresh_rate) |
| 0007 quiet-no-vr-and-runtime-loss | no runtime or headset: an init error instead of a message box; runtime loss: stop the frame loop, send VREvent_Quit |
| 0008 web-overlay-mailbox | mailbox/control-panel interfaces SteamVR web overlays use |
| 0009 macos-native-build | CMake and sources build natively on macOS (`bin/osx64/vrclient.dylib`) |
| 0010 metal-compositor | Metal compositor and `XR_KHR_metal_enable` session |
| 0011 metal-submit-sync | `oc_metal_submit_sync_begin` / `oc_metal_submit_sync_end` exports for bridges that submit from another thread |

## Build

Needs Xcode (or the Command Line Tools), CMake and Ninja (`brew install cmake ninja`; ccache is used when present).

```sh
git clone --recursive git@github.com:orchardxr/opencomposite-macos.git
cd opencomposite-macos
scripts/patches.sh apply
scripts/build.sh
```

Output in `build/install/runtime`:

```
runtime/bin/osx64/vrclient.dylib           universal, exports VRClientCoreFactory, oc_metal_submit_sync_begin/end
runtime/bin/osx64/libopenxr_loader.dylib   universal OpenXR loader 1.1.65 (vrclient finds it via @loader_path)
runtime/bin/osx64/version.txt
```

`scripts/package.sh <name>` zips it with `install.sh`, this README and the licences into `build/dist/<name>.zip`.

## Install

```sh
scripts/install.sh            # or ./install.sh from a release zip
scripts/install.sh status
scripts/install.sh uninstall
```

The runtime goes to `~/Library/Application Support/OpenComposite/runtime` (override with `OPENCOMPOSITE_HOME`), next to
`config/` and `logs/`. The installer then puts that directory first in the `runtime` list of
`~/Library/Application Support/OpenVR/.openvr/openvrpaths.vrpath`, creating the file if needed. Other runtimes there
(SteamVR) stay in the list behind it, and `config`, `log` and `external_drivers` are left as they are. Uninstall
removes the entry (and the file, if nothing else is registered) and deletes the install directory. Nothing needs root.

`tests/install/test-install.sh` runs install, reinstall and uninstall against a temporary `HOME` (with and without an
existing SteamVR entry) and `dlopen`s the installed `vrclient.dylib` as arm64 and, under Rosetta, as x86_64.

## How runtimes find it

1. An OpenVR client (`openvr_api`, or a vrclient bridge) reads
   `~/Library/Application Support/OpenVR/.openvr/openvrpaths.vrpath` and takes the first entry of `runtime`
   (`VR_OVERRIDE=<runtime dir>` overrides this in `openvr_api`).
2. It loads `<runtime>/bin/osx64/vrclient.dylib` and calls `VRClientCoreFactory("IVRClientCore_003")`.
3. OpenComposite loads the OpenXR loader next to it, which finds the OpenXR runtime the usual way: `XR_RUNTIME_JSON`,
   else the active runtime manifest (see the OpenXR loader documentation).
4. The OpenXR runtime must offer `XR_KHR_metal_enable`. Monado (and WiVRn's server) get it from the Metal patch in
   [orchardxr/wivrn-macos](https://github.com/orchardxr/wivrn-macos).

## Test

`tests/openvr-metal/ovr_metal.mm` is a native OpenVR app that loads `<runtime>/bin/osx64/vrclient.dylib` itself and
submits Metal textures in four modes (`separate`, `sbs`, `array`, `msaa`). `scripts/build.sh` builds it as
`build/tests/ovr_metal` (arm64) against OpenComposite's bundled OpenVR 2.15.6 header.

It needs an OpenXR runtime with `XR_KHR_metal_enable`: a Monado service built from orchardxr/wivrn-macos (its Monado
patch stack, including the Metal enable patch; the null compositor's frame dump and sync stats come from the same
stack). Pass the runtime manifest:

```sh
# start a private null-compositor service for the run (simulated HMD, frame dump to build/logs/ovr-metal):
MONADO_SERVICE=<monado build>/src/xrt/targets/service/monado-service \
  scripts/run-ovr-metal.sh <monado build>/openxr_monado-dev.json 30 separate
# or against a service that is already running (e.g. WiVRn's server):
scripts/run-ovr-metal.sh <path to the runtime's openxr json> 30 sbs
```

The app exits non-zero on any error; the script prints the log tails, error counts and the frame dump path.

## Licence

- OpenComposite and our patches to it (`patches/opencomposite`) are GPL-3.0, as upstream
  (`third_party/opencomposite/LICENSE.txt`); the built `vrclient.dylib` is GPL-3.0. Release zips include the licences;
  the corresponding source is the tagged commit of this repo (submodule pins plus patches).
- The OpenXR loader is Apache-2.0 (`third_party/openxr-sdk/LICENSE`).
- Everything else here (scripts, CI, tests, docs) is MIT, see `LICENSE`.
