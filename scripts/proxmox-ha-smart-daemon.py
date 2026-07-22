#!/usr/bin/env python3
"""Publish smartctl SMART/NVMe telemetry to Home Assistant via MQTT Discovery.

Long-running replacement for the old proxmox-ha-smart-mqtt.sh + systemd
timer. See proxmox-ha-hwmon-daemon.py for the rationale (single MQTT
connection + Last Will instead of one `mosquitto_pub` connection per metric).

This also fixes a bug in the old shell version: SMART metadata was
serialized with `jq @tsv` and parsed with `IFS=$'\\t' read`, but bash
treats tab as IFS-whitespace and squeezes consecutive tabs together, so
empty fields (e.g. an unset device_class) were silently dropped and later
fields shifted left - `state_class: measurement` ended up published as
`device_class: measurement` for several NVMe sensors. Here metrics are
built as plain Python tuples, so there is no delimiter to squeeze.

The metric set (48 keys) and every unique_id/state_topic are built to match
proxmox-ha-smart-mqtt.sh byte-for-byte as it was actually running in
production (verified against a live host via sha256 and a full key-set
diff), not the stale copy that had drifted in this repo before commit
"Sync proxmox-ha-smart-mqtt.sh with the version actually running on pve".
"""

from __future__ import annotations

import json
import logging
import os
import re
import signal
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))

from proxmox_ha_common import (  # noqa: E402
    ENV_FILE_DEFAULT,
    MqttPublisher,
    load_base_config,
    require_cmd,
    setup_logging,
    slugify,
)

log = logging.getLogger("proxmox-ha-smart")

STATE_EXPIRE_AFTER = 1800
ENTITY_CATEGORY = "diagnostic"

_SCAN_COMMENT = re.compile(r"\s*#.*$")

# (attribute id, key, name, unit, device_class, state_class)
ATA_ATTR_TABLE = [
    (5, "ata_reallocated_sector_count", "ATA reallocated sector count", "", "", "measurement"),
    (10, "ata_spin_retry_count", "ATA spin retry count", "", "", "measurement"),
    (183, "ata_runtime_bad_block", "ATA runtime bad block", "", "", "measurement"),
    (184, "ata_end_to_end_error", "ATA end-to-end error", "", "", "measurement"),
    (187, "ata_reported_uncorrect", "ATA reported uncorrectable", "", "", "measurement"),
    (188, "ata_command_timeout", "ATA command timeout", "", "", "measurement"),
    (191, "ata_g_sense_error_rate", "ATA G-sense error rate", "", "", "measurement"),
    (192, "ata_power_off_retract_count", "ATA power-off retract count", "", "", "measurement"),
    (193, "ata_load_cycle_count", "ATA load cycle count", "", "", "measurement"),
    (197, "ata_current_pending_sector", "ATA current pending sector", "", "", "measurement"),
    (198, "ata_offline_uncorrectable", "ATA offline uncorrectable", "", "", "measurement"),
    (199, "ata_udma_crc_error_count", "ATA UDMA CRC error count", "", "", "measurement"),
]
# (attribute id, key, name) for the raw LBA counters, as-is (cumulative, unitless)
ATA_LBA_ATTR_TABLE = [
    (241, "ata_total_lbas_written", "ATA total LBAs written"),
    (242, "ata_total_lbas_read", "ATA total LBAs read"),
]
# (attribute id, key, name) for the same two counters converted to TB (raw * logical_block_size)
ATA_TB_ATTR_TABLE = [
    (241, "ata_total_written_tb", "ATA total written"),
    (242, "ata_total_read_tb", "ATA total read"),
]


@dataclass
class Metric:
    component: str
    key: str
    name: str
    value: object
    unit: str = ""
    device_class: str = ""
    state_class: str = ""

    def is_present(self) -> bool:
        return self.value is not None


def find_ata_attr(table: list, attr_id: int) -> Optional[dict]:
    for entry in table or []:
        if entry.get("id") == attr_id:
            return entry
    return None


