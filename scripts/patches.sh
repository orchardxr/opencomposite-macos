#!/usr/bin/env bash
# Manage third_party/opencomposite and our staged (never committed) patch stack in patches/opencomposite.
#
#   patches.sh apply           reset to the pin, then git apply --index every patch
#   patches.sh reset           reset to the pin, no patches
#   patches.sh status          pin, HEAD, patch count, staged/unstaged summary
#   patches.sh new <NNNN-name|name>
#                              export unstaged changes + untracked files as the next patch, then stage them
#
# The pin is the submodule commit recorded in this repo's index (bump it with
# `git add third_party/opencomposite` after checking out the new upstream commit).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
P=opencomposite
PATCHES="$ROOT/patches/$P"
SRC="$ROOT/third_party/$P"

die() { echo "patches.sh: $*" >&2; exit 1; }
log() { echo "==> $*"; }
oc() { git -C "$SRC" "$@"; }

pin() { git -C "$ROOT" ls-files -s -- "third_party/$P" | awk '$1 == "160000" { print $2 }'; }

check() {
	[[ -n "$(pin)" ]] || die "third_party/$P is not a submodule"
	[[ -e "$SRC/.git" ]] || die "third_party/$P is not checked out (git submodule update --init --recursive)"
}

do_reset() {
	local base
	check
	base="$(pin)"
	oc cat-file -e "$base^{commit}" 2>/dev/null || oc fetch -q origin "$base"
	log "$P: reset to $base"
	oc am --abort >/dev/null 2>&1 || true
	oc checkout -q --detach -f "$base"
	oc reset -q --hard "$base"
	oc clean -q -fdx
	git -C "$ROOT" submodule update -q --init --recursive "third_party/$P"
}

do_apply() {
	local f n=0
	do_reset
	shopt -s nullglob
	for f in "$PATCHES"/*.patch; do
		echo "    apply ${f#"$ROOT"/}"
		oc apply --index --whitespace=nowarn "$f" || die "failed to apply $f"
		n=$((n + 1))
	done
	shopt -u nullglob
	log "$P: $n patches staged"
}

do_status() {
	local base head
	check
	base="$(pin)"
	head="$(oc rev-parse HEAD)"
	echo "== $P"
	echo "   pin  $base"
	if [[ "$head" == "$base" ]]; then
		echo "   HEAD at pin"
	else
		echo "   HEAD $head  (NOT at pin)"
	fi
	echo "   our patches: $(find "$PATCHES" -maxdepth 1 -name '*.patch' | wc -l | tr -d ' ')"
	echo "   staged:   $(oc diff --cached --shortstat || true)"
	echo "   unstaged: $(oc diff --shortstat || true)"
	echo "   untracked files: $(oc ls-files --others --exclude-standard | wc -l | tr -d ' ')"
}

do_new() {
	local name="${1%.patch}" last num file
	check
	if [[ ! "$name" =~ ^[0-9]{4}- ]]; then
		last=$(find "$PATCHES" -maxdepth 1 -name '[0-9][0-9][0-9][0-9]-*.patch' -exec basename {} \; | sort | tail -n1)
		num=1
		[[ -z "$last" ]] || num=$((10#${last:0:4} + 1))
		name="$(printf '%04d' "$num")-$name"
	fi
	file="$PATCHES/$name.patch"
	[[ ! -e "$file" ]] || die "$file already exists"

	oc ls-files -z --others --exclude-standard | xargs -0 -r git -C "$SRC" add -N --
	oc diff --quiet && die "no unstaged changes to export"
	{
		echo "From: opencomposite-macos"
		echo "Subject: [PATCH] ${name#[0-9][0-9][0-9][0-9]-}"
		echo
		echo "---"
		oc diff --stat
		echo
		oc diff --binary --full-index
	} > "$file"
	oc add -A
	log "wrote ${file#"$ROOT"/} and staged it"
}

case "${1:-}" in
	apply) do_apply ;;
	reset) do_reset ;;
	status) do_status ;;
	new)
		[[ $# -eq 2 ]] || die "usage: patches.sh new <name>"
		do_new "$2"
		;;
	*) die "usage: patches.sh {apply|reset|status|new <name>}" ;;
esac
