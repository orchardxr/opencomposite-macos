# opencomposite-macos

Native macOS [OpenComposite](https://gitlab.com/znixian/OpenOVR): an OpenVR runtime that translates OpenVR to
OpenXR, with a Metal compositor. Install it once and OpenVR games on your Mac use it as their VR runtime, the way
OpenComposite is used on Linux.

Part of orchardxr: vibe-coded support for VR on macOS: native and Windows games, on Apple Silicon, streamed via WiVRn.

## What works

- **Windows games** reach this runtime through [orchardxr/varbor](https://github.com/orchardxr/varbor).
- **Native macOS OpenVR games** that submit Metal textures (`vr::TextureType_Metal`) use it directly. This path is
  barely tested so far.
- **Web overlays** (e.g. loading screens) like SteamVR's vrwebhelper: games that draw parts of their UI as a web
  page, such as Half-Life: Alyx's loading screens, get them rendered and shown in the headset. Started automatically
  when a game needs them; see [docs/web-overlays.md](docs/web-overlays.md).
- **Output** goes to WiVRn's server from [orchardxr/wivrn-macos](https://github.com/orchardxr/wivrn-macos), which
  streams to any WiVRn-supported headset (tested on Quest 3S).

## Requirements

- A Mac with Apple Silicon. The runtime is universal (arm64 + x86_64), so x86_64 games running under Rosetta can load
  it too.
- An OpenXR runtime with Metal support (`XR_KHR_metal_enable`): the WiVRn server from orchardxr/wivrn-macos.
- For Windows games: orchardxr/varbor.

## Install

1. Download `opencomposite-macos-<version>.zip` from the
   [releases](https://github.com/orchardxr/opencomposite-macos/releases) and unzip it.
2. In Terminal, in the unzipped folder:

   ```sh
   ./install.sh
   ```

The runtime goes to `~/Library/Application Support/OpenComposite` and is registered as your OpenVR runtime in
`~/Library/Application Support/OpenVR/.openvr/openvrpaths.vrpath`. Any other runtime that is registered there
(SteamVR) stays in the file, behind this one. Nothing needs admin rights.

```sh
./install.sh status       # which runtime is active, installed version
./install.sh uninstall    # unregister, delete ~/Library/Application Support/OpenComposite and its logs
```

To update, run `./install.sh` from the new release.

## Limitations

- Native macOS OpenVR games are barely tested. Only Metal texture submits are supported for them.
- While installed, this runtime comes first: OpenVR apps load it rather than SteamVR. Uninstall to switch back.
- The binaries are ad-hoc signed, not notarized. `install.sh` clears the download quarantine on the files it installs.
- Without a running OpenXR runtime with Metal support, games see no headset.
- Web overlays: so far tested end to end only in an earlier form; Alyx's holograms (3D render models) and its
  encrypted fonts are not supported (the text falls back to Arial). Log: `~/Library/Logs/OpenComposite/web-overlays.log`.

## License

- OpenComposite and our patches to it (`patches/opencomposite`) are GPL-3.0, as upstream
  (`third_party/opencomposite/LICENSE.txt`). The built `vrclient.dylib` is GPL-3.0. Release zips include the licences,
  and the corresponding source is the tagged commit of this repo (submodule pins plus patches).
- The bundled OpenXR loader is Apache-2.0 (`third_party/openxr-sdk/LICENSE`).
- Everything else here (scripts, CI, tests, docs) is MIT, see `LICENSE`.

## Development

Building from source, the repository layout, the patch stack, tests, CI and releases are covered in
[docs/development.md](docs/development.md).
