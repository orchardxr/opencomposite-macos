#!/usr/bin/env bash
# Install the OpenComposite runtime for the current user on macOS, or remove it again.
#   install.sh [install]          copy the runtime to $OPENCOMPOSITE_HOME/runtime; openvrpaths.vrpath is left alone
#   install.sh [install] --register  also register it first in openvrpaths.vrpath (for use without WiVRn)
#   install.sh unregister         remove our entry from openvrpaths.vrpath
#   install.sh uninstall          unregister, stop its web overlay processes, delete $OPENCOMPOSITE_HOME and its logs
#   install.sh status             show the registered runtimes and the installed version
#
# As on Linux, WiVRn's server registers the runtime in openvrpaths.vrpath while it runs and restores the file
# afterwards, so a plain install needs no registration.
#
# OPENCOMPOSITE_HOME   install location (default ~/Library/Application Support/OpenComposite)
# OPENCOMPOSITE_FROM   runtime to install (default: ./runtime next to this script in a release zip, else build/install/runtime)
# Other runtimes in openvrpaths.vrpath (e.g. SteamVR) are kept behind ours; uninstall leaves them in place.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${OPENCOMPOSITE_HOME:-$HOME/Library/Application Support/OpenComposite}"
VRPATH="$HOME/Library/Application Support/OpenVR/.openvr/openvrpaths.vrpath"
RUNTIME="$DEST/runtime"
WEB_LOGS="$HOME/Library/Logs/OpenComposite"

die() { echo "install.sh: $*" >&2; exit 1; }

# openvrpaths.vrpath is JSON; plutil (part of macOS) reads and edits it in place and keeps its nulls.
json_str() {
	local v="${1//\\/\\\\}"
	printf '"%s"' "${v//\"/\\\"}"
}

# Prints the strings of array <key>, one per line (nothing if absent).
vr_list() {
	local i=0 v
	[[ -f "$VRPATH" ]] || return 0
	while v="$(plutil -extract "$1.$i" raw -o - "$VRPATH" 2> /dev/null)"; do
		printf '%s\n' "$v"
		i=$((i + 1))
	done
}

# JSON array of the non-empty lines on stdin.
json_array() {
	local out="" line
	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		out+="${out:+,}$(json_str "$line")"
	done
	printf '[%s]' "$out"
}

vr_set() { # <key> <json>
	if plutil -type "$1" "$VRPATH" > /dev/null 2>&1; then
		plutil -replace "$1" -json "$2" "$VRPATH"
	else
		plutil -insert "$1" -json "$2" "$VRPATH"
	fi
}

