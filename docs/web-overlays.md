# Web overlays (SteamVR's vrwebhelper pipeline on macOS)

Some games don't draw parts of their UI themselves. Half-Life: Alyx ships its loading screens ("LOADING", "Press
Trigger To Start", chapter titles, tips, the hologram map) as a web page (`game/hlvr/webui`) and has SteamVR render
it. opencomposite-macos does the same thing SteamVR does, with the same messages, the same page and the same scene
graph:

| SteamVR | opencomposite-macos | Where |
|---|---|---|
| vrclient `IVRControlPanel::RegisterExternalWebRoot`, `IVRMailbox` (IPC to vrserver) | patch 0008: WebSocket client to the broker, starts the broker on demand | `patches/opencomposite/0008-web-overlay-mailbox.patch` |
| vrserver web server: mailboxes on `ws://localhost:27062`, `/fonts/get_font`, reads `vrwebui.config.json`, `create_overlays` to `vrwebhelper/main` | `oc-webbroker` | `web-overlays/Sources/oc-webbroker` |
| vrwebhelper (CEF): offscreen pages with `window.VRHTML`, scene graph to the compositor | `oc-webhelper`: offscreen WKWebView | `web-overlays/Sources/oc-webhelper` |
| vrcompositor scene graph: panels (rects of the page texture) as overlays in the standing universe | `XR_EXTX_overlay` session on the OpenXR runtime (WiVRn), one quad layer per panel | `web-overlays/Sources/COverlayXR` |

Both binaries are installed in `runtime/libexec/opencomposite/` next to `runtime/bin/osx64/vrclient.dylib`. They are
arm64 only (Swift, Network.framework, WebKit, Metal); x86_64 games under Rosetta start them as native processes.

## Who starts what

No app supervises anything:

1. The first time a game opens a mailbox (`IVRMailbox::RegisterMailbox`) or registers a web root and nothing listens
   on 127.0.0.1:27062, `vrclient.dylib` starts `oc-webbroker`. It finds it relative to its own file (`dladdr`:
   `<runtime>/bin/osx64/../../libexec/opencomposite/oc-webbroker`), so any install location works.
2. The game may be a Wine process (a Windows game through a vrclient bridge such as VarboR, x86_64 under Rosetta or
   arm64 under FEX). The broker is started with `posix_spawn` and a fresh environment: `HOME`, a system `PATH`,
   `USER`, `LOGNAME`, `TMPDIR`, `LANG`, and only the `XR_*`, `XDG_*` and `OC_WEB_*` variables listed in
   `WebMailbox.cpp` (no `WINE*`, `CX_*`, `DYLD_*`). Its descriptors are closed (`POSIX_SPAWN_CLOEXEC_DEFAULT`), its
   signal mask and handlers reset, and it runs in its own session. A thread in the game reaps it when it exits.
3. Every vrclient connection identifies itself with `oc_vrclient <pid>` (our addition to the protocol). The broker
   exits 5 s (`--idle-exit`) after the last of them closed, and also 5 s after start if none ever connects.