def build_metrics(smart_json: dict, smart_exit: int) -> list:
    metrics: list[Metric] = []

    def add(component, key, name, value, unit="", device_class="", state_class=""):
        if value is None:
            return
        metrics.append(Metric(component, key, name, value, unit, device_class, state_class))

    add(
        "sensor",
        "smartctl_exit_status",
        "smartctl exit status",
        (smart_json.get("smartctl") or {}).get("exit_status", smart_exit),
        state_class="measurement",
    )

    smart_passed = (smart_json.get("smart_status") or {}).get("passed")
    add(
        "binary_sensor",
        "smart_failed",
        "SMART failed",
        None if smart_passed is None else (0 if smart_passed else 1),
        device_class="problem",
    )

    add(
        "sensor",
        "temperature_current",
        "Temperature current",
        (smart_json.get("temperature") or {}).get("current"),
        unit="°C",
        device_class="temperature",
        state_class="measurement",
    )
    add(
        "sensor",
        "power_on_hours",
        "Power on hours",
        (smart_json.get("power_on_time") or {}).get("hours"),
        unit="h",
        device_class="duration",
        state_class="total_increasing",
    )
    add(
        "sensor",
        "power_cycle_count",
        "Power cycle count",
        smart_json.get("power_cycle_count"),
        state_class="total_increasing",
    )
    add(
        "sensor",
        "user_capacity_bytes",
        "User capacity",
        (smart_json.get("user_capacity") or {}).get("bytes"),
        unit="B",
        device_class="data_size",
        state_class="measurement",
    )

    nvme = smart_json.get("nvme_smart_health_information_log")
    if nvme is not None:
        add(
            "sensor",
            "nvme_critical_warning_raw",
            "NVMe critical warning raw",
            nvme.get("critical_warning"),
            state_class="measurement",
        )
        critical_warning = nvme.get("critical_warning")
        add(
            "binary_sensor",
            "nvme_critical_warning_problem",
            "NVMe critical warning",
            None if critical_warning is None else (0 if critical_warning == 0 else 1),
            device_class="problem",
        )
        add(
            "sensor",
            "nvme_temperature",
            "NVMe temperature",
            nvme.get("temperature"),
            unit="°C",
            device_class="temperature",
            state_class="measurement",
        )
        temp_sensors = nvme.get("temperature_sensors") or []
        for idx, ordinal in ((0, "1"), (1, "2")):
            if idx < len(temp_sensors):
                add(
                    "sensor",
                    f"nvme_temperature_sensor_{ordinal}",
                    f"NVMe temperature sensor {ordinal}",
                    temp_sensors[idx],
                    unit="°C",
                    device_class="temperature",
                    state_class="measurement",
                )
        add(
            "sensor",
            "nvme_available_spare",
            "NVMe available spare",
            nvme.get("available_spare"),
            unit="%",
            state_class="measurement",
        )
        add(
            "sensor",
            "nvme_available_spare_threshold",
            "NVMe available spare threshold",
            nvme.get("available_spare_threshold"),
            unit="%",
            state_class="measurement",
        )
        add(
            "sensor",
            "nvme_percentage_used",
            "NVMe percentage used",
            nvme.get("percentage_used"),
            unit="%",
            state_class="measurement",
        )
        data_units_read = nvme.get("data_units_read")
        add(
            "sensor",
            "nvme_data_units_read",
            "NVMe data units read",
            data_units_read,
            state_class="total_increasing",
        )
        data_units_written = nvme.get("data_units_written")
        add(
            "sensor",
            "nvme_data_units_written",
            "NVMe data units written",
            data_units_written,
            state_class="total_increasing",
        )
        add(
            "sensor",
            "nvme_data_read_tb",
            "NVMe data read",
            None if data_units_read is None else data_units_read * 512000 / 1_000_000_000_000,
            unit="TB",
            device_class="data_size",
            state_class="total_increasing",
        )
        add(
            "sensor",
            "nvme_data_written_tb",
            "NVMe data written",
            None
            if data_units_written is None
            else data_units_written * 512000 / 1_000_000_000_000,
            unit="TB",
            device_class="data_size",
            state_class="total_increasing",
        )
        add(
            "sensor",
            "nvme_host_reads",
            "NVMe host reads",
            nvme.get("host_reads"),
            state_class="total_increasing",
        )
        add(
            "sensor",
            "nvme_host_writes",
            "NVMe host writes",
            nvme.get("host_writes"),
            state_class="total_increasing",
        )
        add(
            "sensor",
            "nvme_controller_busy_time",
            "NVMe controller busy time",
            nvme.get("controller_busy_time"),
            unit="min",
            device_class="duration",
            state_class="total_increasing",
        )
        add(
            "sensor",
            "nvme_power_cycles",
            "NVMe power cycles",
            nvme.get("power_cycles"),
            state_class="total_increasing",
        )
        add(
            "sensor",
            "nvme_power_on_hours",
            "NVMe power on hours",
            nvme.get("power_on_hours"),
            unit="h",
            device_class="duration",
            state_class="total_increasing",
        )
        add(
            "sensor",
            "nvme_unsafe_shutdowns",
            "NVMe unsafe shutdowns",
            nvme.get("unsafe_shutdowns"),
            state_class="total_increasing",
        )
        add(
            "sensor",
            "nvme_media_errors",
            "NVMe media errors",
            nvme.get("media_errors"),
            state_class="total_increasing",
        )
        add(
            "sensor",
            "nvme_error_log_entries",
            "NVMe error log entries",
            nvme.get("num_err_log_entries"),
            state_class="total_increasing",
        )
        add(
            "sensor",
            "nvme_warning_temp_time",
            "NVMe warning temperature time",
            nvme.get("warning_temp_time"),
            unit="min",
            device_class="duration",
            state_class="total_increasing",
        )
        add(
            "sensor",
            "nvme_critical_comp_time",
            "NVMe critical composite temperature time",
            nvme.get("critical_comp_time"),
            unit="min",
            device_class="duration",
            state_class="total_increasing",
        )

    add(
        "sensor",
        "ata_error_log_count",
        "ATA SMART error log count",
        ((smart_json.get("ata_smart_error_log") or {}).get("summary") or {}).get("count"),
        state_class="total_increasing",
    )
    self_test = (smart_json.get("ata_smart_data") or {}).get("self_test") or {}
    self_test_passed = (self_test.get("status") or {}).get("passed")
    add(
        "binary_sensor",
        "ata_self_test_failed",
        "ATA self-test failed",
        None if self_test_passed is None else (0 if self_test_passed else 1),
        device_class="problem",
    )
    polling_minutes = self_test.get("polling_minutes") or {}
    add(
        "sensor",
        "ata_short_self_test_minutes",
        "ATA short self-test duration",
        polling_minutes.get("short"),
        unit="min",
        device_class="duration",
        state_class="measurement",
    )
    add(
        "sensor",
        "ata_extended_self_test_minutes",
        "ATA extended self-test duration",
        polling_minutes.get("extended"),
        unit="min",
        device_class="duration",
        state_class="measurement",
    )

    attr_table = (smart_json.get("ata_smart_attributes") or {}).get("table") or []
    for attr_id, key, name, unit, device_class, state_class in ATA_ATTR_TABLE:
        attr = find_ata_attr(attr_table, attr_id)
        raw_value = (attr or {}).get("raw", {}).get("value") if attr else None
        add("sensor", key, name, raw_value, unit=unit, device_class=device_class, state_class=state_class)

    for attr_id, key, name in ATA_LBA_ATTR_TABLE:
        attr = find_ata_attr(attr_table, attr_id)
        raw_value = (attr or {}).get("raw", {}).get("value") if attr else None
        add("sensor", key, name, raw_value, state_class="total_increasing")

    logical_block_size = smart_json.get("logical_block_size") or 512
    for attr_id, key, name in ATA_TB_ATTR_TABLE:
        attr = find_ata_attr(attr_table, attr_id)
        raw_value = (attr or {}).get("raw", {}).get("value") if attr else None
        value = None if raw_value is None else raw_value * logical_block_size / 1_000_000_000_000
        add(
            "sensor",
            key,
            name,
            value,
            unit="TB",
            device_class="data_size",
            state_class="total_increasing",
        )

    return metrics


