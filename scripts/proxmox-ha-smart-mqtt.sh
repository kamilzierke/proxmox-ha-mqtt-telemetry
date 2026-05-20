#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="/etc/proxmox-ha-mqtt.env"
[[ -f "$ENV_FILE" ]] || { echo "ERROR: Missing $ENV_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"

: "${MQTT_HOST:?Missing MQTT_HOST}"
: "${MQTT_PORT:=1883}"
: "${NODE_NAME:=$(hostname -s)}"
: "${DISCOVERY_PREFIX:=homeassistant}"
: "${SMART_BASE_TOPIC:=proxmox/${NODE_NAME}/smart}"

MQTT_ARGS=(-h "$MQTT_HOST" -p "$MQTT_PORT" -q 1)
[[ -n "${MQTT_USER:-}" ]] && MQTT_ARGS+=(-u "$MQTT_USER")
[[ -n "${MQTT_PASS:-}" ]] && MQTT_ARGS+=(-P "$MQTT_PASS")

require_cmd(){ command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing command: $1" >&2; exit 1; }; }
slugify(){ tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//'; }
pub(){ local r=0 t="" m=""; while [[ $# -gt 0 ]]; do case "$1" in -r) r=1; shift;; -t) t="$2"; shift 2;; -m) m="$2"; shift 2;; *) echo "ERROR: pub arg $1" >&2; return 1;; esac; done; [[ -n "$t" ]] || return 1; if [[ "$r" -eq 1 ]]; then mosquitto_pub "${MQTT_ARGS[@]}" -r -t "$t" -m "$m"; else mosquitto_pub "${MQTT_ARGS[@]}" -t "$t" -m "$m"; fi; }

sensor_cfg(){
  jq -nc --arg name "$1" --arg unique_id "$2" --arg state_topic "$3" --arg availability_topic "$4" --arg device_id "$5" --arg device_name "$6" --arg model "$7" --arg manufacturer "$8" --arg sw_version "$9" --arg unit "${10}" --arg device_class "${11}" --arg state_class "${12}" '{name:$name,unique_id:$unique_id,object_id:$unique_id,state_topic:$state_topic,availability_topic:$availability_topic,payload_available:"online",payload_not_available:"offline",expire_after:1800,entity_category:"diagnostic",device:{identifiers:[$device_id],name:$device_name,manufacturer:$manufacturer,model:$model,sw_version:$sw_version}} + (if $unit != "" then {unit_of_measurement:$unit} else {} end) + (if $device_class != "" then {device_class:$device_class} else {} end) + (if $state_class != "" then {state_class:$state_class} else {} end)'
}

binary_cfg(){
  jq -nc --arg name "$1" --arg unique_id "$2" --arg state_topic "$3" --arg availability_topic "$4" --arg device_id "$5" --arg device_name "$6" --arg model "$7" --arg manufacturer "$8" --arg sw_version "$9" '{name:$name,unique_id:$unique_id,object_id:$unique_id,state_topic:$state_topic,availability_topic:$availability_topic,payload_available:"online",payload_not_available:"offline",payload_on:"1",payload_off:"0",device_class:"problem",entity_category:"diagnostic",expire_after:1800,device:{identifiers:[$device_id],name:$device_name,manufacturer:$manufacturer,model:$model,sw_version:$sw_version}}'
}

emit(){
  local disk_key="$1" avail="$2" dev_id="$3" dev_name="$4" model="$5" vendor="$6" firmware="$7" component="$8" key="$9" name="${10}" value="${11}" unit="${12}" dev_class="${13}" state_class="${14}"
  [[ -z "$value" || "$value" == "null" ]] && return 0
  local key_slug unique_id state_topic config_topic payload
  key_slug="$(printf '%s' "$key" | slugify)"
  unique_id="proxmox_${disk_key}_${key_slug}"
  state_topic="${SMART_BASE_TOPIC}/${disk_key}/${key_slug}/state"
  if [[ "$component" == "binary_sensor" ]]; then
    config_topic="${DISCOVERY_PREFIX}/binary_sensor/${unique_id}/config"
    payload="$(binary_cfg "$name" "$unique_id" "$state_topic" "$avail" "$dev_id" "$dev_name" "$model" "$vendor" "$firmware")"
  else
    config_topic="${DISCOVERY_PREFIX}/sensor/${unique_id}/config"
    payload="$(sensor_cfg "$name" "$unique_id" "$state_topic" "$avail" "$dev_id" "$dev_name" "$model" "$vendor" "$firmware" "$unit" "$dev_class" "$state_class")"
  fi
  echo "INFO: ${unique_id} = ${value}"
  pub -r -t "$config_topic" -m "$payload"
  pub -r -t "$state_topic" -m "$value"
}

require_cmd smartctl
require_cmd jq
require_cmd mosquitto_pub

scan="$(smartctl --scan-open | sed -E 's/[[:space:]]*#.*$//' | awk 'NF')"
[[ -n "$scan" ]] || { echo "ERROR: smartctl --scan-open found no disks" >&2; exit 1; }

echo "$scan" | while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  read -r -a args <<< "$line"
  dev="${args[0]}"
  tmp="$(mktemp)"
  smart_exit=0
  smartctl -a -j "${args[@]}" >"$tmp" || smart_exit=$?
  jq empty "$tmp" >/dev/null 2>&1 || { echo "WARN: invalid JSON from smartctl for $dev" >&2; rm -f "$tmp"; continue; }

  dev_base="$(basename "$dev")"
  model="$(jq -r '.model_name // .model_family // .device.model_name // "Unknown disk"' "$tmp")"
  serial="$(jq -r '.serial_number // .device.serial_number // empty' "$tmp")"
  firmware="$(jq -r '.firmware_version // empty' "$tmp")"
  vendor="$(jq -r '.vendor // .device.protocol // "Disk"' "$tmp")"
  protocol="$(jq -r '.device.protocol // .device.type // "unknown"' "$tmp")"
  if [[ -n "$serial" ]]; then disk_key="$(printf '%s_%s' "$NODE_NAME" "$serial" | slugify)"; else disk_key="$(printf '%s_%s' "$NODE_NAME" "$dev_base" | slugify)"; fi
  dev_id="proxmox_${disk_key}_disk"
  dev_name="Proxmox ${NODE_NAME} disk ${model}"
  [[ -n "$serial" ]] && dev_name+=" ${serial}" || dev_name+=" ${dev_base}"
  avail="${SMART_BASE_TOPIC}/${disk_key}/availability"

  echo "INFO: Disk ${dev}: ${model} ${serial} protocol=${protocol}"
  pub -r -t "$avail" -m "online"

  jq -r --arg smart_exit "$smart_exit" '
    def emit($c;$k;$n;$v;$u;$dc;$sc): if $v == null then empty else [$c,$k,$n,($v|tostring),$u,$dc,$sc] | @tsv end;
    def attr($id): .ata_smart_attributes.table[]? | select(.id == $id);
    (.logical_block_size // 512) as $lbs |
    emit("sensor";"smartctl_exit_status";"smartctl exit status";(.smartctl.exit_status // ($smart_exit|tonumber));"";"";"measurement"),
    emit("binary_sensor";"smart_failed";"SMART failed";(if .smart_status.passed == true then 0 elif .smart_status.passed == false then 1 else null end);"";"problem";""),
    emit("sensor";"temperature_current";"Temperature current";.temperature.current;"°C";"temperature";"measurement"),
    emit("sensor";"power_on_hours";"Power on hours";.power_on_time.hours;"h";"duration";"total_increasing"),
    emit("sensor";"power_cycle_count";"Power cycle count";.power_cycle_count;"";"";"total_increasing"),
    emit("sensor";"user_capacity_bytes";"User capacity";.user_capacity.bytes;"B";"data_size";"measurement"),
    (.nvme_smart_health_information_log as $x | if $x == null then empty else
      emit("sensor";"nvme_critical_warning_raw";"NVMe critical warning raw";$x.critical_warning;"";"";"measurement"),
      emit("binary_sensor";"nvme_critical_warning";"NVMe critical warning";(if $x.critical_warning == 0 then 0 else 1 end);"";"problem";""),
      emit("sensor";"nvme_temperature";"NVMe temperature";$x.temperature;"°C";"temperature";"measurement"),
      emit("sensor";"nvme_temperature_sensor_1";"NVMe temperature sensor 1";$x.temperature_sensors[0];"°C";"temperature";"measurement"),
      emit("sensor";"nvme_temperature_sensor_2";"NVMe temperature sensor 2";$x.temperature_sensors[1];"°C";"temperature";"measurement"),
      emit("sensor";"nvme_available_spare";"NVMe available spare";$x.available_spare;"%";"";"measurement"),
      emit("sensor";"nvme_available_spare_threshold";"NVMe available spare threshold";$x.available_spare_threshold;"%";"";"measurement"),
      emit("sensor";"nvme_percentage_used";"NVMe percentage used";$x.percentage_used;"%";"";"measurement"),
      emit("sensor";"nvme_data_read_tb";"NVMe data read";(if $x.data_units_read == null then null else ($x.data_units_read * 512000 / 1000000000000) end);"TB";"data_size";"total_increasing"),
      emit("sensor";"nvme_data_written_tb";"NVMe data written";(if $x.data_units_written == null then null else ($x.data_units_written * 512000 / 1000000000000) end);"TB";"data_size";"total_increasing"),
      emit("sensor";"nvme_unsafe_shutdowns";"NVMe unsafe shutdowns";$x.unsafe_shutdowns;"";"";"total_increasing"),
      emit("sensor";"nvme_media_errors";"NVMe media errors";$x.media_errors;"";"";"total_increasing"),
      emit("sensor";"nvme_error_log_entries";"NVMe error log entries";$x.num_err_log_entries;"";"";"total_increasing") end),
    emit("sensor";"ata_error_log_count";"ATA SMART error log count";.ata_smart_error_log.summary.count;"";"";"total_increasing"),
    emit("binary_sensor";"ata_self_test_failed";"ATA self-test failed";(if .ata_smart_data.self_test.status.passed == true then 0 elif .ata_smart_data.self_test.status.passed == false then 1 else null end);"";"problem";""),
    (attr(5)|emit("sensor";"ata_reallocated_sector_count";"ATA reallocated sector count";.raw.value;"";"";"measurement")),
    (attr(10)|emit("sensor";"ata_spin_retry_count";"ATA spin retry count";.raw.value;"";"";"measurement")),
    (attr(187)|emit("sensor";"ata_reported_uncorrect";"ATA reported uncorrectable";.raw.value;"";"";"measurement")),
    (attr(188)|emit("sensor";"ata_command_timeout";"ATA command timeout";.raw.value;"";"";"measurement")),
    (attr(192)|emit("sensor";"ata_power_off_retract_count";"ATA power-off retract count";.raw.value;"";"";"measurement")),
    (attr(193)|emit("sensor";"ata_load_cycle_count";"ATA load cycle count";.raw.value;"";"";"measurement")),
    (attr(197)|emit("sensor";"ata_current_pending_sector";"ATA current pending sector";.raw.value;"";"";"measurement")),
    (attr(198)|emit("sensor";"ata_offline_uncorrectable";"ATA offline uncorrectable";.raw.value;"";"";"measurement")),
    (attr(199)|emit("sensor";"ata_udma_crc_error_count";"ATA UDMA CRC error count";.raw.value;"";"";"measurement")),
    (attr(241)|emit("sensor";"ata_total_written_tb";"ATA total written";(.raw.value*$lbs/1000000000000);"TB";"data_size";"total_increasing")),
    (attr(242)|emit("sensor";"ata_total_read_tb";"ATA total read";(.raw.value*$lbs/1000000000000);"TB";"data_size";"total_increasing"))
  ' "$tmp" | while IFS=$'\t' read -r component key name value unit dev_class state_class; do
    emit "$disk_key" "$avail" "$dev_id" "$dev_name" "$model" "$vendor" "$firmware" "$component" "$key" "$name" "$value" "$unit" "$dev_class" "$state_class"
  done

  rm -f "$tmp"
  [[ "$smart_exit" -eq 0 ]] || echo "WARN: smartctl exit status for ${dev}: ${smart_exit}" >&2
done
