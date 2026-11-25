#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT_DIR="$ROOT_DIR/agent"
OUT_DIR="$ROOT_DIR/dist"
mkdir -p "$OUT_DIR"

echo "==> Building fleetd for host ($(uname -s)/$(uname -m))..."
(cd "$AGENT_DIR" && cargo build --release)
cp "$AGENT_DIR/target/release/fleetd" "$OUT_DIR/fleetd-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)"

# Copy into Apple bundle staging path for XcodeGen
mkdir -p "$ROOT_DIR/apple/Apps/FleetStatsMac/Resources/Helpers"
cp "$AGENT_DIR/target/release/fleetd" "$ROOT_DIR/apple/Apps/FleetStatsMac/Resources/Helpers/fleetd"

echo "==> Host binary staged at:"
echo "    $OUT_DIR/fleetd-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)"
echo "    $ROOT_DIR/apple/Apps/FleetStatsMac/Resources/Helpers/fleetd"

# Optional Intel macOS build if target is installed
if rustup target list --installed | grep -q "x86_64-apple-darwin"; then
  echo "==> Building fleetd for Intel macOS (x86_64-apple-darwin)..."
  (cd "$AGENT_DIR" && cargo build --release --target x86_64-apple-darwin)
  cp "$AGENT_DIR/target/x86_64-apple-darwin/release/fleetd" "$OUT_DIR/fleetd-darwin-x86_64"
  if command -v lipo >/dev/null 2>&1; then
    lipo -create \
      "$AGENT_DIR/target/release/fleetd" \
      "$AGENT_DIR/target/x86_64-apple-darwin/release/fleetd" \
      -output "$OUT_DIR/fleetd-darwin-universal"
    cp "$OUT_DIR/fleetd-darwin-universal" "$ROOT_DIR/apple/Apps/FleetStatsMac/Resources/Helpers/fleetd"
    echo "==> Created Universal macOS binary (arm64 + x86_64)"
  fi
fi

# Optional Linux cross-build via `cargo-zigbuild` or `cross` if installed
if [[ "${BUILD_LINUX:-0}" == "1" ]]; then
  if command -v cargo-zigbuild >/dev/null 2>&1; then
    echo "==> Cross-compiling Linux x86_64 via cargo-zigbuild..."
    (cd "$AGENT_DIR" && cargo zigbuild --release --target x86_64-unknown-linux-gnu.2.31)
    cp "$AGENT_DIR/target/x86_64-unknown-linux-gnu/release/fleetd" "$OUT_DIR/fleetd-linux-x86_64"
  elif command -v cross >/dev/null 2>&1; then
    echo "==> Cross-compiling Linux x86_64 via cross..."
    (cd "$AGENT_DIR" && cross build --release --target x86_64-unknown-linux-gnu)
    cp "$AGENT_DIR/target/x86_64-unknown-linux-gnu/release/fleetd" "$OUT_DIR/fleetd-linux-x86_64"
  else
    echo "NOTE: Install cargo-zigbuild (brew install zig && cargo install cargo-zigbuild) or build directly on your Linux host with: cd agent && cargo build --release"
  fi
fi
