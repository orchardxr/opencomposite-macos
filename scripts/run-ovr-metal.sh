#!/usr/bin/env bash
# Run the native Metal OpenVR test app (tests/openvr-metal) through this OpenComposite against an OpenXR runtime that
# has XR_KHR_metal_enable (Monado with the Metal patch from orchardxr/wivrn-macos).
#   scripts/run-ovr-metal.sh <runtime json> [seconds] [mode]     (default 30 separate; modes: see tests/openvr-metal)
#
# <runtime json> is the OpenXR runtime manifest (e.g. <monado build>/openxr_monado-dev.json); it becomes XR_RUNTIME_JSON.
# Environment:
#   MONADO_SERVICE=<path>  start this monado-service (null compositor, simulated HMD) with a private XDG_RUNTIME_DIR for
#                          the run and stop it afterwards. Unset: the runtime's service must already be running.
#   RUNTIME=<dir>          the OpenVR runtime to load (default build/install/runtime)
#   APP=<path>             the test binary (default build/tests/ovr_metal)
#   OUT=<dir>              logs and the frame dump (default build/logs/ovr-metal)
#   DUMP_FRAME=N           which committed frame the null compositor writes to $OUT/frame-<mode>.png (default 300)
#   MTL_DEBUG_LAYER=1      Metal API validation in the app (passed through)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[[ $# -ge 1 ]] || { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
json="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
[[ -f "$json" ]] || { echo "no runtime manifest: $1" >&2; exit 1; }
secs="${2:-30}"
mode="${3:-separate}"
RUNTIME="${RUNTIME:-$ROOT/build/install/runtime}"
APP="${APP:-$ROOT/build/tests/ovr_metal}"
OUT="${OUT:-$ROOT/build/logs/ovr-metal}"
[[ -f "$RUNTIME/bin/osx64/vrclient.dylib" ]] || { echo "no $RUNTIME/bin/osx64/vrclient.dylib (scripts/build.sh)" >&2; exit 1; }
[[ -x "$APP" ]] || { echo "no test app $APP (scripts/build.sh)" >&2; exit 1; }
mkdir -p "$OUT"
alog="$OUT/ovr_metal-$mode.log"
slog="$OUT/service-$mode.log"
png="$OUT/frame-$mode.png"
rm -f "$png"

timeout_run() { perl -e 'alarm shift; exec @ARGV' "$@"; }

spid=
if [[ -n "${MONADO_SERVICE:-}" ]]; then
	moltenvk=/opt/homebrew/opt/molten-vk/etc/vulkan/icd.d/MoltenVK_icd.json
	[[ -n "${VK_DRIVER_FILES:-}" || ! -f "$moltenvk" ]] || export VK_DRIVER_FILES="$moltenvk"
	mkdir -p "$OUT/rt"
	export XDG_RUNTIME_DIR="$OUT/rt" MONADO_SYNC_STATS=1
	sock="$XDG_RUNTIME_DIR/monado_comp_ipc"
	rm -f "$sock"
	(
		export XRT_NO_STDIN=1 XRT_COMPOSITOR_NULL=1 SIMULATED_ENABLE=1
		export XRT_COMPOSITOR_NULL_DUMP="$png" XRT_COMPOSITOR_NULL_DUMP_FRAME="${DUMP_FRAME:-300}"
		exec perl -e 'alarm shift; exec @ARGV' $((secs + 60)) "$MONADO_SERVICE"
	) > "$slog" 2>&1 &
	spid=$!
	for _ in $(seq 50); do
		[[ -S "$sock" ]] && break
		sleep 0.1
	done
	[[ -S "$sock" ]] || { echo "service did not create $sock"; cat "$slog"; kill "$spid" 2>/dev/null; exit 1; }
fi

set +e
(cd "$OUT" && XR_RUNTIME_JSON="$json" timeout_run $((secs + 30)) "$APP" "$RUNTIME" "$secs" "$mode") > "$alog" 2>&1
rc=$?
set -e

src=0
if [[ -n "$spid" ]]; then
	kill -INT "$spid" 2>/dev/null
	wait "$spid" || src=$?
fi

tail -3 "$alog"
echo "app exit code $rc, log $alog"
if [[ -n "$spid" ]]; then
	echo "service exit code $src, log $slog"
	grep -E "layer commits|Frame dump|sync-stats" "$slog" || true
	echo "service errors: $(grep -c ' ERROR \|ERROR \[' "$slog" || true)"
fi
echo "app errors: $(grep -ciE '^\[OC\].*(error|abort|fail)|failed assertion|failed:' "$alog" || true)"
[[ -f "$png" ]] && echo "frame dump: $png"
exit $((rc != 0 ? rc : src))
