#!/usr/bin/env bash
# Downloads UTM's prebuilt iOS QEMU sysroot (QEMU fork built as frameworks,
# GPLv2 / Apache-2.0, https://github.com/utmapp/UTM) and keeps what the
# PocketVM QEMU engine needs:
#
#   QEMU/<flavor>/Frameworks/   qemu-aarch64-softmmu, qemu-x86_64-softmmu and
#                               their dependency frameworks (glib, pixman…)
#   QEMU/<flavor>/qemu/         UEFI firmware and option ROMs
#
# Flavors:
#   tci  Sysroot-ios-tci-arm64  threaded interpreter, works without JIT (default)
#   jit  Sysroot-ios-arm64      TCG JIT, needs JIT enabled by a debugger
#
# Requires: macOS, gh (GitHub CLI, logged in or GH_TOKEN set), unzip.
# Usage: scripts/fetch-qemu-sysroot.sh [tci|jit]
set -euo pipefail

FLAVOR="${1:-tci}"
case "$FLAVOR" in
    tci) ARTIFACT="Sysroot-ios-tci-arm64" ;;
    jit) ARTIFACT="Sysroot-ios-arm64" ;;
    *) echo "usage: $0 [tci|jit]" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/QEMU/$FLAVOR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

find_artifact() {
    local query="$1" run id
    for run in $(gh api "repos/utmapp/UTM/actions/workflows/build.yml/runs?$query&status=success&per_page=15" --jq '.workflow_runs[].id'); do
        id=$(gh api "repos/utmapp/UTM/actions/runs/$run/artifacts?per_page=100" \
            --jq ".artifacts[] | select(.name == \"$ARTIFACT\" and .expired == false) | .id" | head -n 1)
        if [ -n "$id" ]; then
            echo "$run $id"
            return 0
        fi
    done
    return 1
}

echo "Looking for $ARTIFACT in UTM's GitHub Actions…"
FOUND="$(find_artifact "event=release" || find_artifact "branch=main" || true)"
if [ -z "$FOUND" ]; then
    echo "No unexpired $ARTIFACT artifact found. Build it with UTM's scripts/build_dependencies.sh -p ${ARTIFACT#Sysroot-} instead." >&2
    exit 1
fi
read -r RUN_ID ARTIFACT_ID <<< "$FOUND"
echo "Using UTM run $RUN_ID (artifact $ARTIFACT_ID)"

gh api "repos/utmapp/UTM/actions/artifacts/$ARTIFACT_ID/zip" > "$WORK/artifact.zip"
unzip -q "$WORK/artifact.zip" -d "$WORK/artifact"
tar -xzf "$WORK/artifact/sysroot.tgz" -C "$WORK"
SYSROOT="$(find "$WORK" -maxdepth 1 -type d -name 'sysroot*' | head -n 1)"
[ -d "$SYSROOT/Frameworks" ] || { echo "Unexpected sysroot layout" >&2; ls -la "$WORK" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT/Frameworks" "$OUT/qemu"

# Copy the QEMU frameworks and, transitively, every framework they link.
queue=(qemu-aarch64-softmmu qemu-x86_64-softmmu)
copied=" "
while [ ${#queue[@]} -gt 0 ]; do
    name="${queue[0]}"
    queue=("${queue[@]:1}")
    case "$copied" in *" $name "*) continue ;; esac
    src="$SYSROOT/Frameworks/$name.framework"
    if [ ! -d "$src" ]; then
        echo "warning: $name.framework not in sysroot" >&2
        continue
    fi
    cp -R "$src" "$OUT/Frameworks/"
    copied="$copied$name "
    for dep in $(otool -L "$src/$name" | awk '/@rpath\/.*\.framework/ {print $1}' | sed -E 's#@rpath/([^/]+)\.framework/.*#\1#'); do
        queue+=("$dep")
    done
done

# Firmware and ROMs used by the virt / q35 machines.
SHARE="$SYSROOT/share/qemu"
for pattern in 'edk2-aarch64-code.fd' 'edk2-arm-vars.fd' 'edk2-x86_64-code.fd' 'edk2-i386-vars.fd' \
               'vgabios*.bin' 'efi-*.rom' 'bios-256k.bin' 'kvmvapic.bin' 'linuxboot_dma.bin' 'multiboot_dma.bin'; do
    for file in $SHARE/$pattern; do
        [ -e "$file" ] && cp "$file" "$OUT/qemu/"
    done
done
[ -d "$SHARE/keymaps" ] && cp -R "$SHARE/keymaps" "$OUT/qemu/"

for required in Frameworks/qemu-aarch64-softmmu.framework qemu/edk2-aarch64-code.fd; do
    [ -e "$OUT/$required" ] || { echo "missing $required" >&2; exit 1; }
done

{
    echo "UTM run: https://github.com/utmapp/UTM/actions/runs/$RUN_ID"
    echo "Artifact: $ARTIFACT"
    echo "QEMU source (GPLv2): https://github.com/utmapp/qemu"
} > "$OUT/SOURCE.txt"

echo "Installed into $OUT:"
du -sh "$OUT/Frameworks" "$OUT/qemu"
ls "$OUT/Frameworks"
