#!/bin/bash
# Build script for LLMBar

set -e

APP_NAME="LLMBar"
BUILD_OPTIONS=(-c release "$@")

echo "Building $APP_NAME..."
swift build "${BUILD_OPTIONS[@]}"
BUILD_DIR="$(swift build "${BUILD_OPTIONS[@]}" --show-bin-path)"
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
