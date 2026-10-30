#!/usr/bin/env bash
# Install OpenComposite as the user's shared OpenVR runtime on macOS, or remove it again.
#   install.sh [install]    copy the runtime to $OPENCOMPOSITE_HOME/runtime and register it first in openvrpaths.vrpath
#   install.sh uninstall    unregister it and delete $OPENCOMPOSITE_HOME
#   install.sh status       show the registered runtimes and the installed version
#
# OPENCOMPOSITE_HOME   install location (default ~/Library/Application Support/OpenComposite)
# OPENCOMPOSITE_FROM   runtime to install (default: ./runtime next to this script in a release zip, else build/install/runtime)
# Other runtimes in openvrpaths.vrpath (e.g. SteamVR) are kept behind ours; uninstall leaves them in place.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${OPENCOMPOSITE_HOME:-$HOME/Library/Application Support/OpenComposite}"
VRPATH="$HOME/Library/Application Support/OpenVR/.openvr/openvrpaths.vrpath"
RUNTIME="$DEST/runtime"

die() { echo "install.sh: $*" >&2; exit 1; }

# Edits the vrpath with JavaScript for Automation (always present on macOS); plutil can't hold the file's nulls.
vrpath() {
	local js
	js="$(mktemp -t oc-vrpath).js"
	cat > "$js" <<'JS'
ObjC.import('Foundation');
function run(argv) {
	const [file, op, rt, base] = argv;
	const fm = $.NSFileManager.defaultManager;
	let j = {};
	if (fm.fileExistsAtPath(file)) {
		const s = $.NSString.stringWithContentsOfFileEncodingError(file, $.NSUTF8StringEncoding, null);
		j = JSON.parse(ObjC.unwrap(s));
	}
	const runtimes = (Array.isArray(j.runtime) ? j.runtime : []).filter(r => r.replace(/\/+$/, '') !== rt);
	if (op === 'list')
		return (Array.isArray(j.runtime) ? j.runtime : []).join('\n');
	if (op === 'add') {
		j.runtime = [rt, ...runtimes];
		if (!Array.isArray(j.config) || !j.config.length) j.config = [base + '/config'];
		if (!Array.isArray(j.log) || !j.log.length) j.log = [base + '/logs'];
		if (!('external_drivers' in j)) j.external_drivers = null;
		j.jsonid = 'vrpathreg';
		j.version = 1;
	} else if (op === 'remove') {
		j.runtime = runtimes;
		const ours = p => typeof p === 'string' && p.startsWith(base + '/');
		if (Array.isArray(j.config)) j.config = j.config.filter(p => !ours(p));
		if (Array.isArray(j.log)) j.log = j.log.filter(p => !ours(p));
		if (!runtimes.length && !(j.config || []).length && !(j.log || []).length && !j.external_drivers) {
			fm.removeItemAtPathError(file, null);
			return 'removed';
		}
	} else {
		throw new Error('bad op ' + op);
	}
	fm.createDirectoryAtPathWithIntermediateDirectoriesAttributesError($(file).stringByDeletingLastPathComponent, true, $(), null);
	if (!$(JSON.stringify(j, null, '\t') + '\n').writeToFileAtomicallyEncodingError(file, true, $.NSUTF8StringEncoding, null))
		throw new Error('cannot write ' + file);
	return 'written';
}
JS
	osascript -l JavaScript "$js" "$VRPATH" "$1" "$RUNTIME" "$DEST"
	rm -f "$js"
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
	codesign --verify "$RUNTIME.new/bin/osx64/vrclient.dylib" || die "vrclient.dylib is not validly signed"
	rm -rf "$RUNTIME"
	mv "$RUNTIME.new" "$RUNTIME"
	vrpath add > /dev/null
	echo "installed $(cat "$RUNTIME/bin/osx64/version.txt" 2> /dev/null || echo '?') to $RUNTIME"
	echo "registered in $VRPATH"
}

do_uninstall() {
	if [[ -f "$VRPATH" ]]; then
		case "$(vrpath remove)" in
			removed) echo "removed $VRPATH (nothing else was registered)" ;;
			*) echo "unregistered from $VRPATH" ;;
		esac
	fi
	if [[ -d "$DEST" ]]; then
		rm -rf "$DEST"
		echo "deleted $DEST"
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
		echo "installed: $RUNTIME ($(cat "$RUNTIME/bin/osx64/version.txt" 2> /dev/null || echo '?'))"
		[[ "$(vrpath list | head -1)" == "$RUNTIME" ]] && echo "active:    yes" || echo "active:    no (another runtime is listed first)"
	else
		echo "installed: no"
	fi
}

case "${1:-install}" in
	install) do_install ;;
	uninstall) do_uninstall ;;
	status) do_status ;;
	*) die "usage: install.sh [install|uninstall|status]" ;;
esac