ours() { [[ "$1" == "$DEST/"* ]]; }
same_runtime() { [[ "${1%"${1##*[!/]}"}" == "$RUNTIME" ]]; }
without() { # <predicate>: stdin lines for which it is false
	local line
	while IFS= read -r line; do "$1" "$line" || printf '%s\n' "$line"; done
}

vrpath() {
	local others config log
	case "$1" in
		list)
			vr_list runtime
			;;
		add)
			if [[ ! -f "$VRPATH" ]]; then
				mkdir -p "$(dirname "$VRPATH")"
				printf '{\n\t"config": [%s],\n\t"external_drivers": null,\n\t"jsonid": "vrpathreg",\n\t"log": [%s],\n\t"runtime": [%s],\n\t"version": 1\n}\n' \
					"$(json_str "$DEST/config")" "$(json_str "$DEST/logs")" "$(json_str "$RUNTIME")" > "$VRPATH"
				return
			fi
			others="$(vr_list runtime | without same_runtime)"
			vr_set runtime "$(printf '%s\n%s\n' "$RUNTIME" "$others" | json_array)"
			[[ -n "$(vr_list config)" ]] || vr_set config "$(echo "$DEST/config" | json_array)"
			[[ -n "$(vr_list log)" ]] || vr_set log "$(echo "$DEST/logs" | json_array)"
			plutil -type external_drivers "$VRPATH" > /dev/null 2>&1 || vr_set external_drivers null
			vr_set jsonid '"vrpathreg"'
			vr_set version 1
			plutil -convert json -r "$VRPATH"
			;;
		remove)
			others="$(vr_list runtime | without same_runtime)"
			config="$(vr_list config | without ours)"
			log="$(vr_list log | without ours)"
			# external_drivers null reads as type "(any)"
			if [[ -z "$others$config$log" ]] && [[ "$(plutil -type external_drivers "$VRPATH" 2> /dev/null || echo none)" =~ ^(\(any\)|none)$ ]]; then
				rm -f "$VRPATH"
				echo removed
				return
			fi
			vr_set runtime "$(printf '%s\n' "$others" | json_array)"
			if plutil -type config "$VRPATH" > /dev/null 2>&1; then vr_set config "$(printf '%s\n' "$config" | json_array)"; fi
			if plutil -type log "$VRPATH" > /dev/null 2>&1; then vr_set log "$(printf '%s\n' "$log" | json_array)"; fi
			plutil -convert json -r "$VRPATH"
			echo written
			;;
	esac
}

installed_version() {
	local v
	v="$(sed -n 's/^version=//p' "$RUNTIME/share/opencomposite/build-info" 2> /dev/null)"
	echo "${v:-?} ($(cat "$RUNTIME/bin/osx64/version.txt" 2> /dev/null || echo '?'))"
}

do_install() {
	local from="${OPENCOMPOSITE_FROM:-}"
	if [[ -z "$from" ]]; then
		if [[ -d "$HERE/runtime" ]]; then from="$HERE/runtime"; else from="$HERE/../build/install/runtime"; fi
	fi
	[[ -f "$from/bin/osx64/vrclient.dylib" ]] || die "no runtime at $from (build it with scripts/build.sh)"
	from="$(cd "$from" && pwd)"
	[[ "$from" != "$RUNTIME" ]] || die "source and destination are the same: $from"
	mkdir -p "$DEST/config" "$DEST/logs"
	rm -rf "$RUNTIME.new"
	cp -R "$from" "$RUNTIME.new"
	xattr -dr com.apple.quarantine "$RUNTIME.new" 2> /dev/null || true
	local f
	for f in "$RUNTIME.new/bin/osx64/vrclient.dylib" "$RUNTIME.new"/libexec/opencomposite/*; do
		[[ -e "$f" ]] || continue
		codesign --verify "$f" || die "${f#"$RUNTIME.new/"} is not validly signed"
	done
	rm -rf "$RUNTIME"
	mv "$RUNTIME.new" "$RUNTIME"
	echo "installed $(installed_version) to $RUNTIME"
	if [[ "$1" == register ]]; then
		vrpath add > /dev/null
		echo "registered in $VRPATH"
	elif registered; then
		echo "still registered in $VRPATH (earlier install); ./install.sh unregister leaves that to WiVRn"
	else
		echo "not registered: WiVRn activates OpenComposite while it runs"
	fi
}

registered() {
	local r
	while IFS= read -r r; do same_runtime "$r" && return 0; done < <(vrpath list)
	return 1
}

do_unregister() {
	registered || return 0
	case "$(vrpath remove)" in
		removed) echo "removed $VRPATH (nothing else was registered)" ;;
		*) echo "unregistered from $VRPATH" ;;
	esac
}

do_uninstall() {
	do_unregister
	if pkill -f "$RUNTIME/libexec/opencomposite/oc-web" 2> /dev/null; then
		echo "stopped the web overlay broker"
	fi
	if [[ -d "$DEST" ]]; then
		rm -rf "$DEST"
		echo "deleted $DEST"
	fi
	if [[ -d "$WEB_LOGS" ]]; then
		rm -rf "$WEB_LOGS"
		echo "deleted $WEB_LOGS"
	fi
}

do_status() {
	echo "vrpath:   $VRPATH"
	if [[ -f "$VRPATH" ]]; then
		vrpath list | sed 's/^/  runtime: /'
	else
		echo "  (none)"
	fi
	if [[ -f "$RUNTIME/bin/osx64/vrclient.dylib" ]]; then
		echo "installed: $RUNTIME ($(installed_version))"
		if same_runtime "$(vrpath list | head -1)"; then
			echo "active:    yes"
		elif registered; then
			echo "active:    no (another runtime is listed first)"
		else
			echo "active:    no (not registered; WiVRn activates OpenComposite while it runs)"
		fi
		if pgrep -f "$RUNTIME/libexec/opencomposite/oc-webbroker" > /dev/null; then
			echo "web overlays: broker running (log $WEB_LOGS/web-overlays.log)"
		fi
	else
		echo "installed: no"
	fi
}

usage="usage: install.sh [install] [--register] | unregister | uninstall | status"
cmd="" register=""
for arg in "$@"; do
	case "$arg" in
		--register) register=register ;;
		install | unregister | uninstall | status) [[ -z "$cmd" ]] || die "$usage"; cmd="$arg" ;;
		*) die "$usage" ;;
	esac
done
cmd="${cmd:-install}"
[[ -z "$register" || "$cmd" == install ]] || die "$usage"
case "$cmd" in
	install) do_install "$register" ;;
	unregister) do_unregister ;;
	uninstall) do_uninstall ;;
	status) do_status ;;
esac
