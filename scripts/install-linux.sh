#!/usr/bin/env bash
# Distro-agnostic systemd installer for Debian, Ubuntu, Arch, Fedora, etc.
# Usage: sudo ./install-linux.sh [BINARY_PATH] [BEARER_TOKEN] [BIND_ADDR]
set -euo pipefail

BIN_SRC="${1:-./fleetd}"
TOKEN="${2:-}"
BIND_ADDR="${3:-0.0.0.0:9470}"

if [[ $EUID -ne 0 ]]; then
  echo "Please run with sudo: sudo $0 $*"
  exit 1
fi

if [[ ! -f "$BIN_SRC" ]]; then
  echo "Error: fleetd binary not found at $BIN_SRC"
  exit 1
fi

echo "==> Installing /usr/local/bin/fleetd..."
install -m 0755 "$BIN_SRC" /usr/local/bin/fleetd

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

if [[ ! -f /etc/fleetd/config.toml ]]; then
  if [[ -n "$TOKEN" ]]; then
    /usr/local/bin/fleetd --config /etc/fleetd/config.toml init --bind "$BIND_ADDR" --token "$TOKEN"
  else
    /usr/local/bin/fleetd --config /etc/fleetd/config.toml init --bind "$BIND_ADDR"
  fi
  # Ensure DB path points to systemd StateDirectory
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

echo ""
echo "==> fleetd is running!"
systemctl --no-pager status fleetd.service | head -n 10
echo ""
echo "Bearer Token: $(/usr/local/bin/fleetd --config /etc/fleetd/config.toml print-token)"
echo "Bind Address: $BIND_ADDR"
