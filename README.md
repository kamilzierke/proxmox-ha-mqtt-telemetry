# Proxmox HA MQTT Telemetry

Publish Proxmox host hardware telemetry to Home Assistant over MQTT.

This project exports host-level telemetry that Home Assistant usually cannot see from inside a VM:

- `lm-sensors` / `sensors -j` hardware telemetry: CPU, GPU/APU, NVMe hwmon, voltage, power and alarm data.
- `smartctl -j` SMART/NVMe disk health: disk temperature, SMART pass/fail, NVMe warnings, media errors, unsafe shutdowns, ATA sector counters and CRC errors.
- MQTT Discovery payloads, so Home Assistant can create entities automatically.
- systemd timer units for scheduled publishing.
- an example Home Assistant `sections` dashboard using Mushroom cards and card-mod.

<p align="center">
<img width="1318" height="1277" alt="7afcd35d-7ba0-4d67-9b0a-e6c41b72696a" src="https://github.com/user-attachments/assets/f18e1965-1929-47f8-9d00-8045e675fae5" />

</p>

Data flow:

```text
Proxmox host -> local daemons -> MQTT broker -> Home Assistant entities/dashboard
```

Both exporters are long-running Python daemons managed by systemd (`Type=simple`,
`Restart=always`), not one-shot scripts fired by a timer. Each holds a single
MQTT connection open for its whole lifetime and sets a Last Will, so Home
Assistant is told `offline` by the broker itself if the daemon dies or the
host loses power — not just when someone remembers to publish it.

No Proxmox API write permissions are required. The scripts do not start, stop, reboot, modify, or manage VMs/containers.

## Documentation

Start here:

- [Installation](docs/installation.md) — packages, file placement, systemd units and first run.
- [Configuration](docs/configuration.md) — `/etc/proxmox-ha-mqtt.env`, MQTT variables and entity naming notes.
- [MQTT topics](docs/mqtt-topics.md) — state topics, discovery topics and metric classification.
- [Dashboard](docs/dashboard.md) — Home Assistant `sections` YAML, Mushroom/card-mod requirements and entity ID caveats.
- [Security](docs/security.md) — permissions, secret handling and pre-publish checks.
- [Troubleshooting](docs/troubleshooting.md) — MQTT, script, systemd and discovery diagnostics.

## Repository layout

```text
.
├── scripts/
│   ├── proxmox-ha-hwmon-daemon.py
│   ├── proxmox-ha-smart-daemon.py
│   └── proxmox_ha_common.py
├── systemd/
│   ├── proxmox-ha-hwmon.service
│   └── proxmox-ha-smart.service
├── examples/
│   └── proxmox-ha-mqtt.env.example
├── dashboards/
│   └── proxmox-hardware-dashboard.example.yaml
├── assets/
│   └── dashboard-example.jpg
└── docs/
    ├── installation.md
    ├── configuration.md
    ├── dashboard.md
    ├── mqtt-topics.md
    ├── security.md
    └── troubleshooting.md
```

## Quick install

On the Proxmox host:

```bash
apt update
apt install -y lm-sensors python3 python3-paho-mqtt mosquitto-clients smartmontools

install -m 700 scripts/proxmox-ha-hwmon-daemon.py /usr/local/sbin/proxmox-ha-hwmon-daemon.py
install -m 700 scripts/proxmox-ha-smart-daemon.py /usr/local/sbin/proxmox-ha-smart-daemon.py
install -m 644 scripts/proxmox_ha_common.py /usr/local/sbin/proxmox_ha_common.py

install -m 644 systemd/proxmox-ha-hwmon.service /etc/systemd/system/proxmox-ha-hwmon.service
install -m 644 systemd/proxmox-ha-smart.service /etc/systemd/system/proxmox-ha-smart.service

install -m 600 examples/proxmox-ha-mqtt.env.example /etc/proxmox-ha-mqtt.env
nano /etc/proxmox-ha-mqtt.env

systemctl daemon-reload
systemctl enable --now proxmox-ha-hwmon.service proxmox-ha-smart.service
```

Full installation notes are in [docs/installation.md](docs/installation.md).

## Required Home Assistant side

You need:

