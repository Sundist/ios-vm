#!/usr/bin/env bash
# Downloads the pinned v86 (x86 emulator, BSD-2-Clause) build and SeaBIOS /
# VGA BIOS images (LGPLv3) into App/PCWeb. The results are committed, so this
# only needs to be re-run to upgrade v86.
set -euo pipefail

V86_VERSION="0.5.471"
V86_COMMIT="94faf3d6b19ecabc53a4010aaa24252fa6a162e2"   # commit of the npm build

root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/App/PCWeb"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$out/bios" "$out/licenses"

(cd "$work" && npm pack --silent "v86@$V86_VERSION" >/dev/null && tar -xzf "v86-$V86_VERSION.tgz")
cp "$work/package/build/libv86.js" "$out/libv86.js"
cp "$work/package/build/v86.wasm" "$out/v86.wasm"
cp "$work/package/LICENSE" "$out/licenses/v86-LICENSE.txt"

raw="https://raw.githubusercontent.com/copy/v86/$V86_COMMIT"
curl -fsSL "$raw/bios/seabios.bin" -o "$out/bios/seabios.bin"
curl -fsSL "$raw/bios/vgabios.bin" -o "$out/bios/vgabios.bin"
curl -fsSL "$raw/bios/COPYING.LESSER" -o "$out/licenses/seabios-COPYING.LESSER.txt"

(cd "$out" && shasum -a 256 libv86.js v86.wasm bios/seabios.bin bios/vgabios.bin > VERSIONS.sha256)
echo "v86 $V86_VERSION (commit $V86_COMMIT)" > "$out/licenses/VERSION.txt"
echo "Updated $out"