def sensor_config_payload(name, unique_id, state_topic, availability_topic, device, unit, device_class, state_class):
    payload = {
        "name": name,
        "unique_id": unique_id,
        "object_id": unique_id,
        "state_topic": state_topic,
        "availability_topic": availability_topic,
        "payload_available": "online",
        "payload_not_available": "offline",
        "entity_category": ENTITY_CATEGORY,
        "expire_after": STATE_EXPIRE_AFTER,
        "device": device,
    }
    if unit:
        payload["unit_of_measurement"] = unit
    if device_class:
        payload["device_class"] = device_class
    if state_class:
        payload["state_class"] = state_class
    return payload


def binary_config_payload(name, unique_id, state_topic, availability_topic, device):
    return {
        "name": name,
        "unique_id": unique_id,
        "object_id": unique_id,
        "state_topic": state_topic,
        "availability_topic": availability_topic,
        "payload_available": "online",
        "payload_not_available": "offline",
        "payload_on": "1",
        "payload_off": "0",
        "device_class": "problem",
        "entity_category": ENTITY_CATEGORY,
        "expire_after": STATE_EXPIRE_AFTER,
        "device": device,
    }


def scan_disks() -> list[list[str]]:
    result = subprocess.run(
        ["smartctl", "--scan-open"], capture_output=True, text=True, check=False
    )
    disks = []
    for line in result.stdout.splitlines():
        cleaned = _SCAN_COMMENT.sub("", line).strip()
        if cleaned:
            disks.append(cleaned.split())
    return disks


def read_disk_smart(args: list[str]) -> tuple[Optional[dict], int]:
    result = subprocess.run(
        ["smartctl", "-a", "-j", *args], capture_output=True, text=True, check=False
    )
    try:
        return json.loads(result.stdout), result.returncode
    except json.JSONDecodeError:
        return None, result.returncode


