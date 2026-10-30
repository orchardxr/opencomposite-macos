#!/usr/bin/env bash
# Exercise scripts/install.sh against a throwaway HOME: fresh install, install next to an existing SteamVR entry,
# reinstall, and uninstall in both cases. Needs a built runtime (scripts/build.sh) or OPENCOMPOSITE_FROM.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="${INSTALL_SH:-$ROOT/scripts/install.sh}"
T="$(mktemp -d /tmp/oc-install-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT
cd "$T"
export HOME="$T"
unset OPENCOMPOSITE_HOME
VRPATH="$HOME/Library/Application Support/OpenVR/.openvr/openvrpaths.vrpath"
RT="$HOME/Library/Application Support/OpenComposite/runtime"
fail() { echo "FAIL: $*" >&2; exit 1; }
runtimes() { osascript -l JavaScript -e "JSON.parse(ObjC.unwrap(\$.NSString.stringWithContentsOfFileEncodingError('$VRPATH', 4, null))).runtime.join('|')"; }

echo "== fresh install"
"$INSTALL" install
[[ -f "$RT/bin/osx64/vrclient.dylib" && -e "$RT/bin/osx64/libopenxr_loader.dylib" ]] || fail "runtime not copied"
[[ "$(runtimes)" == "$RT" ]] || fail "vrpath runtime list: $(runtimes)"
"$INSTALL" status | grep -q "active:    yes" || fail "status not active"
if command -v clang > /dev/null; then
	printf '#include <dlfcn.h>\n#include <stdio.h>\nint main(int c,char**v){void*h=dlopen(v[1],RTLD_NOW);if(!h){puts(dlerror());return 1;}return !(dlsym(h,"VRClientCoreFactory")&&dlsym(h,"oc_metal_submit_sync_begin")&&dlsym(h,"oc_metal_submit_sync_end"));}\n' > "$T/dl.c"
	for arch in arm64 x86_64; do
		[[ "$arch" == x86_64 ]] && ! arch -x86_64 /usr/bin/true 2> /dev/null && continue
		clang -arch "$arch" -o "$T/dl-$arch" "$T/dl.c"
		arch "-$arch" "$T/dl-$arch" "$RT/bin/osx64/vrclient.dylib" || fail "dlopen of the installed vrclient.dylib ($arch)"
		echo "dlopen ok ($arch)"
	done
fi
echo "== uninstall (only entry)"
"$INSTALL" uninstall
[[ ! -e "$VRPATH" ]] || fail "vrpath left behind: $(cat "$VRPATH")"
[[ ! -e "$RT" ]] || fail "runtime left behind"

echo "== install next to SteamVR"
steamvr="$HOME/Library/Application Support/Steam/steamapps/common/SteamVR"
mkdir -p "$(dirname "$VRPATH")"
cat > "$VRPATH" <<JSON
{
	"config": [ "$HOME/Library/Application Support/Steam/config" ],
	"external_drivers": null,
	"jsonid": "vrpathreg",
	"log": [ "$HOME/Library/Application Support/Steam/logs" ],
	"runtime": [ "$steamvr" ],
	"version": 1
}
JSON
"$INSTALL" install
"$INSTALL" install
[[ "$(runtimes)" == "$RT|$steamvr" ]] || fail "vrpath runtime list after reinstall: $(runtimes)"
grep -q '"external_drivers": null' "$VRPATH" || fail "external_drivers lost"
grep -q 'Steam/config' "$VRPATH" || fail "config lost"
echo "== uninstall (SteamVR stays)"
"$INSTALL" uninstall
[[ "$(runtimes)" == "$steamvr" ]] || fail "vrpath runtime list after uninstall: $(runtimes)"
grep -q 'OpenComposite' "$VRPATH" && fail "OpenComposite still in vrpath"
echo "PASS"