4. The broker starts `oc-webhelper` when a web root is registered; the helper exits when its last overlay is
   destroyed (the registering game's connection closed) or when it loses the broker.
5. If the broker can't be found or started, mailboxes behave as upstream OpenComposite: the game gets a fake
   `ready` and no overlays are shown.

Two games starting at once both try to start a broker; the second can't listen on the port and exits, and both games
connect to the first.

Logs: `~/Library/Logs/OpenComposite/web-overlays.log` (broker and helper, `[webhelper]` lines; rotated at 4 MB), the
game side in OpenComposite's log. The ini option `webOverlays=false` turns the whole feature off.

## What happens (Alyx, startup)

1. Alyx registers mailbox `hlvr/mailbox`, then calls `RegisterExternalWebRoot("<game>\hlvr\webui")` (vr.dll calls
   `IVRControlPanel_006` vtable slot 26 with one string). A vrclient bridge converts the path to a unix path, as
   Proton's vrclient does.
2. OpenComposite opens `vrclient/<pid>` on the broker and sends `register_external_webroot` with the path. It waits
   for the reply (vrserver also waits: "Waiting for %s to load", max 15 s).
3. The broker reads `vrwebui.config.json` (`interstitials`: `/interstitials.html`, type overlay, 2048x2048), names the
   web root after its last two path components (`hlvr/webui`, as vrserver), starts the helper and sends it
   `create_overlays`. The reply goes back when the helper reports `overlays_loaded`.
4. The page bootstraps only in an overlay (`VRHTML.Environment() == 2`), opens `hlvr/interstitials` and sends
   `{"type":"ready"}` to `hlvr/mailbox`. OpenComposite's `ReadMessage` returns it to the game.
5. The game sends `set_paths`, `begin_loading`, `show_message`, `end_loading` to `hlvr/interstitials`; the page renders
   them and calls `VRHTML.UpdateSceneGraph(json)` on every change.
6. The helper turns the scene graph into quads and shows them; on game exit the `vrclient/<pid>` connection closes, the
   broker sends `destroy_overlays`, the helper quits, and the broker follows after its grace period.

## Broker (`oc-webbroker`)

- WebSocket server on 127.0.0.1:27062 and [::1]:27062 (the page connects to `ws://localhost:27062`). Network.framework,
  no HTTP: pages are served by the helper's URL scheme handler. `--port` (or `OC_MAILBOX_PORT`) changes the port,
  `--log -` keeps the log on stdout.
- Text commands as SteamVR's: `mailbox_open <name>`, `mailbox_close <name>`, `mailbox_send <name> <json>`,
  `websocket_close`; plus `oc_vrclient <pid>`. A message goes to every connection that opened `<name>`.
- `web_server_mailbox`: `request_mailbox_registration_notification` → `mailbox_registered` (also later, when the
  mailbox opens), `request_mailbox_unavailable_notification` → `mailbox_unavailable`, `register_external_webroot`
  (vrclient talks to vrserver over its IPC for this in SteamVR), `overlays_loaded` (helper).
- Secret: vrserver rejects WebSocket requests without its secret and checks the origin. The broker listens on
  loopback only and accepts any or no secret.
- Messages to a mailbox nobody has opened are kept for 10 s and delivered when it opens (covers ordering races).

## Web helper (`oc-webhelper`)

- One offscreen borderless window per overlay (never shown) holding a WKWebView of `pixel_size` CSS pixels, with a
  non-persistent data store. SPI: `_setOverrideDeviceScaleFactor: 1` (1 CSS px = 1 texel, as CEF in SteamVR) and
  `_setWindowOcclusionDetectionEnabled: NO` (an offscreen window counts as occluded and WebKit would stop animations
  and rendering). Transparent background, sRGB window color space. It holds a `userInitiated | latencyCritical`
  activity so App Nap doesn't throttle it.
- `WKUserScript` at document start defines `window.VRHTML`: `Environment()` → 2, `UpdateSceneGraph(json, retired)` →
  `WKScriptMessageHandler`, `VROverlay.ThisOverlayHandle()`, and `VRProperties` / `VRRenderModelsInternal` /
  `VRRenderModels` that throw (only an unused controller-transform component calls them; it catches). The page's
  console goes to the log.
- `vrwebui://<webroot name>/…` (`WKURLSchemeHandler`) serves the web root. `/fonts/get_font?font=X`: from
  `~/Library/Application Support/OpenComposite/fonts/X`, else `<webroot>/fonts/X`, but only plain OpenType/TrueType
  files (see Fonts). `/dashboard/localization/webhelper_*.json` (SteamVR's own strings) is a 404, which the page
  ignores.
- Scene graph → quads (`SceneGraph.swift`): transform (translation, rotation w x y z, scale), opacity, tint; panels
  give `uv_min`/`uv_max` × pixel size = the texture rect, `width`/`height` in metres (a missing one from the rect's
  aspect), `origin` (−1…1). The root is the standing universe = STAGE. `parent-path`/`parent-id`,
  `target-dpi-panel-id`, curvature and the head-following transforms aren't used by Alyx and are logged once if seen.
- Pixels: `takeSnapshot` of each panel's rect at 30 Hz (`OC_WEB_FPS`), a third of that after 0.5 s without a change.
  Unchanged snapshots are dropped; changed ones are converted and staged (`ovxr_upload`).
- Debug: `OC_WEB_DUMP=<dir>` writes each changed panel as PNG and the last scene graph JSON; `OC_WEB_NO_XR=1` skips
  the compositor. vrclient passes both to the broker, which passes them to the helper.

## Compositor (`COverlayXR/overlay_xr.m`)

- Linked against the OpenXR loader shipped in `runtime/bin/osx64` (rpath `@executable_path/../../bin/osx64`). The
  loader finds the runtime: `XR_RUNTIME_JSON` (set by vrclient from the per-user active runtime, patch 0012), else the system active runtime; for WiVRn that is the
  manifest installed by orchardxr/wivrn-macos (`share/openxr/1/openxr_wivrn.json`).
- `XR_EXTX_overlay` session, `sessionLayersPlacement = 1` (above the game), STAGE space, `XR_KHR_metal_enable` (the
  extension OpenComposite itself needs), `XR_KHR_composition_layer_color_scale_bias` when offered. Application name
  `OpenComposite web overlays`.
- One `RGBA8Unorm_sRGB` (or `BGRA8Unorm_sRGB`) swapchain of the page size = the page texture, as SteamVR's overlay
  texture. Each panel is an `XrCompositionLayerQuad` whose `subImage.imageRect` is the panel rect. Pose and size from
  the scene graph, `BLEND_TEXTURE_SOURCE_ALPHA`, color scale = (tint × opacity, opacity).
- A new swapchain image is produced only when a panel changed: the rects (+1 px for filtering) are blitted from a
  shared `MTLBuffer` on the runtime's Metal device. Otherwise the last image is resubmitted.
- Premultiplied alpha: WebKit's pixels are premultiplied in sRGB-encoded space; the swapchain is sRGB, so the runtime
  decodes per channel. `ovxr_upload` stores encode(decode(c/a)·a) (a 64K-entry LUT), which the compositor decodes to
  the correct linear premultiplied value.
- The session (and the XrInstance) exists only while there are panels, plus 1 s. Without a headset session in WiVRn
  `xrCreateInstance` fails and is retried every 2 s.

## Status

- The pipeline (broker, helper, page, scene graph, quads) was checked end to end with Half-Life: Alyx on WiVRn and a
  Quest 3S in an earlier form: the broker was started by a launcher app and the compositor used Vulkan (MoltenVK).
  "Press Trigger To Start" size and position, LOADING with spinning arcs and animated dots were right; only the font
  differs (see Fonts).
- The current form (on-demand start from vrclient, Metal compositor through the OpenXR loader) is tested headless
  only (`tests/web-overlays`); the overlay session on WiVRn with a headset is not tested yet.
- At Alyx's startup map the game sends `end_loading` 0.23 s after "Press Trigger To Start", so that prompt is only
  visible on save loads, where the game waits for the trigger.

## Fonts

Alyx's `webui/fonts/raju-*.otf` (and SteamVR's own `motiva-sans-*.ttf`) are not plain font files: vrserver's
`get_font` decrypts them. The helper doesn't; the page then uses its CSS fallback (`"Raju", "Arial"`), so the text is
Arial. A plain `raju-*.otf` put into `~/Library/Application Support/OpenComposite/fonts/` is used instead (served by
the same `get_font` URL). That folder is inside the install directory, so `install.sh uninstall` deletes it.

## Render models (holograms): not done

The page also emits `rendermodel` nodes (OBJ + DDS from `set_paths.models`, e.g. `play_space_center_feet.obj` on every
loading screen and the city hologram in later maps) with tint, opacity (also negative), `fresnel {color, opacity,
strength}`, `wireframe`, `solid`, `culling`, `no-depth-write`, `texture-id`. They are parsed and counted in the log
but not drawn. vrcompositor draws them with its `geom_fresnel_vs` + `distort_geom_fresnel_ps` shaders (SteamVR ships
SPIR-V builds in `SteamVR/resources/shaders/vulkan/`: per-vertex fresnel term `1 − pow(|dot(V, N)|, k)`, colour =
texture × mix(colour A, colour B, fresnel)). Missing: which scene-graph property feeds which uniform, the blend state
for negative opacities, the render target; then an OBJ/DDS loader and a projection layer with depth in the same
overlay session.

## Tests

`tests/web-overlays/test-web-overlays.sh` (also in CI): `ovr_webroot` plays a game's side through the built
`vrclient.dylib` (RegisterMailbox, RegisterExternalWebRoot via slot 26, ReadMessage until ready) over a stub OpenXR
runtime (`stub_xr_runtime.c`: enough for VR_Init with Metal, no `XR_EXTX_overlay`), as arm64 and, under Rosetta, as
x86_64, with fake Wine variables in its environment. It checks that vrclient starts the broker with a clean
environment, the helper loads the page (`tests/web-overlays/webui`, which answers `ready` and publishes a panel), the
panel is captured, the helper reaches the runtime through the loader, both processes exit after the game, and that a
runtime without the broker gives upstream's fake ready. Port 27062 must be free.