- MQTT integration configured in Home Assistant.
- A reachable MQTT broker, for example the Mosquitto broker add-on.
- MQTT Discovery enabled.
- For the example dashboard only:
  - Mushroom Cards
  - card-mod

## Security

Do **not** commit your real `/etc/proxmox-ha-mqtt.env` file.

It contains MQTT credentials. This repository includes only [`examples/proxmox-ha-mqtt.env.example`](examples/proxmox-ha-mqtt.env.example).

Recommended file permissions on the Proxmox host:

```text
-rwx------ root:root /usr/local/sbin/proxmox-ha-hwmon-daemon.py
-rwx------ root:root /usr/local/sbin/proxmox-ha-smart-daemon.py
-rw-r--r-- root:root /usr/local/sbin/proxmox_ha_common.py
-rw------- root:root /etc/proxmox-ha-mqtt.env
```

More security notes: [docs/security.md](docs/security.md).

## Script overview

Both daemons hold one MQTT connection open for their entire run (instead of
spawning a new connection per metric) and loop internally on
`HWMON_INTERVAL_SECONDS` / `SMART_INTERVAL_SECONDS`. MQTT Discovery configs
are only (re-)published when a `unique_id` wasn't seen yet in the current
process (always true right after a restart, so retained discovery
self-heals); every cycle after that publishes state values only.

### [`scripts/proxmox-ha-hwmon-daemon.py`](scripts/proxmox-ha-hwmon-daemon.py)

Reads:

```bash
sensors -j
```

Publishes numeric hwmon values as MQTT Discovery entities:

- `temp*_input`, `temp*_max`, `temp*_min`, `temp*_crit` -> temperature sensors.
- `in*_input` -> voltage sensors.
- `power*_input` -> power sensors.
- `current*_input` / `curr*_input` -> current sensors.
- `fan*_input` -> RPM sensors.
- `*_alarm` -> binary problem sensors.
- other numeric values -> diagnostic sensors.

### [`scripts/proxmox-ha-smart-daemon.py`](scripts/proxmox-ha-smart-daemon.py)

Reads disks from:

```bash
smartctl --scan-open
```

Then calls:

```bash
smartctl -a -j <scan arguments>
```

Publishes selected SMART/NVMe metrics:

- SMART pass/fail as binary sensors.
- disk temperature.
- power-on hours and power cycle count.
- NVMe critical warning, available spare, percentage used, media errors, error log entries, unsafe shutdowns, data read/written.
- curated ATA counters such as reallocated sectors, pending sectors, offline uncorrectable, UDMA CRC errors, load cycle count.

The SMART exporter intentionally does **not** publish every ATA raw value, because many vendors encode raw SMART values in vendor-specific ways.

## Validation

```bash
python3 -m py_compile /usr/local/sbin/proxmox-ha-hwmon-daemon.py
python3 -m py_compile /usr/local/sbin/proxmox-ha-smart-daemon.py

# Run in the foreground, Ctrl+C to stop:
/usr/local/sbin/proxmox-ha-hwmon-daemon.py
/usr/local/sbin/proxmox-ha-smart-daemon.py

systemctl status proxmox-ha-hwmon.service --no-pager
systemctl status proxmox-ha-smart.service --no-pager
journalctl -u proxmox-ha-hwmon.service -n 100 --no-pager
journalctl -u proxmox-ha-smart.service -n 100 --no-pager
```

More diagnostics: [docs/troubleshooting.md](docs/troubleshooting.md).

## Tested environment

Initial working setup:

```text
lm-sensors         1:3.6.0-7.1
python3-paho-mqtt  1.6.1-1
mosquitto-clients  2.0.11-1.2+deb12u2
smartmontools      7.3-pve1
```

Known hardware from the reference setup:

- AMD `k10temp` CPU telemetry
- AMDGPU hwmon telemetry
- NVMe hwmon telemetry
- MediaTek MT7921 temperature telemetry
- Samsung SSD 980 1TB NVMe SMART
- Seagate IronWolf ST4000VN006 SATA SMART

Your entity names and dashboard IDs will differ if your disks, serial numbers, node name, or MQTT topics differ.

## License

MIT. Use at your own risk. Monitoring is read-only, but shell scripts running as root on a hypervisor are still sharp tools.
