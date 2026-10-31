# opencomposite-macos

Native macOS [OpenComposite](https://gitlab.com/znixian/OpenOVR): an OpenVR runtime that translates OpenVR to
OpenXR, with a Metal compositor. Install it once, and while WiVRn's server runs, OpenVR games on your Mac use it as
their VR runtime, the way OpenComposite is used on Linux.

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

The runtime goes to `~/Library/Application Support/OpenComposite`. Nothing needs admin rights.

WiVRn activates OpenComposite while it runs, like on Linux: when its server starts, it makes OpenComposite your
OpenVR runtime (in `~/Library/Application Support/OpenVR/.openvr/openvrpaths.vrpath`), and when it stops, it puts
the file back as it was. So SteamVR, if you have it, is untouched while WiVRn isn't running. This needs a WiVRn
release from orchardxr/wivrn-macos with the OpenVR library setting; it finds this install by itself.

Using OpenComposite without WiVRn, or with an older WiVRn? Register it yourself:

```sh
./install.sh --register   # install and make it the OpenVR runtime permanently (other runtimes stay behind it)
./install.sh unregister   # take that registration out again
```

```sh
./install.sh status       # installed version, which runtime is registered
./install.sh uninstall    # remove our registration if any, delete ~/Library/Application Support/OpenComposite and its logs
```

To update, run `./install.sh` from the new release. Updating from 0.1.0 keeps that version's registration; run
`./install.sh unregister` once to leave it to WiVRn.

## Limitations

- Native macOS OpenVR games are barely tested. Only Metal texture submits are supported for them.
- With `--register`, this runtime comes first: OpenVR apps load it rather than SteamVR. Run
  `./install.sh unregister` to switch back.
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
