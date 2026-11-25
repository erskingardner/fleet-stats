#!/usr/bin/env bash
# Headless macOS launchd installer (works on Apple Silicon & Intel Macs)
# Usage: ./install-macos.sh [BINARY_PATH] [BEARER_TOKEN] [BIND_ADDR]
set -euo pipefail

BIN_SRC="${1:-./fleetd}"
TOKEN="${2:-}"
BIND_ADDR="${3:-0.0.0.0:9470}"

if [[ ! -f "$BIN_SRC" ]]; then
  echo "Error: fleetd binary not found at $BIN_SRC"
  exit 1
fi

echo "==> Installing /usr/local/bin/fleetd (may prompt for sudo)..."
sudo mkdir -p /usr/local/bin
sudo install -m 0755 "$BIN_SRC" /usr/local/bin/fleetd

CFG_DIR="$HOME/Library/Application Support/FleetStats/fleetd"
CFG_PATH="$CFG_DIR/config.toml"
mkdir -p "$CFG_DIR"

if [[ ! -f "$CFG_PATH" ]]; then
  if [[ -n "$TOKEN" ]]; then
    /usr/local/bin/fleetd --config "$CFG_PATH" init --bind "$BIND_ADDR" --token "$TOKEN"
  else
    /usr/local/bin/fleetd --config "$CFG_PATH" init --bind "$BIND_ADDR"
  fi
fi

PLIST="$HOME/Library/LaunchAgents/com.fleetstats.fleetd.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat <<EOF > "$PLIST"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.fleetstats.fleetd</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/fleetd</string>
        <string>--config</string>
        <string>${CFG_PATH}</string>
        <string>serve</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/fleetd.out.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/fleetd.err.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo ""
echo "==> fleetd LaunchAgent is running!"
echo "Bearer Token: $(/usr/local/bin/fleetd --config "$CFG_PATH" print-token)"
echo "Bind Address: $BIND_ADDR"
