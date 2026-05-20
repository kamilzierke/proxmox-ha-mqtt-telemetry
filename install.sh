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
apt install -y lm-sensors jq mosquitto-clients smartmontools

echo "Installing scripts..."
install -m 700 "$REPO_ROOT/scripts/proxmox-ha-hwmon-mqtt.sh" /usr/local/sbin/proxmox-ha-hwmon-mqtt.sh
install -m 700 "$REPO_ROOT/scripts/proxmox-ha-smart-mqtt.sh" /usr/local/sbin/proxmox-ha-smart-mqtt.sh

echo "Installing systemd units..."
install -m 644 "$REPO_ROOT/systemd/proxmox-ha-hwmon.service" /etc/systemd/system/proxmox-ha-hwmon.service
install -m 644 "$REPO_ROOT/systemd/proxmox-ha-hwmon.timer" /etc/systemd/system/proxmox-ha-hwmon.timer
install -m 644 "$REPO_ROOT/systemd/proxmox-ha-smart.service" /etc/systemd/system/proxmox-ha-smart.service
install -m 644 "$REPO_ROOT/systemd/proxmox-ha-smart.timer" /etc/systemd/system/proxmox-ha-smart.timer

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Creating $ENV_FILE from example. Edit it before enabling timers."
  install -m 600 "$REPO_ROOT/examples/proxmox-ha-mqtt.env.example" "$ENV_FILE"
else
  echo "$ENV_FILE already exists; leaving it untouched."
fi

systemctl daemon-reload

cat <<EOF2

Installed.

Next steps:
  1. Edit $ENV_FILE
  2. Test manually:
       /usr/local/sbin/proxmox-ha-hwmon-mqtt.sh
       /usr/local/sbin/proxmox-ha-smart-mqtt.sh
  3. Enable timers:
       systemctl enable --now proxmox-ha-hwmon.timer proxmox-ha-smart.timer

EOF2
