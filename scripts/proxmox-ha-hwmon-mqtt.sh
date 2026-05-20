#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="/etc/proxmox-ha-mqtt.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: Missing $ENV_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

: "${MQTT_HOST:?Missing MQTT_HOST}"
: "${MQTT_PORT:=1883}"
: "${NODE_NAME:=$(hostname -s)}"
: "${DISCOVERY_PREFIX:=homeassistant}"
: "${BASE_TOPIC:=proxmox/${NODE_NAME}/hwmon}"

AVAIL_TOPIC="${BASE_TOPIC}/availability"
DEVICE_ID="proxmox_${NODE_NAME}_hardware"
DEVICE_NAME="Proxmox ${NODE_NAME} hardware"

MOSQ_ARGS=(-h "$MQTT_HOST" -p "$MQTT_PORT" -q 1)

if [[ -n "${MQTT_USER:-}" ]]; then
  MOSQ_ARGS+=(-u "$MQTT_USER")
fi

if [[ -n "${MQTT_PASS:-}" ]]; then
  MOSQ_ARGS+=(-P "$MQTT_PASS")
fi

publish() {
  local topic=""
  local message=""
  local retain=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -t)
        topic="$2"
        shift 2
        ;;
      -m)
        message="$2"
        shift 2
        ;;
      -r)
        retain=1
        shift
        ;;
      *)
        echo "ERROR: Unknown publish arg: $1" >&2
        return 1
        ;;
    esac
  done

  if [[ -z "$topic" ]]; then
    echo "ERROR: publish without topic" >&2
    return 1
  fi

  if [[ "$retain" -eq 1 ]]; then
    mosquitto_pub "${MOSQ_ARGS[@]}" -r -t "$topic" -m "$message"
  else
    mosquitto_pub "${MOSQ_ARGS[@]}" -t "$topic" -m "$message"
  fi
}

slugify() {
  tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//'
}

classify_sensor() {
  local field="$1"

  # component|unit|device_class|state_class|entity_category
  case "$field" in
    temp*_input|temp*_max|temp*_min|temp*_crit)
      echo "sensor|°C|temperature|measurement|diagnostic"
      ;;
    in*_input)
      echo "sensor|V|voltage|measurement|diagnostic"
      ;;
    power*_input)
      echo "sensor|W|power|measurement|diagnostic"
      ;;
    current*_input|curr*_input)
      echo "sensor|A|current|measurement|diagnostic"
      ;;
    fan*_input)
      echo "sensor|RPM||measurement|diagnostic"
      ;;
    *_alarm)
      echo "binary_sensor|||diagnostic|diagnostic"
      ;;
    *)
      echo "sensor|||measurement|diagnostic"
      ;;
  esac
}

friendly_suffix() {
  local field="$1"

  case "$field" in
    temp*_input) echo "temperature" ;;
    temp*_max) echo "temperature max" ;;
    temp*_min) echo "temperature min" ;;
    temp*_crit) echo "temperature critical" ;;
    *_alarm) echo "alarm" ;;
    in*_input) echo "voltage" ;;
    power*_input) echo "power" ;;
    current*_input|curr*_input) echo "current" ;;
    fan*_input) echo "fan speed" ;;
    *) echo "$field" ;;
  esac
}

if ! command -v sensors >/dev/null 2>&1; then
  echo "ERROR: sensors command not found. Install lm-sensors." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq command not found." >&2
  exit 1
fi

if ! command -v mosquitto_pub >/dev/null 2>&1; then
  echo "ERROR: mosquitto_pub command not found. Install mosquitto-clients." >&2
  exit 1
fi

echo "INFO: Publishing availability to ${AVAIL_TOPIC}"
publish -t "$AVAIL_TOPIC" -m "online" -r

sensors -j | jq -r '
  to_entries[] as $chip |
  $chip.value
  | to_entries[]
  | select(.value | type == "object")
  | .key as $feature |
  .value
  | to_entries[]
  | select(.value | type == "number")
  | [$chip.key, $feature, .key, (.value | tostring)]
  | @tsv
' | while IFS=$'\t' read -r chip feature field value; do

  raw_id="${NODE_NAME}_${chip}_${feature}_${field}"
  sensor_id="$(printf '%s' "$raw_id" | slugify)"

  class="$(classify_sensor "$field")"
  component="$(cut -d'|' -f1 <<<"$class")"
  unit="$(cut -d'|' -f2 <<<"$class")"
  device_class="$(cut -d'|' -f3 <<<"$class")"
  state_class="$(cut -d'|' -f4 <<<"$class")"
  entity_category="$(cut -d'|' -f5 <<<"$class")"

  suffix="$(friendly_suffix "$field")"

  display_name="Proxmox ${NODE_NAME} ${chip} ${feature} ${suffix}"
  unique_id="proxmox_${sensor_id}"
  state_topic="${BASE_TOPIC}/${sensor_id}/state"
  config_topic="${DISCOVERY_PREFIX}/${component}/${unique_id}/config"

  if [[ "$component" == "binary_sensor" ]]; then
    payload="$(jq -nc \
      --arg name "$display_name" \
      --arg unique_id "$unique_id" \
      --arg state_topic "$state_topic" \
      --arg avail_topic "$AVAIL_TOPIC" \
      --arg device_id "$DEVICE_ID" \
      --arg device_name "$DEVICE_NAME" \
      --arg entity_category "$entity_category" \
      '{
        name: $name,
        unique_id: $unique_id,
        object_id: $unique_id,
        state_topic: $state_topic,
        availability_topic: $avail_topic,
        payload_available: "online",
        payload_not_available: "offline",
        payload_on: "1",
        payload_off: "0",
        device_class: "problem",
        entity_category: $entity_category,
        device: {
          identifiers: [$device_id],
          name: $device_name,
          manufacturer: "Proxmox VE",
          model: "Host hardware sensors"
        }
      }'
    )"
  else
    payload="$(jq -nc \
      --arg name "$display_name" \
      --arg unique_id "$unique_id" \
      --arg state_topic "$state_topic" \
      --arg avail_topic "$AVAIL_TOPIC" \
      --arg device_id "$DEVICE_ID" \
      --arg device_name "$DEVICE_NAME" \
      --arg unit "$unit" \
      --arg device_class "$device_class" \
      --arg state_class "$state_class" \
      --arg entity_category "$entity_category" \
      '{
        name: $name,
        unique_id: $unique_id,
        object_id: $unique_id,
        state_topic: $state_topic,
        availability_topic: $avail_topic,
        payload_available: "online",
        payload_not_available: "offline",
        entity_category: $entity_category,
        expire_after: 300,
        device: {
          identifiers: [$device_id],
          name: $device_name,
          manufacturer: "Proxmox VE",
          model: "Host hardware sensors"
        }
      }
      + (if $unit != "" then {unit_of_measurement: $unit} else {} end)
      + (if $device_class != "" then {device_class: $device_class} else {} end)
      + (if $state_class != "" then {state_class: $state_class} else {} end)'
    )"
  fi

  echo "INFO: ${component} ${unique_id} = ${value}"

  publish -t "$config_topic" -m "$payload" -r
  publish -t "$state_topic" -m "$value" -r

done
