# Security notes

This project is intentionally simple, but it still runs as root on a hypervisor - as two long-running Python daemons rather than periodic shell scripts. Treat it accordingly.

## Do not publish secrets

Never commit:

```text
/etc/proxmox-ha-mqtt.env
```

It contains MQTT credentials.

The repository includes only:

```text
examples/proxmox-ha-mqtt.env.example
```

## Recommended permissions

```bash
chmod 700 /usr/local/sbin/proxmox-ha-hwmon-daemon.py
chmod 700 /usr/local/sbin/proxmox-ha-smart-daemon.py
chmod 644 /usr/local/sbin/proxmox_ha_common.py
chmod 600 /etc/proxmox-ha-mqtt.env
chown root:root \
  /usr/local/sbin/proxmox-ha-hwmon-daemon.py \
  /usr/local/sbin/proxmox-ha-smart-daemon.py \
  /usr/local/sbin/proxmox_ha_common.py \
  /etc/proxmox-ha-mqtt.env
```

## Pre-publish secret scan

Before pushing changes:

```bash
grep -RniE 'MQTT_PASS|password|passwd|secret|token|PVEAPIToken|Authorization' .
```

Expected acceptable hits:

- `.gitignore`
- `examples/proxmox-ha-mqtt.env.example`
- documentation explaining what not to commit

Unexpected hits should be reviewed before publishing.

## MQTT account

Use a dedicated MQTT user for Proxmox telemetry when possible.

The scripts only publish telemetry; they do not need subscription rights unless you use `mosquitto_sub` manually for debugging.

## Proxmox API permissions

These exporters do not use the Proxmox API. They do not require a Proxmox user, token, role, or ACL.

They read local host data through:

```text
lm-sensors
smartmontools
```
