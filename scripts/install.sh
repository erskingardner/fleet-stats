#!/usr/bin/env sh
# FleetStats universal agent installer (Linux systemd & macOS launchd)
# Hardened: verifies SHA-256 checksums, binds Tailscale + loopback only by default,
# blocks browser requests, uses zero-token Tailscale trust by default (optional --token / --require-token),
# and sandboxes service units.
#
# Linux (Debian / Ubuntu / Arch / Fedora — x86_64 & arm64):
#   curl -fsSL https://raw.githubusercontent.com/erskingardner/fleet-stats/main/scripts/install.sh | sudo sh
#   curl -fsSL https://raw.githubusercontent.com/erskingardner/fleet-stats/main/scripts/install.sh | sudo sh -s -- --require-token
#
# Headless macOS (Mac Mini / Intel iMac):
#   curl -fsSL https://raw.githubusercontent.com/erskingardner/fleet-stats/main/scripts/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/erskingardner/fleet-stats/main/scripts/install.sh | sh -s -- --require-token

set -eu

REPO="${FLEETSTATS_REPO:-erskingardner/fleet-stats}"
VERSION="latest"
TOKEN=""
REQUIRE_TOKEN="0"
NO_TOKEN="0"
BIND_ADDR="tailscale:9470"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --token)
      TOKEN="$2"
      shift 2
      ;;
    --require-token)
      REQUIRE_TOKEN="1"
      shift 1
      ;;
    --no-token)
      NO_TOKEN="1"
      shift 1
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
  BASE_URL="https://github.com/${REPO}/releases/latest/download"
else
  BASE_URL="https://github.com/${REPO}/releases/download/${VERSION}"
fi

DOWNLOAD_URL="${BASE_URL}/${ASSET}"
SUMS_URL="${BASE_URL}/SHA256SUMS.txt"

TMP_DIR="$(mktemp -d)"
chmod 0700 "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "==> Downloading ${ASSET} & SHA256SUMS.txt from ${REPO} (${VERSION})..."
if ! curl -fsSL --proto '=https' --tlsv1.2 "$DOWNLOAD_URL" -o "${TMP_DIR}/${ASSET}"; then
  echo "Failed to download ${DOWNLOAD_URL}" >&2
  echo "Make sure a GitHub release exists at https://github.com/${REPO}/releases" >&2
  exit 1
fi
if ! curl -fsSL --proto '=https' --tlsv1.2 "$SUMS_URL" -o "${TMP_DIR}/SHA256SUMS.txt"; then
  echo "Failed to download ${SUMS_URL} for checksum verification" >&2
  exit 1
fi

echo "==> Verifying SHA-256 checksum..."
EXPECTED_SHA="$(awk -v f="$ASSET" '$2 == f || $2 == "*" f { print $1; exit }' "${TMP_DIR}/SHA256SUMS.txt")"
if [ -z "$EXPECTED_SHA" ]; then
  echo "ERROR: No SHA-256 entry found for ${ASSET} in SHA256SUMS.txt" >&2
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA="$(sha256sum "${TMP_DIR}/${ASSET}" | awk '{ print $1 }')"
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA="$(shasum -a 256 "${TMP_DIR}/${ASSET}" | awk '{ print $1 }')"
else
  echo "ERROR: Neither sha256sum nor shasum found to verify binary integrity" >&2
  exit 1
fi

if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
  echo "ERROR: SHA-256 checksum mismatch for ${ASSET}!" >&2
  echo "  Expected: ${EXPECTED_SHA}" >&2
  echo "  Actual:   ${ACTUAL_SHA}" >&2
  exit 1
fi
echo "    Checksum OK (${ACTUAL_SHA})"
chmod 0755 "${TMP_DIR}/${ASSET}"

