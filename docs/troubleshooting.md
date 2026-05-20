# Troubleshooting

## 1. Validate files and permissions

```bash
ls -lah \
  /etc/proxmox-ha-mqtt.env \
  /usr/local/sbin/proxmox-ha-hwmon-mqtt.sh \
  /usr/local/sbin/proxmox-ha-smart-mqtt.sh \
  /etc/systemd/system/proxmox-ha-hwmon.service \
  /etc/systemd/system/proxmox-ha-hwmon.timer \
  /etc/systemd/system/proxmox-ha-smart.service \
  /etc/systemd/system/proxmox-ha-smart.timer

stat -c '%A %U:%G %n' \
  /usr/local/sbin/proxmox-ha-hwmon-mqtt.sh \
  /usr/local/sbin/proxmox-ha-smart-mqtt.sh \
  /etc/proxmox-ha-mqtt.env
```

Recommended:

```text
-rwx------ root:root /usr/local/sbin/proxmox-ha-hwmon-mqtt.sh
-rwx------ root:root /usr/local/sbin/proxmox-ha-smart-mqtt.sh
-rw------- root:root /etc/proxmox-ha-mqtt.env
```

## 2. Show config without leaking password

```bash
echo "### /etc/proxmox-ha-mqtt.env — redacted"
sed -E 's/^(MQTT_PASS=).*/\1"***REDACTED***"/' /etc/proxmox-ha-mqtt.env
```

## 3. Validate script syntax

```bash
bash -n /usr/local/sbin/proxmox-ha-hwmon-mqtt.sh
echo "hwmon syntax exit=$?"

bash -n /usr/local/sbin/proxmox-ha-smart-mqtt.sh
echo "smart syntax exit=$?"
```

Expected:

```text
hwmon syntax exit=0
smart syntax exit=0
```

## 4. Check dependencies

```bash
for cmd in sensors jq mosquitto_pub smartctl systemctl; do
  printf "%-15s " "$cmd"
  command -v "$cmd" || echo "MISSING"
done

dpkg -l lm-sensors jq mosquitto-clients smartmontools | awk '/^ii/ {print $2, $3}'
```

## 5. Check local sensor sources

```bash
sensors
sensors -j | jq
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

```bash
/usr/local/sbin/proxmox-ha-hwmon-mqtt.sh
echo "hwmon exit=$?"

/usr/local/sbin/proxmox-ha-smart-mqtt.sh
echo "smart exit=$?"
```

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
/usr/local/sbin/proxmox-ha-hwmon-mqtt.sh
/usr/local/sbin/proxmox-ha-smart-mqtt.sh
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

If `proxmox/pve/#` appears but `homeassistant/#` does not, the scripts are not publishing discovery payloads or are failing before config publish.

If both appear but Home Assistant has no entities, check MQTT Discovery in Home Assistant.

## 11. Check systemd timers

```bash
systemctl status proxmox-ha-hwmon.timer --no-pager
systemctl status proxmox-ha-smart.timer --no-pager
systemctl list-timers | grep proxmox-ha
```

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
