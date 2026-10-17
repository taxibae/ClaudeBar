#!/bin/bash
# Build script for LLMBar

set -e

APP_NAME="LLMBar"

# The selected developer directory (DEVELOPER_DIR or xcode-select) decides the SDK.
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"

# swiftbuild's link step may not learn the SDK version and then records the deployment
# target (14.0) as the SDK, which makes macOS run the app in old-SDK compatibility mode.
# Passing the sysroot to the Clang linker records the real SDK; it is harmless for native.
SDK_LINK_OPTIONS=(
    -Xswiftc -Xclang-linker -Xswiftc -isysroot
    -Xswiftc -Xclang-linker -Xswiftc "$SDK_PATH"
)
BUILD_OPTIONS=(-c release "${SDK_LINK_OPTIONS[@]}" "$@")

echo "Building $APP_NAME with SDK $SDK_VERSION ($SDK_PATH)..."
swift build "${BUILD_OPTIONS[@]}"
BUILD_DIR="$(swift build "${BUILD_OPTIONS[@]}" --show-bin-path)"

RECORDED_SDK="$(xcrun vtool -show-build "$BUILD_DIR/$APP_NAME" | awk '$1 == "sdk" { print $2; exit }')"
if [ "$RECORDED_SDK" != "$SDK_VERSION" ]; then
    echo "Executable records SDK ${RECORDED_SDK:-unknown}, expected $SDK_VERSION" >&2
    exit 1
fi
echo "Recorded SDK: $RECORDED_SDK"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
RESOURCE_BUNDLE="$BUILD_DIR/${APP_NAME}_${APP_NAME}.bundle"

# Both native and swiftbuild place the resource bundle beside the executable.
# Missing resources would make the app crash on its first localized menu view.
if [ ! -d "$RESOURCE_BUNDLE" ]; then
    echo "Missing resource bundle: $RESOURCE_BUNDLE" >&2
    exit 1
fi

echo "Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# The SwiftPM resource bundle must live under Contents/Resources: anything else at the
# bundle root is "unsealed content" and codesign refuses to seal the app.
# Localization.swift looks there first and falls back to Bundle.module for `swift run`.
cp -r "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"

# Ad-hoc signature: gives the bundle a stable identity so UNUserNotificationCenter
# and Keychain ACL prompts are attributed to LLMBar instead of an unsigned binary.
echo "Signing (ad-hoc)..."
codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"
echo "Signature verified."

echo ""
echo "Build complete: $APP_BUNDLE"
echo ""
echo "Run:     open $APP_BUNDLE"
echo "Install: cp -r $APP_BUNDLE /Applications/"
