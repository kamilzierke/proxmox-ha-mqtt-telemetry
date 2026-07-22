#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="/etc/proxmox-ha-mqtt.env"

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: run as root on the Proxmox host" >&2
  exit 1
fi

echo "Installing required packages..."
apt update
apt install -y lm-sensors python3 python3-paho-mqtt mosquitto-clients smartmontools

echo "Installing scripts..."
install -m 700 "$REPO_ROOT/scripts/proxmox-ha-hwmon-daemon.py" /usr/local/sbin/proxmox-ha-hwmon-daemon.py
install -m 700 "$REPO_ROOT/scripts/proxmox-ha-smart-daemon.py" /usr/local/sbin/proxmox-ha-smart-daemon.py
install -m 644 "$REPO_ROOT/scripts/proxmox_ha_common.py" /usr/local/sbin/proxmox_ha_common.py

echo "Installing systemd units..."
install -m 644 "$REPO_ROOT/systemd/proxmox-ha-hwmon.service" /etc/systemd/system/proxmox-ha-hwmon.service
install -m 644 "$REPO_ROOT/systemd/proxmox-ha-smart.service" /etc/systemd/system/proxmox-ha-smart.service

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Creating $ENV_FILE from example. Edit it before enabling the services."
  install -m 600 "$REPO_ROOT/examples/proxmox-ha-mqtt.env.example" "$ENV_FILE"
else
  echo "$ENV_FILE already exists; leaving it untouched."
fi

systemctl daemon-reload

cat <<EOF2

Installed.

Next steps:
  1. Edit $ENV_FILE
  2. Test manually (Ctrl+C to stop):
       /usr/local/sbin/proxmox-ha-hwmon-daemon.py
       /usr/local/sbin/proxmox-ha-smart-daemon.py
  3. Enable the services (these are long-running daemons, not one-shot timers):
       systemctl enable --now proxmox-ha-hwmon.service proxmox-ha-smart.service

EOF2
