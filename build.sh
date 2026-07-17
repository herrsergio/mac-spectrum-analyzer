#!/bin/bash
# Builds the SPM executable and assembles an ad-hoc-signed .app.
set -euo pipefail

APP_NAME="Spectrum Visualizer"
EXECUTABLE="SpectrumVisualizer"
BUILD_DIR="build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"

echo "==> swift build -c release"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)"

echo "==> Assembling ${APP_BUNDLE}"
rm -rf "${APP_BUNDLE}"
mkdir -p "${CONTENTS}/MacOS"
mkdir -p "${CONTENTS}/Resources"

cp "${BIN_PATH}/${EXECUTABLE}" "${CONTENTS}/MacOS/${EXECUTABLE}"
cp "Resources/Info.plist" "${CONTENTS}/Info.plist"

echo "==> Signing (ad-hoc) with entitlements"
codesign --force --sign - \
    --entitlements "Resources/SpectrumVisualizer.entitlements" \
    --options runtime \
    "${APP_BUNDLE}"

echo "==> Done: ${APP_BUNDLE}"
echo "    open \"${APP_BUNDLE}\""
