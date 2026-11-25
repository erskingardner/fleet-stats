#!/usr/bin/env bash
# Builds a signed Universal (arm64 + x86_64) FleetStats.app and packages dist/FleetStats.dmg.
# Optionally notarizes & staples if NOTARY_PROFILE is set (create once via:
#   xcrun notarytool store-credentials "fleetstats-notary" --apple-id "..." --team-id "8Z6Q2LZ77W" --password "app-specific-password")
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APPLE_DIR="$ROOT_DIR/apple"
DERIVED_DIR="$APPLE_DIR/build/ReleaseDerivedData"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: PAPER ROBIN DI JEFFREY ERSKIN GARDNER & C. SAS (8Z6Q2LZ77W)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

mkdir -p "$DIST_DIR"

echo "==> 1. Building Universal fleetd (arm64 + x86_64)..."
"$ROOT_DIR/scripts/build-agent.sh"

echo "==> 2. Regenerating Xcode project..."
(cd "$APPLE_DIR" && xcodegen generate)

echo "==> 3. Building Release Universal FleetStats.app..."
SIGN_ARGS=()
if security find-identity -v -p codesigning | grep -Fq "$SIGN_IDENTITY"; then
  echo "    Signing with: $SIGN_IDENTITY"
  SIGN_ARGS+=(
    "CODE_SIGN_IDENTITY=$SIGN_IDENTITY"
    "CODE_SIGN_STYLE=Manual"
    "DEVELOPMENT_TEAM=8Z6Q2LZ77W"
    "OTHER_CODE_SIGN_FLAGS=--timestamp --options runtime"
  )
else
  if [[ "${REQUIRE_SIGNING:-0}" == "1" ]]; then
    echo "ERROR: Required Developer ID certificate not found: $SIGN_IDENTITY" >&2
    exit 1
  fi
  echo "    Developer ID certificate not found in keychain; falling back to ad-hoc signing."
  SIGN_ARGS+=(
    "CODE_SIGN_IDENTITY=-"
    "CODE_SIGN_STYLE=Automatic"
  )
fi

(
  cd "$APPLE_DIR"
  xcodebuild \
    -project FleetStats.xcodeproj \
    -scheme FleetStats \
    -configuration Release \
    -derivedDataPath "$DERIVED_DIR" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    "${SIGN_ARGS[@]}" \
    build
)

APP_PATH="$DERIVED_DIR/Build/Products/Release/FleetStats.app"
HELPER_PATH="$APP_PATH/Contents/Helpers/fleetd"

if security find-identity -v -p codesigning | grep -Fq "$SIGN_IDENTITY"; then
  echo "==> 4. Re-signing bundled fleetd helper & app with Hardened Runtime..."
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$HELPER_PATH"
  codesign --force --deep --options runtime --timestamp \
    --entitlements "$APPLE_DIR/Apps/FleetStatsMac/FleetStats.entitlements" \
    --sign "$SIGN_IDENTITY" \
    "$APP_PATH"
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
fi

echo "==> 5. Packaging dist/FleetStats.dmg..."
STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT

cp -R "$APP_PATH" "$STAGE_DIR/FleetStats.app"
ln -s /Applications "$STAGE_DIR/Applications"

DMG_PATH="$DIST_DIR/FleetStats.dmg"
rm -f "$DMG_PATH"

hdiutil create \
  -volname "FleetStats" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

if security find-identity -v -p codesigning | grep -Fq "$SIGN_IDENTITY"; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
fi

if [[ -n "$NOTARY_PROFILE" ]]; then
  echo "==> 6. Submitting FleetStats.dmg for Apple Notarization (profile: $NOTARY_PROFILE)..."
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  echo "==> 7. Stapling notarization ticket..."
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
else
  echo "==> Skipping notarization (set NOTARY_PROFILE=<keychain-profile> to notarize & staple)."
fi

echo ""
echo "==> Done! DMG ready at: $DMG_PATH"
ls -lh "$DMG_PATH"
