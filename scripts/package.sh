#!/usr/bin/env bash
# Zip the install tree from scripts/build.sh with the installer and the licences.
#   scripts/package.sh <name>     -> build/dist/<name>.zip containing <name>/{install.sh,runtime/,README.md,docs/,licenses/}
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
name="${1:?usage: package.sh <name>}"
rt="$ROOT/build/install/runtime"
[[ -f "$rt/bin/osx64/vrclient.dylib" ]] || { echo "no $rt (scripts/build.sh)" >&2; exit 1; }
stage="$ROOT/build/dist/$name"
rm -rf "$stage" "$stage.zip"
mkdir -p "$stage/licenses" "$stage/docs"
cp "$ROOT/docs/development.md" "$stage/docs/"
cp -R "$rt" "$stage/runtime"
cp "$ROOT/scripts/install.sh" "$ROOT/README.md" "$stage/"
cp "$ROOT/LICENSE" "$stage/licenses/MIT-scripts.txt"
oc="$ROOT/third_party/opencomposite"
cp "$oc/LICENSE.txt" "$stage/licenses/GPL-3.0-OpenComposite.txt"
for f in "$oc"/LICEN[CS]E_*.txt; do cp "$f" "$stage/licenses/OpenComposite-$(basename "$f")"; done
cp "$ROOT/third_party/openxr-sdk/LICENSE" "$stage/licenses/OpenXR-SDK-LICENSE.txt"
cp "$ROOT/third_party/openxr-sdk/LICENSES/LicenseRef-jsoncpp-public-domain.txt" "$stage/licenses/OpenXR-SDK-jsoncpp.txt"
(cd "$ROOT/build/dist" && ditto -c -k --norsrc --noextattr --noacl --keepParent "$name" "$name.zip")
shasum -a 256 "$stage.zip"
