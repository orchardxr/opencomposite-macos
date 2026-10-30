#!/usr/bin/env bash
# Build native macOS OpenComposite (Metal compositor, XR_KHR_metal_enable) as a universal OpenVR runtime.
#   scripts/patches.sh apply && scripts/build.sh [--no-test]
#
# Output (build/):
#   install/runtime/bin/osx64/vrclient.dylib            universal (arm64 + x86_64), ad-hoc signed
#   install/runtime/bin/osx64/libopenxr_loader.dylib    universal OpenXR loader (openxr-sdk 1.1.65), found via @loader_path
#   install/runtime/bin/osx64/version.txt
#   install/runtime/share/opencomposite/build-info                    version=<VERSION>, commit, upstream, patches
#   install/runtime/libexec/opencomposite/oc-webbroker, oc-webhelper   web overlays (arm64, Swift), ad-hoc signed
#   tests/ovr_metal                                      arm64 test app (tests/openvr-metal), unless --no-test
# Environment: VULKAN_INCLUDE (Vulkan headers dir), OC_RELEASE (version label, default git describe; a v<x.y.z> tag must match VERSION), BUILD_TYPE (default RelWithDebInfo), NINJA_FLAGS.
# ccache is used when found.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/build"
LOGS="$OUT/logs"
BT="${BUILD_TYPE:-RelWithDebInfo}"
ARCHS=(arm64 x86_64)
build_test=1
[[ "${1:-}" == --no-test ]] && build_test=0
mkdir -p "$LOGS"

if command -v ccache > /dev/null; then
	for l in C CXX OBJC OBJCXX; do
		v="CMAKE_${l}_COMPILER_LAUNCHER"
		export "$v=${!v:-ccache}"
	done
	export CCACHE_SLOPPINESS="${CCACHE_SLOPPINESS:-include_file_mtime,include_file_ctime,time_macros,pch_defines}"
	export CCACHE_COMPILERCHECK="${CCACHE_COMPILERCHECK:-content}"
fi

run() {
	local log="$LOGS/$1.log"
	shift
	"$@" > "$log" 2>&1 || { grep -E "error|FAILED|Error" "$log" | head -30 || tail -30 "$log"; echo "failed, see $log" >&2; exit 1; }
}

