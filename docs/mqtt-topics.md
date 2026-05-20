# MQTT topics and Home Assistant discovery

## hwmon exporter

Script:

```text
scripts/proxmox-ha-hwmon-mqtt.sh
```

Source command:

```bash
sensors -j
```

Default availability topic:

```text
proxmox/pve/hwmon/availability
```

Default state topic pattern:

```text
proxmox/pve/hwmon/<sensor_id>/state
```

Default discovery topic pattern:

```text
homeassistant/sensor/proxmox_<sensor_id>/config
homeassistant/binary_sensor/proxmox_<sensor_id>/config
```

Classification logic:

| `sensors -j` field | Home Assistant component | Unit | Device class |
|---|---|---:|---|
| `temp*_input`, `temp*_max`, `temp*_min`, `temp*_crit` | `sensor` | `°C` | `temperature` |
| `in*_input` | `sensor` | `V` | `voltage` |
| `power*_input` | `sensor` | `W` | `power` |
| `current*_input`, `curr*_input` | `sensor` | `A` | `current` |
| `fan*_input` | `sensor` | `RPM` | none |
| `*_alarm` | `binary_sensor` | none | `problem` |
| other numeric fields | `sensor` | none | none |

## SMART exporter

Script:

```text
scripts/proxmox-ha-smart-mqtt.sh
```

Disk discovery command:

```bash
smartctl --scan-open
```

Per-disk read command:

```bash
smartctl -a -j <scan arguments>
```

Default availability topic pattern:

```text
proxmox/pve/smart/<disk_key>/availability
```

Default state topic pattern:

```text
proxmox/pve/smart/<disk_key>/<metric>/state
```

Default discovery topic pattern:

```text
homeassistant/sensor/proxmox_<disk_key>_<metric>/config
homeassistant/binary_sensor/proxmox_<disk_key>_<metric>/config
```

## Useful listener commands

All Proxmox telemetry:

```bash
source /etc/proxmox-ha-mqtt.env

mosquitto_sub \
  -h "$MQTT_HOST" \
  -p "$MQTT_PORT" \
  -u "$MQTT_USER" \
  -P "$MQTT_PASS" \
  -t 'proxmox/pve/#' \
  -v
```

Home Assistant discovery:

```bash
source /etc/proxmox-ha-mqtt.env

mosquitto_sub \
  -h "$MQTT_HOST" \
  -p "$MQTT_PORT" \
  -u "$MQTT_USER" \
  -P "$MQTT_PASS" \
  -t 'homeassistant/#' \
  -v
```
