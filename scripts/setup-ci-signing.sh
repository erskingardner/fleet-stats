#!/usr/bin/env bash
# Interactive one-time setup to upload your macOS Developer ID certificate & Apple
# notarization credentials as GitHub Actions secrets on erskingardner/fleet-stats.
set -euo pipefail

REPO="${FLEETSTATS_REPO:-erskingardner/fleet-stats}"

echo "=== FleetStats GitHub Actions Signing & Notarization Setup ==="
echo "Target repo: $REPO"
echo ""
echo "Step 1: Export your Developer ID Application certificate from Keychain Access:"
echo "  1. Open 'Keychain Access' -> 'login' -> 'My Certificates'"
echo "  2. Find 'Developer ID Application: PAPER ROBIN DI JEFFREY ERSKIN GARDNER & C. SAS (8Z6Q2LZ77W)'"
echo "  3. Right-click -> Export... -> save as a .p12 file with a strong password"
echo ""
read -r -p "Path to exported .p12 file: " P12_PATH
P12_PATH="${P12_PATH/#\~/$HOME}"
if [[ ! -f "$P12_PATH" ]]; then
  echo "File not found: $P12_PATH" >&2
  exit 1
fi
read -r -s -p "Password for .p12 file: " P12_PASS
echo ""

echo ""
echo "Step 2: Apple Notarization credentials (App-Specific Password from https://account.apple.com)"
read -r -p "Apple ID email (e.g. jeff@paper-robin.com): " APPLE_ID
read -r -s -p "App-Specific Password (xxxx-xxxx-xxxx-xxxx): " APPLE_APP_PASSWORD
echo ""

echo ""
echo "==> Uploading secrets to GitHub Actions ($REPO)..."
base64 -i "$P12_PATH" | tr -d '\n' | gh secret set MACOS_CERT_P12 -R "$REPO"
printf '%s' "$P12_PASS" | gh secret set MACOS_CERT_PASSWORD -R "$REPO"
printf '%s' "$APPLE_ID" | gh secret set APPLE_ID -R "$REPO"
printf '%s' "$APPLE_APP_PASSWORD" | gh secret set APPLE_APP_PASSWORD -R "$REPO"
printf '%s' "8Z6Q2LZ77W" | gh secret set APPLE_TEAM_ID -R "$REPO"

echo ""
echo "==> All 5 GitHub secrets configured!"
echo "Any tag you push (e.g. 'git tag v0.1.0 && git push origin v0.1.0') will now"
echo "build, Developer-ID sign, Apple-notarize, staple, and publish FleetStats.dmg."
