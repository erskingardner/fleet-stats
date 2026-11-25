#!/usr/bin/env sh
# FleetStats universal agent installer (Linux systemd & macOS launchd)
#
# Linux (Debian / Ubuntu / Arch / Fedora — x86_64 & arm64):
#   curl -fsSL https://raw.githubusercontent.com/erskingardner/fleet-stats/main/scripts/install.sh | sudo sh
#   curl -fsSL https://raw.githubusercontent.com/erskingardner/fleet-stats/main/scripts/install.sh | sudo sh -s -- --token "fls_..."
#
# Headless macOS (Mac Mini / Intel iMac):
#   curl -fsSL https://raw.githubusercontent.com/erskingardner/fleet-stats/main/scripts/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/erskingardner/fleet-stats/main/scripts/install.sh | sh -s -- --token "fls_..."

set -eu

REPO="${FLEETSTATS_REPO:-erskingardner/fleet-stats}"
VERSION="latest"
TOKEN=""
BIND_ADDR="0.0.0.0:9470"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --token)
      TOKEN="$2"
      shift 2
      ;;
    --bind)
      BIND_ADDR="$2"
      shift 2
      ;;
    --version)
      VERSION="$2"
      shift 2
      ;;
    --repo)
      REPO="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

OS_RAW="$(uname -s)"
ARCH_RAW="$(uname -m)"

case "$OS_RAW" in
  Linux)  OS="linux" ;;
  Darwin) OS="darwin" ;;
  *)
    echo "Unsupported OS: $OS_RAW" >&2
    exit 1
    ;;
esac

case "$ARCH_RAW" in
  x86_64|amd64)   ARCH="x86_64" ;;
  aarch64|arm64)  ARCH="aarch64" ;;
  *)
    echo "Unsupported architecture: $ARCH_RAW" >&2
    exit 1
    ;;
esac

if [ "$OS" = "darwin" ]; then
  ASSET="fleetd-darwin-universal"
else
  ASSET="fleetd-linux-${ARCH}"
fi

if [ "$VERSION" = "latest" ]; then
  DOWNLOAD_URL="https://github.com/${REPO}/releases/latest/download/${ASSET}"
else
  DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${VERSION}/${ASSET}"
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "==> Downloading ${ASSET} from ${REPO} (${VERSION})..."
if ! curl -fsSL "$DOWNLOAD_URL" -o "${TMP_DIR}/fleetd"; then
  echo "Failed to download ${DOWNLOAD_URL}" >&2
  echo "Make sure a GitHub release exists at https://github.com/${REPO}/releases" >&2
  exit 1
fi
chmod 0755 "${TMP_DIR}/fleetd"

if [ "$OS" = "linux" ]; then
  if [ "$(id -u)" -ne 0 ]; then
    echo "Please run with sudo on Linux: curl -fsSL ... | sudo sh" >&2
    exit 1
  fi

  echo "==> Installing /usr/local/bin/fleetd..."
  install -m 0755 "${TMP_DIR}/fleetd" /usr/local/bin/fleetd

  if ! id -u fleetd >/dev/null 2>&1; then
    echo "==> Creating system user 'fleetd'..."
    if command -v useradd >/dev/null 2>&1; then
      useradd --system --no-create-home --shell /usr/sbin/nologin fleetd 2>/dev/null \
        || useradd --system --no-create-home --shell /sbin/nologin fleetd
    else
      adduser --system --no-create-home --disabled-login fleetd
    fi
  fi

  mkdir -p /etc/fleetd /var/lib/fleetd
  chown -R fleetd:fleetd /etc/fleetd /var/lib/fleetd
  chmod 0750 /etc/fleetd /var/lib/fleetd

  if [ ! -f /etc/fleetd/config.toml ] || [ -n "$TOKEN" ]; then
    if [ -n "$TOKEN" ]; then
      /usr/local/bin/fleetd --config /etc/fleetd/config.toml init --bind "$BIND_ADDR" --token "$TOKEN" >/dev/null
    else
      /usr/local/bin/fleetd --config /etc/fleetd/config.toml init --bind "$BIND_ADDR" >/dev/null
    fi
    sed -i 's|^db_path = .*|db_path = "/var/lib/fleetd/fleetd.db"|' /etc/fleetd/config.toml
    chown fleetd:fleetd /etc/fleetd/config.toml
    chmod 0600 /etc/fleetd/config.toml
  fi

  cat <<'EOF' > /etc/systemd/system/fleetd.service
[Unit]
Description=FleetStats Telemetry Agent (fleetd)
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/fleetd --config /etc/fleetd/config.toml serve
Restart=always
RestartSec=3
User=fleetd
Group=fleetd
StateDirectory=fleetd
ConfigurationDirectory=fleetd
AmbientCapabilities=CAP_DAC_READ_SEARCH CAP_SYSLOG
CapabilityBoundingSet=CAP_DAC_READ_SEARCH CAP_SYSLOG
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=true
MemoryMax=64M

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now fleetd.service
  systemctl restart fleetd.service

  FINAL_TOKEN="$(/usr/local/bin/fleetd --config /etc/fleetd/config.toml print-token)"
  TS_IP="$(tailscale ip -4 2>/dev/null | head -n 1 || hostname -f 2>/dev/null || hostname)"

  echo ""
  echo "============================================================"
  echo "  fleetd is installed and running (systemd)!"
  echo "  Host / Tailscale IP : ${TS_IP}"
  echo "  Port                : $(echo "$BIND_ADDR" | awk -F: '{print $NF}')"
  echo "  Bearer Token        : ${FINAL_TOKEN}"
  echo "============================================================"
else
  echo "==> Installing /usr/local/bin/fleetd (sudo may prompt for password)..."
  sudo mkdir -p /usr/local/bin
  sudo install -m 0755 "${TMP_DIR}/fleetd" /usr/local/bin/fleetd

  CFG_DIR="${HOME}/Library/Application Support/FleetStats/fleetd"
  CFG_PATH="${CFG_DIR}/config.toml"
  mkdir -p "$CFG_DIR"

  if [ ! -f "$CFG_PATH" ] || [ -n "$TOKEN" ]; then
    if [ -n "$TOKEN" ]; then
      /usr/local/bin/fleetd --config "$CFG_PATH" init --bind "$BIND_ADDR" --token "$TOKEN" >/dev/null
    else
      /usr/local/bin/fleetd --config "$CFG_PATH" init --bind "$BIND_ADDR" >/dev/null
    fi
  fi

  PLIST="${HOME}/Library/LaunchAgents/com.paper-robin.fleetd.plist"
  mkdir -p "${HOME}/Library/LaunchAgents"
  cat <<EOF > "$PLIST"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.paper-robin.fleetd</string>
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

  FINAL_TOKEN="$(/usr/local/bin/fleetd --config "$CFG_PATH" print-token)"
  TS_IP="$(/Applications/Tailscale.app/Contents/MacOS/Tailscale ip -4 2>/dev/null | head -n 1 || hostname)"

  echo ""
  echo "============================================================"
  echo "  fleetd is installed and running (launchd)!"
  echo "  Host / Tailscale IP : ${TS_IP}"
  echo "  Port                : $(echo "$BIND_ADDR" | awk -F: '{print $NF}')"
  echo "  Bearer Token        : ${FINAL_TOKEN}"
  echo "============================================================"
fi
