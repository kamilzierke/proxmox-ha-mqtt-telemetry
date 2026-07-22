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
: "${SMART_BASE_TOPIC:=proxmox/${NODE_NAME}/smart}"

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
      -t) topic="$2"; shift 2 ;;
      -m) message="$2"; shift 2 ;;
      -r) retain=1; shift ;;
      *) echo "ERROR: Unknown publish arg: $1" >&2; return 1 ;;
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

mqtt_config_sensor() {
  local name="$1"
  local unique_id="$2"
  local state_topic="$3"
  local availability_topic="$4"
  local device_id="$5"
  local device_name="$6"
  local model="$7"
  local manufacturer="$8"
  local sw_version="$9"
  local unit="${10}"
  local device_class="${11}"
  local state_class="${12}"
  local entity_category="${13}"

  jq -nc \
    --arg name "$name" \
    --arg unique_id "$unique_id" \
    --arg state_topic "$state_topic" \
    --arg availability_topic "$availability_topic" \
    --arg device_id "$device_id" \
    --arg device_name "$device_name" \
    --arg model "$model" \
    --arg manufacturer "$manufacturer" \
    --arg sw_version "$sw_version" \
    --arg unit "$unit" \
    --arg device_class "$device_class" \
    --arg state_class "$state_class" \
    --arg entity_category "$entity_category" \
    '{
      name: $name,
      unique_id: $unique_id,
      object_id: $unique_id,
      state_topic: $state_topic,
      availability_topic: $availability_topic,
      payload_available: "online",
      payload_not_available: "offline",
      expire_after: 1800,
      entity_category: $entity_category,
      device: {
        identifiers: [$device_id],
        name: $device_name,
        manufacturer: $manufacturer,
        model: $model,
        sw_version: $sw_version
      }
    }
    + (if $unit != "" then {unit_of_measurement: $unit} else {} end)
    + (if $device_class != "" then {device_class: $device_class} else {} end)
    + (if $state_class != "" then {state_class: $state_class} else {} end)'
}

mqtt_config_binary() {
  local name="$1"
  local unique_id="$2"
  local state_topic="$3"
  local availability_topic="$4"
  local device_id="$5"
  local device_name="$6"
  local model="$7"
  local manufacturer="$8"
  local sw_version="$9"

  jq -nc \
    --arg name "$name" \
    --arg unique_id "$unique_id" \
    --arg state_topic "$state_topic" \
    --arg availability_topic "$availability_topic" \
    --arg device_id "$device_id" \
    --arg device_name "$device_name" \
    --arg model "$model" \
    --arg manufacturer "$manufacturer" \
    --arg sw_version "$sw_version" \
    '{
      name: $name,
      unique_id: $unique_id,
      object_id: $unique_id,
      state_topic: $state_topic,
      availability_topic: $availability_topic,
      payload_available: "online",
      payload_not_available: "offline",
      payload_on: "1",
      payload_off: "0",
      device_class: "problem",
      entity_category: "diagnostic",
      expire_after: 1800,
      device: {
        identifiers: [$device_id],
        name: $device_name,
        manufacturer: $manufacturer,
        model: $model,
        sw_version: $sw_version
      }
    }'
}

emit_metric() {
  local disk_key="$1"
  local avail_topic="$2"
  local device_id="$3"
  local device_name="$4"
  local model="$5"
  local manufacturer="$6"
  local firmware="$7"
  local component="$8"
  local key="$9"
  local name="${10}"
  local value="${11}"
  local unit="${12}"
  local device_class="${13}"
  local state_class="${14}"

  if [[ -z "$value" || "$value" == "null" ]]; then
    return 0
  fi

  local key_slug unique_id state_topic config_topic payload
  key_slug="$(printf '%s' "$key" | slugify)"
  unique_id="proxmox_${disk_key}_${key_slug}"
  state_topic="${SMART_BASE_TOPIC}/${disk_key}/${key_slug}/state"

  if [[ "$component" == "binary_sensor" ]]; then
    config_topic="${DISCOVERY_PREFIX}/binary_sensor/${unique_id}/config"
    payload="$(mqtt_config_binary "$name" "$unique_id" "$state_topic" "$avail_topic" "$device_id" "$device_name" "$model" "$manufacturer" "$firmware")"
  else
    config_topic="${DISCOVERY_PREFIX}/sensor/${unique_id}/config"
    payload="$(mqtt_config_sensor "$name" "$unique_id" "$state_topic" "$avail_topic" "$device_id" "$device_name" "$model" "$manufacturer" "$firmware" "$unit" "$device_class" "$state_class" "diagnostic")"
  fi

  echo "INFO: ${unique_id} = ${value}"
  publish -t "$config_topic" -m "$payload" -r
  publish -t "$state_topic" -m "$value" -r
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing command: $1" >&2
    exit 1
  }
}