if [ "$OS" = "linux" ]; then
  if [ "$(id -u)" -ne 0 ]; then
    echo "Please run with sudo on Linux: curl -fsSL ... | sudo sh" >&2
    exit 1
  fi

  if systemctl is-active --quiet fleetd.service 2>/dev/null; then
    echo "==> Stopping existing fleetd service..."
    systemctl kill -s KILL fleetd.service 2>/dev/null || true
    systemctl stop fleetd.service 2>/dev/null || true
  fi

  echo "==> Installing /usr/local/bin/fleetd..."
  install -m 0755 "${TMP_DIR}/${ASSET}" /usr/local/bin/fleetd

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

  if [ ! -f /etc/fleetd/config.toml ] || [ -n "$TOKEN" ] || [ "$REQUIRE_TOKEN" = "1" ] || [ "$NO_TOKEN" = "1" ]; then
    INIT_FLAGS="--bind ${BIND_ADDR}"
    if [ "$REQUIRE_TOKEN" = "1" ]; then
      INIT_FLAGS="${INIT_FLAGS} --require-token"
    fi
    if [ "$NO_TOKEN" = "1" ]; then
      INIT_FLAGS="${INIT_FLAGS} --no-token"
    fi
    # shellcheck disable=SC2086
    FLEETD_TOKEN="$TOKEN" /usr/local/bin/fleetd --config /etc/fleetd/config.toml init $INIT_FLAGS >/dev/null
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
TimeoutStopSec=5
User=fleetd
Group=fleetd
UMask=0077
StateDirectory=fleetd
ConfigurationDirectory=fleetd
AmbientCapabilities=CAP_DAC_READ_SEARCH CAP_SYSLOG
CapabilityBoundingSet=CAP_DAC_READ_SEARCH CAP_SYSLOG
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ProtectControlGroups=true
ProtectKernelModules=true
ProtectKernelTunables=true
LockPersonality=true
MemoryDenyWriteExecute=true
RestrictRealtime=true
RestrictSUIDSGID=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK AF_UNIX
SystemCallArchitectures=native
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
  echo "  fleetd is installed and running (systemd, Tailscale-only)!"
  echo "  Host / Tailscale IP : ${TS_IP}"
  echo "  Bind                : ${BIND_ADDR}"
  if [ -n "$FINAL_TOKEN" ]; then
    echo "  Auth                : Bearer token required"
    echo "  Bearer Token        : ${FINAL_TOKEN}"
  else
    echo "  Auth                : Tailscale-only (zero-token, browser requests blocked)"
  fi
  echo "============================================================"
else
  echo "==> Installing /usr/local/bin/fleetd (sudo may prompt for password)..."
  sudo mkdir -p /usr/local/bin
  sudo install -m 0755 "${TMP_DIR}/${ASSET}" /usr/local/bin/fleetd

  CFG_DIR="${HOME}/Library/Application Support/FleetStats/fleetd"
  LOG_DIR="${HOME}/Library/Logs/FleetStats"
  CFG_PATH="${CFG_DIR}/config.toml"
  mkdir -p "$CFG_DIR" "$LOG_DIR"
  chmod 0700 "$CFG_DIR" "$LOG_DIR"

  if [ ! -f "$CFG_PATH" ] || [ -n "$TOKEN" ] || [ "$REQUIRE_TOKEN" = "1" ] || [ "$NO_TOKEN" = "1" ]; then
    INIT_FLAGS="--bind ${BIND_ADDR}"
    if [ "$REQUIRE_TOKEN" = "1" ]; then
      INIT_FLAGS="${INIT_FLAGS} --require-token"
    fi
    if [ "$NO_TOKEN" = "1" ]; then
      INIT_FLAGS="${INIT_FLAGS} --no-token"
    fi
    # shellcheck disable=SC2086
    FLEETD_TOKEN="$TOKEN" /usr/local/bin/fleetd --config "$CFG_PATH" init $INIT_FLAGS >/dev/null
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
    <key>Umask</key>
    <integer>63</integer>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/fleetd.out.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/fleetd.err.log</string>
</dict>
</plist>
EOF

  launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"

  FINAL_TOKEN="$(/usr/local/bin/fleetd --config "$CFG_PATH" print-token)"
  TS_IP="$(/Applications/Tailscale.app/Contents/MacOS/Tailscale ip -4 2>/dev/null | head -n 1 || hostname)"

  echo ""
  echo "============================================================"
  echo "  fleetd is installed and running (launchd, Tailscale-only)!"
  echo "  Host / Tailscale IP : ${TS_IP}"
  echo "  Bind                : ${BIND_ADDR}"
  if [ -n "$FINAL_TOKEN" ]; then
    echo "  Auth                : Bearer token required"
    echo "  Bearer Token        : ${FINAL_TOKEN}"
  else
    echo "  Auth                : Tailscale-only (zero-token, browser requests blocked)"
  fi
  echo "============================================================"
fi
