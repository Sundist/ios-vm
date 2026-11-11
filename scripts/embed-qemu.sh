#!/usr/bin/env bash
# Xcode build phase: embeds QEMU/<flavor> (see fetch-qemu-sysroot.sh) into
# the app for device builds. Does nothing when the sysroot is absent, so the
# app also builds without the QEMU engine.
set -euo pipefail

FLAVOR="${PVM_QEMU_FLAVOR:-tci}"
case "${PLATFORM_NAME:-}" in
    iphoneos) SRC="$SRCROOT/QEMU/$FLAVOR" ;;
    iphonesimulator) SRC="$SRCROOT/QEMU/$FLAVOR-simulator" ;;
    *) echo "QEMU engine not embedded (platform ${PLATFORM_NAME:-?})"; exit 0 ;;
esac
if [ ! -d "$SRC/Frameworks" ]; then
    echo "QEMU engine not embedded ($SRC missing; see scripts/fetch-qemu-sysroot.sh)"
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
