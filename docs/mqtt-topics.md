# MQTT topics and Home Assistant discovery

Both exporters hold a single MQTT connection open for their whole run and
publish discovery configs once (right after startup, or the first time a
new `unique_id` appears), then only state values on every following cycle.

## hwmon exporter

Script:

```text
scripts/proxmox-ha-hwmon-daemon.py
```

Source command:

```bash
sensors -j
```

Default availability topic:

```text
proxmox/pve/hwmon/availability
```

This is the daemon's MQTT Last Will topic: the broker publishes `offline`
here automatically if the daemon disconnects uncleanly (crash, lost
network, host power loss), in addition to the daemon publishing `online`
itself right after connecting.

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
scripts/proxmox-ha-smart-daemon.py
```

Disk discovery command:

```bash
smartctl --scan-open
```

Per-disk read command:

```bash
smartctl -a -j <scan arguments>
```

Default availability topic:

```text
proxmox/pve/smart/availability
```

> **Changed from per-disk to daemon-wide.** The SMART exporter used to
> publish a separate `proxmox/<node>/smart/<disk_key>/availability` topic
> per disk, retained `online` and never actually flipped to `offline` by
> anything. The daemon now holds one MQTT connection for all disks, so
> there is one Last Will topic shared by every disk's `availability_topic`
> - the broker sets it `offline` for real if the daemon disconnects
> uncleanly. Upgrading from the old shell scripts leaves the old per-disk
> `.../availability` topics retained and orphaned on the broker (nothing
> references them anymore); clear them manually if you want, e.g.
> `mosquitto_pub -r -n -t 'proxmox/pve/smart/<disk_key>/availability'`.

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
