# Installation

These instructions install the exporters directly on the Proxmox host.

## 0. Prepare Home Assistant / MQTT first

Before touching Proxmox, prepare the MQTT side:

1. Install/configure an MQTT broker.
   - The Home Assistant Mosquitto add-on is a common option.
2. Create an MQTT user, for example `proxmox_mqtt`.
3. Confirm the broker is reachable from the Proxmox host on TCP port `1883`.
4. Confirm MQTT Discovery is enabled in Home Assistant.

If Mosquitto runs as a Home Assistant add-on, `MQTT_HOST` is usually the IP address of Home Assistant, not the Proxmox host.

## 1. Install dependencies on Proxmox

```bash
apt update
apt install -y lm-sensors python3 python3-paho-mqtt mosquitto-clients smartmontools
```

`python3-paho-mqtt` is the MQTT client library the daemons use to hold a
single persistent connection open (instead of shelling out to
`mosquitto_pub` once per metric). `mosquitto-clients` is no longer required
by the daemons themselves, but is kept for the manual `mosquitto_pub` /
`mosquitto_sub` checks used below and in troubleshooting.

Optional, for network tests:

```bash
apt install -y netcat-openbsd
```

## 2. Verify local telemetry sources

Hardware sensors:

```bash
sensors
sensors -j
```

SMART/NVMe disks:

```bash
smartctl --scan-open
```

Test one disk manually if needed:

```bash
smartctl -a -j /dev/nvme0
smartctl -a -j -d sat /dev/sda
```

Use the exact device/type combination returned by `smartctl --scan-open`.

## 3. Copy scripts

From the repository root on the Proxmox host:

```bash
install -m 700 scripts/proxmox-ha-hwmon-daemon.py /usr/local/sbin/proxmox-ha-hwmon-daemon.py
install -m 700 scripts/proxmox-ha-smart-daemon.py /usr/local/sbin/proxmox-ha-smart-daemon.py
install -m 644 scripts/proxmox_ha_common.py /usr/local/sbin/proxmox_ha_common.py
```

`proxmox_ha_common.py` is a shared module imported by both daemons - it must
live in the same directory as them, but does not need the execute bit.

Expected permissions:

```text
-rwx------ root:root /usr/local/sbin/proxmox-ha-hwmon-daemon.py
-rwx------ root:root /usr/local/sbin/proxmox-ha-smart-daemon.py
-rw-r--r-- root:root /usr/local/sbin/proxmox_ha_common.py
```

## 4. Create `/etc/proxmox-ha-mqtt.env`

```bash
install -m 600 examples/proxmox-ha-mqtt.env.example /etc/proxmox-ha-mqtt.env
nano /etc/proxmox-ha-mqtt.env
```

Set at least:

```bash
MQTT_HOST="192.168.1.100"
MQTT_PORT="1883"
MQTT_USER="proxmox_mqtt"
MQTT_PASS="your_real_password"
NODE_NAME="pve"
DISCOVERY_PREFIX="homeassistant"
BASE_TOPIC="proxmox/pve/hwmon"
SMART_BASE_TOPIC="proxmox/pve/smart"
HWMON_INTERVAL_SECONDS="60"
SMART_INTERVAL_SECONDS="300"
```

Then secure it:

```bash
chmod 600 /etc/proxmox-ha-mqtt.env
chown root:root /etc/proxmox-ha-mqtt.env
```

Never commit this real file to Git.

## 5. Test MQTT connectivity

```bash
source /etc/proxmox-ha-mqtt.env

nc -vz "$MQTT_HOST" "$MQTT_PORT"

mosquitto_pub -d \
  -h "$MQTT_HOST" \
  -p "$MQTT_PORT" \
  -u "$MQTT_USER" \
  -P "$MQTT_PASS" \
  -t "debug/proxmox/test" \
  -m "hello-from-proxmox-$(date -Is)"
```

Expected `mosquitto_pub -d` output includes:

```text
Client null sending CONNECT
Client null received CONNACK (0)
Client null sending PUBLISH
Client null sending DISCONNECT
```

## 6. Test exporters manually

```bash
python3 -m py_compile /usr/local/sbin/proxmox-ha-hwmon-daemon.py
python3 -m py_compile /usr/local/sbin/proxmox-ha-smart-daemon.py

# Each daemon runs in the foreground and loops forever - stop it with Ctrl+C
# once you've confirmed it connected and published a cycle.
/usr/local/sbin/proxmox-ha-hwmon-daemon.py
/usr/local/sbin/proxmox-ha-smart-daemon.py
```

In MQTT Explorer or Home Assistant MQTT listener, look for:

```text
proxmox/pve/hwmon/#
proxmox/pve/smart/#
homeassistant/#
```

## 7. Install systemd units

These are long-running services (`Type=simple`, `Restart=always`), not
timers - each daemon does its own internal scheduling based on
`HWMON_INTERVAL_SECONDS` / `SMART_INTERVAL_SECONDS`.

```bash
install -m 644 systemd/proxmox-ha-hwmon.service /etc/systemd/system/proxmox-ha-hwmon.service
install -m 644 systemd/proxmox-ha-smart.service /etc/systemd/system/proxmox-ha-smart.service

systemctl daemon-reload
systemctl enable --now proxmox-ha-hwmon.service proxmox-ha-smart.service
```

## 8. Verify systemd

```bash
systemctl status proxmox-ha-hwmon.service --no-pager
systemctl status proxmox-ha-smart.service --no-pager

journalctl -u proxmox-ha-hwmon.service -n 100 --no-pager
journalctl -u proxmox-ha-smart.service -n 150 --no-pager
```

Each service should log an MQTT connect once at startup, then one publish
cycle per interval - not a burst of connect/disconnect lines per metric.
