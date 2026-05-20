# Proxmox HA MQTT Telemetry

Publish Proxmox host hardware telemetry to Home Assistant over MQTT.

This project exports host-level data that Home Assistant usually cannot see from inside a VM:

- `lm-sensors` / `sensors -j` hardware telemetry: CPU, GPU/APU, NVMe hwmon, voltage, power and alarm data.
- `smartctl -j` SMART/NVMe disk health: disk temperature, SMART pass/fail, NVMe warnings, media errors, unsafe shutdowns, ATA sector counters and CRC errors.
- MQTT Discovery payloads, so Home Assistant can create entities automatically.
- systemd timer units for scheduled publishing.
- an example Home Assistant `sections` dashboard using Mushroom cards and card-mod.

Data flow:

```text
Proxmox host -> local scripts -> MQTT broker -> Home Assistant entities/dashboard
```

No Proxmox API write permissions are required. The scripts do not start, stop, reboot, modify, or manage VMs/containers.

## Repository layout

```text
.
├── scripts/
│   ├── proxmox-ha-hwmon-mqtt.sh
│   └── proxmox-ha-smart-mqtt.sh
├── systemd/
│   ├── proxmox-ha-hwmon.service
│   ├── proxmox-ha-hwmon.timer
│   ├── proxmox-ha-smart.service
│   └── proxmox-ha-smart.timer
├── examples/
│   └── proxmox-ha-mqtt.env.example
├── dashboards/
│   └── proxmox-hardware-dashboard.example.yaml
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
apt install -y lm-sensors jq mosquitto-clients smartmontools

install -m 700 scripts/proxmox-ha-hwmon-mqtt.sh /usr/local/sbin/proxmox-ha-hwmon-mqtt.sh
install -m 700 scripts/proxmox-ha-smart-mqtt.sh /usr/local/sbin/proxmox-ha-smart-mqtt.sh

install -m 644 systemd/proxmox-ha-hwmon.service /etc/systemd/system/proxmox-ha-hwmon.service
install -m 644 systemd/proxmox-ha-hwmon.timer /etc/systemd/system/proxmox-ha-hwmon.timer
install -m 644 systemd/proxmox-ha-smart.service /etc/systemd/system/proxmox-ha-smart.service
install -m 644 systemd/proxmox-ha-smart.timer /etc/systemd/system/proxmox-ha-smart.timer

install -m 600 examples/proxmox-ha-mqtt.env.example /etc/proxmox-ha-mqtt.env
nano /etc/proxmox-ha-mqtt.env

systemctl daemon-reload
systemctl enable --now proxmox-ha-hwmon.timer proxmox-ha-smart.timer
systemctl start proxmox-ha-hwmon.service proxmox-ha-smart.service
```

Full instructions are in `docs/installation.md`.

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

It contains MQTT credentials. This repository includes only `examples/proxmox-ha-mqtt.env.example`.

Recommended file permissions on the Proxmox host:

```text
-rwx------ root:root /usr/local/sbin/proxmox-ha-hwmon-mqtt.sh
-rwx------ root:root /usr/local/sbin/proxmox-ha-smart-mqtt.sh
-rw------- root:root /etc/proxmox-ha-mqtt.env
```

## Script overview

### `scripts/proxmox-ha-hwmon-mqtt.sh`

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

### `scripts/proxmox-ha-smart-mqtt.sh`

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
bash -n /usr/local/sbin/proxmox-ha-hwmon-mqtt.sh
bash -n /usr/local/sbin/proxmox-ha-smart-mqtt.sh

/usr/local/sbin/proxmox-ha-hwmon-mqtt.sh
/usr/local/sbin/proxmox-ha-smart-mqtt.sh

systemctl status proxmox-ha-hwmon.timer --no-pager
systemctl status proxmox-ha-smart.timer --no-pager
journalctl -u proxmox-ha-hwmon.service -n 100 --no-pager
journalctl -u proxmox-ha-smart.service -n 100 --no-pager
```

## Tested environment

Initial working setup:

```text
jq                 1.6-2.1+deb12u1
lm-sensors         1:3.6.0-7.1
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
