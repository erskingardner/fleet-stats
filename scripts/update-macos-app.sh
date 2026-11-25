#!/usr/bin/env sh
# FleetStats verified macOS updater (updates /Applications/FleetStats.app if installed,
# otherwise updates headless launchd fleetd via install.sh).
# Verifies SHA-256 checksum, Apple Developer ID signature, and Team ID (8Z6Q2LZ77W).

set -eu

REPO="${FLEETSTATS_REPO:-erskingardner/fleet-stats}"
EXPECTED_TEAM="8Z6Q2LZ77W"
APP_DEST="/Applications/FleetStats.app"

if [ ! -d "$APP_DEST" ]; then
  echo "==> ${APP_DEST} not found; updating headless launchd fleetd..."
  exec sh -c "curl -fsSL --proto '=https' --tlsv1.2 'https://raw.githubusercontent.com/${REPO}/main/scripts/install.sh' | sh"
fi

BASE_URL="https://github.com/${REPO}/releases/latest/download"
TMP_DIR="$(mktemp -d)"
MOUNT_DIR="${TMP_DIR}/mnt"
chmod 0700 "$TMP_DIR"
mkdir -p "$MOUNT_DIR"

cleanup() {
  hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

echo "==> Downloading FleetStats.dmg & SHA256SUMS.txt..."
curl -fsSL --proto '=https' --tlsv1.2 "${BASE_URL}/FleetStats.dmg" -o "${TMP_DIR}/FleetStats.dmg"
curl -fsSL --proto '=https' --tlsv1.2 "${BASE_URL}/SHA256SUMS.txt" -o "${TMP_DIR}/SHA256SUMS.txt"

echo "==> Verifying SHA-256 checksum..."
EXPECTED_SHA="$(awk '$2 == "FleetStats.dmg" || $2 == "*FleetStats.dmg" { print $1; exit }' "${TMP_DIR}/SHA256SUMS.txt")"
ACTUAL_SHA="$(shasum -a 256 "${TMP_DIR}/FleetStats.dmg" | awk '{ print $1 }')"
if [ -z "$EXPECTED_SHA" ] || [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
  echo "ERROR: SHA-256 checksum mismatch for FleetStats.dmg!" >&2
  exit 1
fi
echo "    Checksum OK (${ACTUAL_SHA})"

echo "==> Mounting FleetStats.dmg..."
hdiutil attach "${TMP_DIR}/FleetStats.dmg" -nobrowse -readonly -mountpoint "$MOUNT_DIR" >/dev/null

STAGED_APP="${TMP_DIR}/FleetStats.app"
ditto "${MOUNT_DIR}/FleetStats.app" "$STAGED_APP"
hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true

echo "==> Verifying Apple Developer ID signature & Team ID..."
codesign --verify --deep --strict "$STAGED_APP"
TEAM_ID="$(codesign -dvv "$STAGED_APP" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
if [ "$TEAM_ID" != "$EXPECTED_TEAM" ]; then
  echo "ERROR: Unexpected TeamIdentifier '${TEAM_ID}' (expected ${EXPECTED_TEAM})" >&2
  exit 1
fi
NEW_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${STAGED_APP}/Contents/Info.plist" 2>/dev/null || echo 'latest')"
echo "    Signature OK (Team ${TEAM_ID}, v${NEW_VER})"

echo "==> Installing FleetStats v${NEW_VER} to ${APP_DEST}..."
pkill -TERM -x FleetStats 2>/dev/null || true
sleep 0.5

if [ -w "/Applications" ] && [ -w "$APP_DEST" ]; then
  rm -rf "${APP_DEST}.prev"
  mv "$APP_DEST" "${APP_DEST}.prev"
  if mv "$STAGED_APP" "$APP_DEST"; then
    rm -rf "${APP_DEST}.prev"
  else
    mv "${APP_DEST}.prev" "$APP_DEST"
    echo "ERROR: Failed replacing ${APP_DEST}" >&2
    exit 1
  fi
else
  sudo rm -rf "${APP_DEST}.prev"
  sudo mv "$APP_DEST" "${APP_DEST}.prev"
  if sudo mv "$STAGED_APP" "$APP_DEST"; then
    sudo rm -rf "${APP_DEST}.prev"
  else
    sudo mv "${APP_DEST}.prev" "$APP_DEST"
    echo "ERROR: Failed replacing ${APP_DEST}" >&2
    exit 1
  fi
fi

echo "==> Relaunching FleetStats..."
open "$APP_DEST" 2>/dev/null || true
echo "Done! FleetStats updated to v${NEW_VER}."