src="$ROOT/third_party/opencomposite"
[[ -f "$src/DrvOpenXR/tmp_gfx/TemporaryMetal.cpp" ]] || { echo "patches not applied: run scripts/patches.sh apply" >&2; exit 1; }
oc_rev="$(git -C "$src" rev-parse --short HEAD)"
our_rev="${OC_RELEASE:-$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || echo unknown)}"
release="$(cat "$ROOT/VERSION")"
[[ "$release" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "VERSION is not x.y.z: $release" >&2; exit 1; }
[[ "${OC_RELEASE:-}" != v* || "$OC_RELEASE" == "v$release" ]] || { echo "tag $OC_RELEASE does not match VERSION $release" >&2; exit 1; }
version="$oc_rev opencomposite-macos $our_rev"

# Homebrew is ignored as a prefix, so name the Vulkan headers dir: VULKAN_INCLUDE, the LunarG SDK, or vulkan-headers.
vk_inc=""
for d in "${VULKAN_INCLUDE:-}" /usr/local/include "$(brew --prefix vulkan-headers 2>/dev/null)/include"; do
	[[ -n "$d" && -f "$d/vulkan/vulkan.h" ]] && { vk_inc="$d"; break; }
done
[[ -n "$vk_inc" ]] || { echo "no Vulkan headers: brew install vulkan-headers or set VULKAN_INCLUDE" >&2; exit 1; }

echo "==> openxr-loader (universal)"
run loader-configure cmake -S "$ROOT/third_party/openxr-sdk" -B "$OUT/openxr-loader" -G Ninja -DCMAKE_BUILD_TYPE="$BT" \
	-DCMAKE_OSX_ARCHITECTURES="$(IFS=';'; echo "${ARCHS[*]}")" -DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew -DDYNAMIC_LOADER=ON \
	-DBUILD_TESTS=OFF -DBUILD_API_LAYERS=OFF -DBUILD_CONFORMANCE_TESTS=OFF -DBUILD_WITH_SYSTEM_JSONCPP=OFF
run loader-build ninja -C "$OUT/openxr-loader" openxr_loader
loader="$OUT/openxr-loader/src/loader"

# One build per architecture: CMake's precompiled headers don't do multi-arch builds.
for arch in "${ARCHS[@]}"; do
	echo "==> opencomposite ($arch)"
	run "oc-$arch-configure" cmake -S "$src" -B "$OUT/oc-$arch" -G Ninja -DCMAKE_BUILD_TYPE="$BT" \
		-DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew -DOC_VERSION="$version" \
		-DOC_VULKAN_INCLUDE_DIR="$vk_inc" \
		-DOC_OPENXR_INCLUDE_DIRS="$OUT/openxr-loader/include;$ROOT/third_party/openxr-sdk/include" \
		-DOC_OPENXR_LIBRARY="$loader/libopenxr_loader.dylib" \
		-DCMAKE_SHARED_LINKER_FLAGS="-Wl,-rpath,@loader_path" -DCMAKE_SKIP_BUILD_RPATH=ON
	# shellcheck disable=SC2086
	run "oc-$arch-build" ninja -C "$OUT/oc-$arch" ${NINJA_FLAGS:-}
done

echo "==> web overlays (arm64)"
web_build="$OUT/web-overlays"
run web-overlays swift build -c release --arch arm64 --package-path "$ROOT/web-overlays" --build-path "$web_build"
web_bin="$(swift build -c release --arch arm64 --package-path "$ROOT/web-overlays" --build-path "$web_build" --show-bin-path)"

echo "==> install tree"
bin="$OUT/install/runtime/bin/osx64"
rm -rf "$OUT/install"
mkdir -p "$bin"
lipo -create -output "$bin/vrclient.dylib" $(for a in "${ARCHS[@]}"; do echo "$OUT/oc-$a/bin/osx64/vrclient.dylib"; done)
# vrclient links the loader by its install name (@rpath/libopenxr_loader.1.dylib); ship one real file under that name
# and the unversioned name the README and installers refer to.
loader_name="$(otool -D "$loader/libopenxr_loader.dylib" | tail -1)"
loader_name="${loader_name##*/}"
cp -L "$loader/libopenxr_loader.dylib" "$bin/$loader_name"
[[ "$loader_name" == libopenxr_loader.dylib ]] || ln -s "$loader_name" "$bin/libopenxr_loader.dylib"
echo "$version" > "$bin/version.txt"
share="$OUT/install/runtime/share/opencomposite"
mkdir -p "$share"
{
	echo "version=$release"
	echo "commit=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
	echo "describe=$our_rev"
	echo "opencomposite=$(git -C "$src" rev-parse HEAD)"
	echo "openxr-loader=$(git -C "$ROOT/third_party/openxr-sdk" describe --tags --always 2>/dev/null || echo unknown)"
	echo "patches=$(cd "$ROOT/patches/opencomposite" && ls *.patch | sed 's/\.patch$//' | tr '\n' ' ' | sed 's/ $//')"
	echo "built=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$share/build-info"
codesign --force --sign - "$bin/$loader_name" "$bin/vrclient.dylib"

libexec="$OUT/install/runtime/libexec/opencomposite"
mkdir -p "$libexec"
for exe in oc-webbroker oc-webhelper; do
	cp "$web_bin/$exe" "$libexec/"
	# Drop the toolchain's absolute rpaths; the helper finds the loader via @executable_path/../../bin/osx64.
	otool -l "$libexec/$exe" | awk '$1 == "path" && $2 ~ /^\// && $2 != "/usr/lib/swift" { print $2 }' | while read -r rp; do
		install_name_tool -delete_rpath "$rp" "$libexec/$exe" 2> /dev/null
	done
	codesign --force --sign - "$libexec/$exe"
done

for f in "$bin/vrclient.dylib" "$bin/$loader_name" "$libexec"/*; do
	lipo -info "$f"
done
otool -L -arch arm64 "$bin/vrclient.dylib" | tail -n +2
nm -gU "$bin/vrclient.dylib" | grep -E ' _(VRClientCoreFactory|oc_metal_submit_sync_(begin|end))$' || {
	echo "missing exports in vrclient.dylib" >&2
	exit 1
}

if ((build_test)); then
	echo "==> ovr_metal"
	mkdir -p "$OUT/tests/include"
	cp "$src/OpenVRHeaders/openvr-2.15.6.h" "$OUT/tests/include/openvr.h"
	clang++ -std=c++17 -fobjc-arc -O1 -g -Wall -arch arm64 -I"$OUT/tests/include" \
		-o "$OUT/tests/ovr_metal" "$ROOT/tests/openvr-metal/ovr_metal.mm" -framework Metal -framework Foundation
fi
echo "==> done: $OUT/install/runtime ($version)"
