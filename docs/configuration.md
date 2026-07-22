# Configuration

All runtime configuration is loaded from:

```text
/etc/proxmox-ha-mqtt.env
```

This file is parsed by both daemons at startup and should be readable only by root.

It uses a small `KEY="value"` parser, not a full shell interpreter - no
`export`, command substitution, or variable interpolation. Keep it in the
same plain format as `examples/proxmox-ha-mqtt.env.example`.

## Variables

| Variable | Required | Used by | Meaning |
|---|---:|---|---|
| `MQTT_HOST` | yes | both | MQTT broker host/IP. For HA Mosquitto add-on, usually the HA IP address. |
| `MQTT_PORT` | no | both | MQTT port. Defaults to `1883`. |
| `MQTT_USER` | no | both | MQTT username. Recommended. |
| `MQTT_PASS` | no | both | MQTT password. Recommended. |
| `NODE_NAME` | no | both | Logical Proxmox node name. Defaults to `hostname -s`. |
| `DISCOVERY_PREFIX` | no | both | MQTT Discovery prefix. Home Assistant default is usually `homeassistant`. |
| `BASE_TOPIC` | no | hwmon | State topic base for `sensors -j` exporter. |
| `SMART_BASE_TOPIC` | no | SMART | State topic base for SMART/NVMe exporter. |
| `HWMON_INTERVAL_SECONDS` | no | hwmon | Seconds between hwmon publish cycles. Defaults to `60`. |
| `SMART_INTERVAL_SECONDS` | no | SMART | Seconds between SMART publish cycles. Defaults to `300`. |

Changing an interval only takes effect after `systemctl restart
proxmox-ha-hwmon.service` / `proxmox-ha-smart.service` - both daemons read
the env file once at startup, since they no longer get re-invoked
periodically by a systemd timer.

## Example

```bash
MQTT_HOST="192.168.1.100"
MQTT_PORT="1883"
MQTT_USER="proxmox_mqtt"
MQTT_PASS="change_me"

NODE_NAME="pve"
DISCOVERY_PREFIX="homeassistant"

BASE_TOPIC="proxmox/pve/hwmon"
SMART_BASE_TOPIC="proxmox/pve/smart"

HWMON_INTERVAL_SECONDS="60"
SMART_INTERVAL_SECONDS="300"
```

## Topic naming

Default state topics:

```text
proxmox/<node>/hwmon/...
proxmox/<node>/smart/...
```

Default discovery topics:

```text
homeassistant/sensor/...
homeassistant/binary_sensor/...
```

## Entity naming caveat

Home Assistant entity IDs are generated from MQTT Discovery object IDs. Disk entity IDs include model/serial-derived values. If your disk serials differ, dashboard entity IDs must be adjusted.

Examples from one reference setup:

```text
sensor.proxmox_pve_disk_samsung_ssd_980_1tb_s649nu0w940418m_temperature_current
sensor.proxmox_pve_disk_st4000vn006_3cw104_zw60skhl_ata_current_pending_sector
sensor.proxmox_pve_hardware_proxmox_pve_k10temp_pci_00c3_tctl_temperature
```
