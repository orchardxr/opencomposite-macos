#!/usr/bin/env bash
# Headless web overlay test: a game's side (tests/web-overlays/ovr_webroot.cpp) loads the runtime's vrclient.dylib over
# a stub OpenXR runtime (stub_xr_runtime.c), registers a mailbox and a web root. Checks that vrclient starts
# oc-webbroker on demand with a clean environment, that oc-webhelper loads the page (which answers "ready" and
# publishes a panel), that both exit after the game, and that without a broker the game gets upstream's fake ready.
# The overlay session itself needs WiVRn with a headset and is not tested (the stub has no XR_EXTX_overlay).
#   tests/web-overlays/test-web-overlays.sh
# RUNTIME=<dir>  runtime to test (default build/install/runtime). Needs port 27062 free (no other broker running).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNTIME="${RUNTIME:-$ROOT/build/install/runtime}"
WEBROOT="$ROOT/tests/web-overlays/webui"
OUT="$ROOT/build/tests/web-overlays"
fails=0

fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
pass() { echo "ok:   $*"; }
running() { pgrep -f "libexec/opencomposite/$1" > /dev/null; }

[[ -f "$RUNTIME/bin/osx64/vrclient.dylib" ]] || { echo "no $RUNTIME (scripts/build.sh)" >&2; exit 1; }
if running oc-webbroker || lsof -nP -iTCP:27062 -sTCP:LISTEN > /dev/null 2>&1; then
	echo "port 27062 is in use (a broker is running): stop it first" >&2
	exit 1
fi
rm -rf "$OUT"
mkdir -p "$OUT/home"

inc=(-I"$ROOT/build/openxr-loader/include" -I"$ROOT/third_party/openxr-sdk/include")
clang -O1 -g -Wall -arch arm64 -arch x86_64 -dynamiclib "${inc[@]}" -framework Metal \
	-o "$OUT/libstub_xr_runtime.dylib" "$ROOT/tests/web-overlays/stub_xr_runtime.c"
clang++ -std=c++17 -O1 -g -Wall -arch arm64 -arch x86_64 -o "$OUT/ovr_webroot" "$ROOT/tests/web-overlays/ovr_webroot.cpp"
cat > "$OUT/stub.json" << EOF
{ "file_format_version": "1.0.0", "runtime": { "name": "stub", "library_path": "$OUT/libstub_xr_runtime.dylib" } }
EOF

# A game in Wine carries Wine/CrossOver variables; none of them may reach the broker.
game_env=(env HOME="$OUT/home" XR_RUNTIME_JSON="$OUT/stub.json" WINEPREFIX=/nonexistent/prefix CX_ROOT=/nonexistent/cx
	DYLD_FALLBACK_LIBRARY_PATH=/nonexistent/lib)
log="$OUT/home/Library/Logs/OpenComposite/web-overlays.log"

wait_gone() {
	for _ in $(seq 100); do
		running oc-webbroker || running oc-webhelper || return 0
		sleep 0.1
	done
	return 1
}

run_game() { # <arch> <runtime> <name>
	local arch="$1" rt="$2" name="$3"
	local envfile="$OUT/$name.broker-env"
	(
		while ! running oc-webbroker; do sleep 0.05; done
		ps eww -o command= -p "$(pgrep -f libexec/opencomposite/oc-webbroker | head -1)" > "$envfile" 2> /dev/null || true
	) &
	local watcher=$!
	set +e
	"${game_env[@]}" OC_WEB_DUMP="$OUT/$name-dump" perl -e 'alarm shift; exec @ARGV' 60 \
		arch "-$arch" "$OUT/ovr_webroot" "$rt" "$WEBROOT" 15 > "$OUT/$name.log" 2>&1
	local rc=$?
	set -e
	kill "$watcher" 2> /dev/null || true
	wait "$watcher" 2> /dev/null || true
	return $rc
}

scenario() { # <arch>
	local arch="$1" name="game-$1"
	echo "== $arch"
	if run_game "$arch" "$RUNTIME" "$name"; then pass "$arch: the page's ready reached the game"; else fail "$arch: no ready (see $OUT/$name.log)"; fi
	grep -E "RegisterMailbox|RegisterExternalWebRoot\(|page ready" "$OUT/$name.log" | sed 's/^/      /'
	grep -q "Started web overlay broker" "$OUT/$name.log" && pass "$arch: vrclient started the broker" \
		|| fail "$arch: vrclient did not start the broker"
	if [[ -s "$OUT/$name.broker-env" ]]; then
		if grep -qE "WINE|CX_|DYLD_" "$OUT/$name.broker-env"; then fail "$arch: Wine/DYLD variables reached the broker"; else pass "$arch: clean broker environment"; fi
	else
		fail "$arch: broker environment not captured"
	fi
	grep -q "\[webhelper\] interstitials: loaded" "$log" && pass "$arch: helper loaded the page" || fail "$arch: helper did not load the page"
	ls "$OUT/$name-dump"/interstitials-*.png > /dev/null 2>&1 && pass "$arch: panel captured" || fail "$arch: no panel capture"
	grep -q "runtime lacks XR_EXTX_overlay" "$log" && pass "$arch: helper reached the OpenXR runtime via the loader (stub has no overlay)" \
		|| fail "$arch: helper did not reach the stub runtime"
	if wait_gone; then pass "$arch: broker and helper exited after the game"; else fail "$arch: broker or helper still running"; fi
	mv "$log" "$OUT/$name.web-overlays.log" 2> /dev/null || true
}

scenario arm64
if arch -x86_64 /usr/bin/true 2> /dev/null; then scenario x86_64; else echo "== x86_64: no Rosetta, skipped"; fi

echo "== no broker"
nob="$OUT/runtime-without-broker"
cp -R "$RUNTIME" "$nob"
rm -rf "$nob/libexec"
run_game arm64 "$nob" no-broker || true
grep -q "fake ready: no broker" "$OUT/no-broker.log" && pass "no broker: upstream's fake ready" || fail "no broker: no fake ready"
running oc-webbroker && fail "no broker: a broker is running" || true

pkill -f libexec/opencomposite/oc-web 2> /dev/null || true
echo "logs: $OUT"
((fails == 0)) && echo "PASS" || { echo "$fails failure(s)"; exit 1; }