require_cmd smartctl
require_cmd jq
require_cmd mosquitto_pub

SCAN_OUTPUT="$(smartctl --scan-open | sed -E 's/[[:space:]]*#.*$//' | awk 'NF')"

if [[ -z "$SCAN_OUTPUT" ]]; then
  echo "ERROR: smartctl --scan-open found no disks" >&2
  exit 1
fi

echo "$SCAN_OUTPUT" | while IFS= read -r scan_line; do
  [[ -z "$scan_line" ]] && continue

  read -r -a SMART_ARGS <<< "$scan_line"
  dev="${SMART_ARGS[0]}"

  tmp_json="$(mktemp)"
  smart_exit=0

  if ! smartctl -a -j "${SMART_ARGS[@]}" >"$tmp_json"; then
    smart_exit=$?
  fi

  if ! jq empty "$tmp_json" >/dev/null 2>&1; then
    echo "WARN: invalid JSON from smartctl for ${dev}; skipping" >&2
    rm -f "$tmp_json"
    continue
  fi

  dev_base="$(basename "$dev")"
  model="$(jq -r '.model_name // .model_family // .device.model_name // "Unknown disk"' "$tmp_json")"
  serial="$(jq -r '.serial_number // .device.serial_number // empty' "$tmp_json")"
  firmware="$(jq -r '.firmware_version // empty' "$tmp_json")"
  vendor="$(jq -r '.vendor // .device.protocol // "Disk"' "$tmp_json")"
  protocol="$(jq -r '.device.protocol // .device.type // "unknown"' "$tmp_json")"

  if [[ -n "$serial" ]]; then
    disk_key="$(printf '%s_%s' "$NODE_NAME" "$serial" | slugify)"
  else
    disk_key="$(printf '%s_%s' "$NODE_NAME" "$dev_base" | slugify)"
  fi

  device_id="proxmox_${disk_key}_disk"
  device_name="Proxmox ${NODE_NAME} disk ${model}"
  if [[ -n "$serial" ]]; then
    device_name+=" ${serial}"
  else
    device_name+=" ${dev_base}"
  fi

  avail_topic="${SMART_BASE_TOPIC}/${disk_key}/availability"

  echo "INFO: Disk ${dev}: ${model} ${serial} protocol=${protocol}"
  publish -t "$avail_topic" -m "online" -r

  # Common metrics.
  while IFS=$'\t' read -r component key name value unit device_class state_class; do
    emit_metric "$disk_key" "$avail_topic" "$device_id" "$device_name" "$model" "$vendor" "$firmware" \
      "$component" "$key" "$name" "$value" "$unit" "$device_class" "$state_class"
  done < <(jq -r --arg smart_exit "$smart_exit" '
    def emit($component;$key;$name;$value;$unit;$device_class;$state_class):
      if $value == null then empty
      else [$component,$key,$name,($value|tostring),$unit,$device_class,$state_class] | @tsv
      end;

    emit("sensor"; "smartctl_exit_status"; "smartctl exit status"; (.smartctl.exit_status // ($smart_exit|tonumber)); ""; ""; "measurement"),
    emit("binary_sensor"; "smart_failed"; "SMART failed"; (if .smart_status.passed == true then 0 elif .smart_status.passed == false then 1 else null end); ""; "problem"; ""),
    emit("sensor"; "temperature_current"; "Temperature current"; .temperature.current; "°C"; "temperature"; "measurement"),
    emit("sensor"; "power_on_hours"; "Power on hours"; .power_on_time.hours; "h"; "duration"; "total_increasing"),
    emit("sensor"; "power_cycle_count"; "Power cycle count"; .power_cycle_count; ""; ""; "total_increasing"),
    emit("sensor"; "user_capacity_bytes"; "User capacity"; .user_capacity.bytes; "B"; "data_size"; "measurement")
  ' "$tmp_json")

  # NVMe metrics.
  while IFS=$'\t' read -r component key name value unit device_class state_class; do
    emit_metric "$disk_key" "$avail_topic" "$device_id" "$device_name" "$model" "$vendor" "$firmware" \
      "$component" "$key" "$name" "$value" "$unit" "$device_class" "$state_class"
  done < <(jq -r '
    def emit($component;$key;$name;$value;$unit;$device_class;$state_class):
      if $value == null then empty
      else [$component,$key,$name,($value|tostring),$unit,$device_class,$state_class] | @tsv
      end;

    .nvme_smart_health_information_log as $n |
    if $n == null then empty else
      emit("sensor"; "nvme_critical_warning_raw"; "NVMe critical warning raw"; $n.critical_warning; ""; ""; "measurement"),
      emit("binary_sensor"; "nvme_critical_warning_problem"; "NVMe critical warning"; (if $n.critical_warning == 0 then 0 else 1 end); ""; "problem"; ""),
      emit("sensor"; "nvme_temperature"; "NVMe temperature"; $n.temperature; "°C"; "temperature"; "measurement"),
      emit("sensor"; "nvme_temperature_sensor_1"; "NVMe temperature sensor 1"; $n.temperature_sensors[0]; "°C"; "temperature"; "measurement"),
      emit("sensor"; "nvme_temperature_sensor_2"; "NVMe temperature sensor 2"; $n.temperature_sensors[1]; "°C"; "temperature"; "measurement"),
      emit("sensor"; "nvme_available_spare"; "NVMe available spare"; $n.available_spare; "%"; ""; "measurement"),
      emit("sensor"; "nvme_available_spare_threshold"; "NVMe available spare threshold"; $n.available_spare_threshold; "%"; ""; "measurement"),
      emit("sensor"; "nvme_percentage_used"; "NVMe percentage used"; $n.percentage_used; "%"; ""; "measurement"),
      emit("sensor"; "nvme_data_units_read"; "NVMe data units read"; $n.data_units_read; ""; ""; "total_increasing"),
      emit("sensor"; "nvme_data_units_written"; "NVMe data units written"; $n.data_units_written; ""; ""; "total_increasing"),
      emit("sensor"; "nvme_data_read_tb"; "NVMe data read"; (if $n.data_units_read == null then null else ($n.data_units_read * 512000 / 1000000000000) end); "TB"; "data_size"; "total_increasing"),
      emit("sensor"; "nvme_data_written_tb"; "NVMe data written"; (if $n.data_units_written == null then null else ($n.data_units_written * 512000 / 1000000000000) end); "TB"; "data_size"; "total_increasing"),
      emit("sensor"; "nvme_host_reads"; "NVMe host reads"; $n.host_reads; ""; ""; "total_increasing"),
      emit("sensor"; "nvme_host_writes"; "NVMe host writes"; $n.host_writes; ""; ""; "total_increasing"),
      emit("sensor"; "nvme_controller_busy_time"; "NVMe controller busy time"; $n.controller_busy_time; "min"; "duration"; "total_increasing"),
      emit("sensor"; "nvme_power_cycles"; "NVMe power cycles"; $n.power_cycles; ""; ""; "total_increasing"),
      emit("sensor"; "nvme_power_on_hours"; "NVMe power on hours"; $n.power_on_hours; "h"; "duration"; "total_increasing"),
      emit("sensor"; "nvme_unsafe_shutdowns"; "NVMe unsafe shutdowns"; $n.unsafe_shutdowns; ""; ""; "total_increasing"),
      emit("sensor"; "nvme_media_errors"; "NVMe media errors"; $n.media_errors; ""; ""; "total_increasing"),
      emit("sensor"; "nvme_error_log_entries"; "NVMe error log entries"; $n.num_err_log_entries; ""; ""; "total_increasing"),
      emit("sensor"; "nvme_warning_temp_time"; "NVMe warning temperature time"; $n.warning_temp_time; "min"; "duration"; "total_increasing"),
      emit("sensor"; "nvme_critical_comp_time"; "NVMe critical composite temperature time"; $n.critical_comp_time; "min"; "duration"; "total_increasing")
    end
  ' "$tmp_json")

  # ATA/SATA curated metrics. Nie eksportujemy ślepo każdego raw.value.
  while IFS=$'\t' read -r component key name value unit device_class state_class; do
    emit_metric "$disk_key" "$avail_topic" "$device_id" "$device_name" "$model" "$vendor" "$firmware" \
      "$component" "$key" "$name" "$value" "$unit" "$device_class" "$state_class"
  done < <(jq -r '
    def emit($component;$key;$name;$value;$unit;$device_class;$state_class):
      if $value == null then empty
      else [$component,$key,$name,($value|tostring),$unit,$device_class,$state_class] | @tsv
      end;

    def attr($id): .ata_smart_attributes.table[]? | select(.id == $id);
    (.logical_block_size // 512) as $lbs |

    emit("sensor"; "ata_error_log_count"; "ATA SMART error log count"; .ata_smart_error_log.summary.count; ""; ""; "total_increasing"),
    emit("binary_sensor"; "ata_self_test_failed"; "ATA self-test failed"; (if .ata_smart_data.self_test.status.passed == true then 0 elif .ata_smart_data.self_test.status.passed == false then 1 else null end); ""; "problem"; ""),
    emit("sensor"; "ata_short_self_test_minutes"; "ATA short self-test duration"; .ata_smart_data.self_test.polling_minutes.short; "min"; "duration"; "measurement"),
    emit("sensor"; "ata_extended_self_test_minutes"; "ATA extended self-test duration"; .ata_smart_data.self_test.polling_minutes.extended; "min"; "duration"; "measurement"),

    (attr(5)   | emit("sensor"; "ata_reallocated_sector_count"; "ATA reallocated sector count"; .raw.value; ""; ""; "measurement")),
    (attr(10)  | emit("sensor"; "ata_spin_retry_count"; "ATA spin retry count"; .raw.value; ""; ""; "measurement")),
    (attr(183) | emit("sensor"; "ata_runtime_bad_block"; "ATA runtime bad block"; .raw.value; ""; ""; "measurement")),
    (attr(184) | emit("sensor"; "ata_end_to_end_error"; "ATA end-to-end error"; .raw.value; ""; ""; "measurement")),
    (attr(187) | emit("sensor"; "ata_reported_uncorrect"; "ATA reported uncorrectable"; .raw.value; ""; ""; "measurement")),
    (attr(188) | emit("sensor"; "ata_command_timeout"; "ATA command timeout"; .raw.value; ""; ""; "measurement")),
    (attr(191) | emit("sensor"; "ata_g_sense_error_rate"; "ATA G-sense error rate"; .raw.value; ""; ""; "measurement")),
    (attr(192) | emit("sensor"; "ata_power_off_retract_count"; "ATA power-off retract count"; .raw.value; ""; ""; "measurement")),
    (attr(193) | emit("sensor"; "ata_load_cycle_count"; "ATA load cycle count"; .raw.value; ""; ""; "measurement")),
    (attr(197) | emit("sensor"; "ata_current_pending_sector"; "ATA current pending sector"; .raw.value; ""; ""; "measurement")),
    (attr(198) | emit("sensor"; "ata_offline_uncorrectable"; "ATA offline uncorrectable"; .raw.value; ""; ""; "measurement")),
    (attr(199) | emit("sensor"; "ata_udma_crc_error_count"; "ATA UDMA CRC error count"; .raw.value; ""; ""; "measurement")),
    (attr(241) | emit("sensor"; "ata_total_lbas_written"; "ATA total LBAs written"; .raw.value; ""; ""; "total_increasing")),
    (attr(242) | emit("sensor"; "ata_total_lbas_read"; "ATA total LBAs read"; .raw.value; ""; ""; "total_increasing")),
    (attr(241) | emit("sensor"; "ata_total_written_tb"; "ATA total written"; (.raw.value * $lbs / 1000000000000); "TB"; "data_size"; "total_increasing")),
    (attr(242) | emit("sensor"; "ata_total_read_tb"; "ATA total read"; (.raw.value * $lbs / 1000000000000); "TB"; "data_size"; "total_increasing"))
  ' "$tmp_json")

  rm -f "$tmp_json"

  if [[ "$smart_exit" -ne 0 ]]; then
    echo "WARN: smartctl exit status for ${dev}: ${smart_exit}" >&2
  fi
done
