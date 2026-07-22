# Troubleshooting

## 1. Validate files and permissions

```bash
ls -lah \
  /etc/proxmox-ha-mqtt.env \
  /usr/local/sbin/proxmox-ha-hwmon-daemon.py \
  /usr/local/sbin/proxmox-ha-smart-daemon.py \
  /usr/local/sbin/proxmox_ha_common.py \
  /etc/systemd/system/proxmox-ha-hwmon.service \
  /etc/systemd/system/proxmox-ha-smart.service

stat -c '%A %U:%G %n' \
  /usr/local/sbin/proxmox-ha-hwmon-daemon.py \
  /usr/local/sbin/proxmox-ha-smart-daemon.py \
  /etc/proxmox-ha-mqtt.env
```

Recommended:

```text
-rwx------ root:root /usr/local/sbin/proxmox-ha-hwmon-daemon.py
-rwx------ root:root /usr/local/sbin/proxmox-ha-smart-daemon.py
-rw------- root:root /etc/proxmox-ha-mqtt.env
```

## 2. Show config without leaking password

```bash
echo "### /etc/proxmox-ha-mqtt.env — redacted"
sed -E 's/^(MQTT_PASS=).*/\1"***REDACTED***"/' /etc/proxmox-ha-mqtt.env
```

## 3. Validate script syntax

```bash
python3 -m py_compile /usr/local/sbin/proxmox-ha-hwmon-daemon.py
echo "hwmon syntax exit=$?"

python3 -m py_compile /usr/local/sbin/proxmox-ha-smart-daemon.py
echo "smart syntax exit=$?"
```

Expected:

```text
hwmon syntax exit=0
smart syntax exit=0
```

## 4. Check dependencies

```bash
for cmd in sensors smartctl python3 systemctl; do
  printf "%-15s " "$cmd"
  command -v "$cmd" || echo "MISSING"
done

python3 -c "import paho.mqtt.client" && echo "paho-mqtt: OK" || echo "paho-mqtt: MISSING"

dpkg -l lm-sensors python3-paho-mqtt mosquitto-clients smartmontools | awk '/^ii/ {print $2, $3}'
```

## 5. Check local sensor sources

```bash
sensors
sensors -j
smartctl --scan-open
```

## 6. Test MQTT network path

```bash
source /etc/proxmox-ha-mqtt.env

nc -vz "$MQTT_HOST" "$MQTT_PORT"
```

Interpretation:

| Result | Meaning |
|---|---|
| `succeeded` | TCP path to broker works. |
| `timed out` | wrong IP, firewall, VLAN, routing, broker unreachable. |
| `connection refused` | host reachable, broker not listening on that port. |

## 7. Test MQTT authentication and publish

```bash
source /etc/proxmox-ha-mqtt.env

mosquitto_pub -d \
  -h "$MQTT_HOST" \
  -p "$MQTT_PORT" \
  -u "$MQTT_USER" \
  -P "$MQTT_PASS" \
  -t "debug/proxmox/test" \
  -m "hello-from-proxmox-$(date -Is)"
```

Expected debug output:

```text
Client null sending CONNECT
Client null received CONNACK (0)
Client null sending PUBLISH
Client null sending DISCONNECT
```

`Connection Refused: not authorised` means invalid MQTT user/password or broker ACL.

## 8. Run exporters manually

Each daemon runs in the foreground and loops forever - it will not exit on
its own. Run it, confirm at least one publish cycle happened, then stop it
with Ctrl+C.

```bash
/usr/local/sbin/proxmox-ha-hwmon-daemon.py
# Ctrl+C once you see a cycle of "INFO: sensor ... = ..." lines

/usr/local/sbin/proxmox-ha-smart-daemon.py
# Ctrl+C once you see a cycle of "INFO: proxmox_... = ..." lines
```

If it exits immediately instead of looping, read the last log line - it is
almost always a missing `MQTT_HOST`, an unreachable broker, or a missing
`sensors`/`smartctl` command.

## 9. Listen to telemetry topics

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

In a second shell, run:

```bash
/usr/local/sbin/proxmox-ha-hwmon-daemon.py
/usr/local/sbin/proxmox-ha-smart-daemon.py
```

## 10. Listen to Home Assistant MQTT Discovery

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

If `proxmox/pve/#` appears but `homeassistant/#` does not, note that discovery
configs are now only (re-)published once per daemon start, or the first
time a new `unique_id` shows up - restart the service
(`systemctl restart proxmox-ha-hwmon.service`) to force a full discovery
republish if you suspect retained configs were lost or are stale.

If both appear but Home Assistant has no entities, check MQTT Discovery in Home Assistant.

## 11. Check systemd services

These are long-running services, not timers - there is no `systemctl
list-timers` entry for them anymore.

```bash
systemctl status proxmox-ha-hwmon.service --no-pager
systemctl status proxmox-ha-smart.service --no-pager
```

A healthy service shows `Active: active (running)` continuously, not
`inactive (dead)` between runs.

## 12. Read logs

```bash
journalctl -u proxmox-ha-hwmon.service -n 100 --no-pager
journalctl -u proxmox-ha-smart.service -n 150 --no-pager
```

Live follow:

```bash
journalctl -u proxmox-ha-hwmon.service -f
journalctl -u proxmox-ha-smart.service -f
```

## 13. Verify the Last Will (offline detection)

Each daemon sets an MQTT Last Will on its availability topic, so the broker
reports `offline` on an unclean disconnect - not only when the daemon
publishes `online` itself.

```bash
mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" \
  -t 'proxmox/pve/hwmon/availability' -t 'proxmox/pve/smart/availability' -v

# In another shell, simulate a crash (not a graceful stop):
systemctl kill -s SIGKILL proxmox-ha-hwmon.service
```

Expect `offline` to appear on `proxmox/pve/hwmon/availability` within a few
seconds (the broker's keepalive timeout), followed by `online` again once
`Restart=always` brings the service back up. A graceful
`systemctl stop proxmox-ha-hwmon.service` also publishes `offline`
explicitly before disconnecting.