def run_cycle(cfg, publisher: MqttPublisher, published_ids: set) -> None:
    disks = scan_disks()
    if not disks:
        log.error("smartctl --scan-open found no disks")
        return

    current_ids = set()
    for args in disks:
        dev = args[0]
        smart_json, smart_exit = read_disk_smart(args)
        if smart_json is None:
            log.warning("invalid JSON from smartctl for %s", dev)
            continue

        model = (
            smart_json.get("model_name")
            or smart_json.get("model_family")
            or (smart_json.get("device") or {}).get("model_name")
            or "Unknown disk"
        )
        serial = smart_json.get("serial_number") or (smart_json.get("device") or {}).get(
            "serial_number"
        )
        firmware = smart_json.get("firmware_version") or ""
        vendor = smart_json.get("vendor") or (smart_json.get("device") or {}).get(
            "protocol", "Disk"
        )
        protocol = (smart_json.get("device") or {}).get("protocol") or (
            smart_json.get("device") or {}
        ).get("type", "unknown")

        dev_base = os.path.basename(dev)
        if serial:
            disk_key = slugify(f"{cfg.node_name}_{serial}")
        else:
            disk_key = slugify(f"{cfg.node_name}_{dev_base}")

        dev_id = f"proxmox_{disk_key}_disk"
        dev_name = f"Proxmox {cfg.node_name} disk {model}"
        dev_name += f" {serial}" if serial else f" {dev_base}"

        log.info("Disk %s: %s %s protocol=%s", dev, model, serial or "", protocol)

        device = {
            "identifiers": [dev_id],
            "name": dev_name,
            "manufacturer": vendor,
            "model": model,
            "sw_version": firmware,
        }

        for metric in build_metrics(smart_json, smart_exit):
            key_slug = slugify(metric.key)
            unique_id = f"proxmox_{disk_key}_{key_slug}"
            state_topic = f"{cfg.smart_base_topic}/{disk_key}/{key_slug}/state"
            current_ids.add(unique_id)

            if metric.component == "binary_sensor":
                config_topic = f"{cfg.discovery_prefix}/binary_sensor/{unique_id}/config"
                payload = binary_config_payload(
                    metric.name, unique_id, state_topic, cfg.avail_topic, device
                )
            else:
                config_topic = f"{cfg.discovery_prefix}/sensor/{unique_id}/config"
                payload = sensor_config_payload(
                    metric.name,
                    unique_id,
                    state_topic,
                    cfg.avail_topic,
                    device,
                    metric.unit,
                    metric.device_class,
                    metric.state_class,
                )

            if unique_id not in published_ids:
                publisher.publish_retained(
                    config_topic, json.dumps(payload, separators=(",", ":"))
                )
            publisher.publish_retained(state_topic, str(metric.value))
            log.info("%s = %s", unique_id, metric.value)

        if smart_exit != 0:
            log.warning("smartctl exit status for %s: %s", dev, smart_exit)

    published_ids.clear()
    published_ids.update(current_ids)


class Config:
    def __init__(self, base, env: dict):
        self.node_name = base.node_name
        self.discovery_prefix = base.discovery_prefix
        self.smart_base_topic = (
            env.get("SMART_BASE_TOPIC", "").strip() or f"proxmox/{self.node_name}/smart"
        )
        # Single daemon-wide availability topic (bound to the MQTT Last Will), shared by
        # every disk's discovery config - unlike the old per-disk retained "online" topic,
        # this one is what the broker actually flips to `offline` on an unclean disconnect.
        self.avail_topic = f"{self.smart_base_topic}/availability"
        self.interval_seconds = int(env.get("SMART_INTERVAL_SECONDS", "300") or "300")


def main() -> None:
    setup_logging()
    require_cmd("smartctl")

    env_path = os.environ.get("PROXMOX_HA_ENV_FILE", ENV_FILE_DEFAULT)
    env, base = load_base_config(env_path)
    cfg = Config(base, env)

    stop_event = threading.Event()

    def handle_signal(signum, _frame):
        log.info("Received signal %s, shutting down", signum)
        stop_event.set()

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    publisher = MqttPublisher(
        host=base.mqtt_host,
        port=base.mqtt_port,
        username=base.mqtt_user,
        password=base.mqtt_pass,
        client_id=f"proxmox-ha-smart-{cfg.node_name}",
        availability_topic=cfg.avail_topic,
    )

    log.info(
        "Starting SMART exporter for node=%s interval=%ss", cfg.node_name, cfg.interval_seconds
    )
    if not publisher.connect_with_retry(stop_event):
        log.info("Stopped before connecting")
        return

    published_ids: set = set()
    while not stop_event.is_set():
        cycle_start = time.monotonic()
        try:
            run_cycle(cfg, publisher, published_ids)
        except Exception:
            log.exception("SMART cycle failed")
        elapsed = time.monotonic() - cycle_start
        stop_event.wait(max(cfg.interval_seconds - elapsed, 1))

    publisher.shutdown()
    log.info("Stopped")


if __name__ == "__main__":
    main()
