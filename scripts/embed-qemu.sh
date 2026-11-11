#!/usr/bin/env bash
# Xcode build phase: embeds QEMU/<flavor> (see fetch-qemu-sysroot.sh) into
# the app for device builds. Does nothing when the sysroot is absent, so the
# app also builds without the QEMU engine.
set -euo pipefail

FLAVOR="${PVM_QEMU_FLAVOR:-tci}"
SRC="$SRCROOT/QEMU/$FLAVOR"
if [ "${PLATFORM_NAME:-}" != "iphoneos" ] || [ ! -d "$SRC/Frameworks" ]; then
    echo "QEMU engine not embedded (platform ${PLATFORM_NAME:-?}, $SRC missing or not a device build)"
    exit 0
fi

APP="$TARGET_BUILD_DIR/$WRAPPER_NAME"
mkdir -p "$APP/Frameworks" "$APP/qemu"
rsync -a --delete "$SRC/qemu/" "$APP/qemu/"
for framework in "$SRC"/Frameworks/*.framework; do
    rsync -a "$framework" "$APP/Frameworks/"
done

if [ "${CODE_SIGNING_ALLOWED:-YES}" = "YES" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
    for framework in "$APP"/Frameworks/*.framework; do
        /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none --preserve-metadata=identifier "$framework"
    done
fi
echo "Embedded QEMU ($FLAVOR): $(ls "$SRC/Frameworks" | wc -l | tr -d ' ') frameworks"
