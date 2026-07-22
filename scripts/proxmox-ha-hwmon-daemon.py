#!/usr/bin/env python3
"""Publish lm-sensors (hwmon) telemetry to Home Assistant via MQTT Discovery.

Long-running replacement for the old proxmox-ha-hwmon-mqtt.sh + systemd
timer: holds a single MQTT connection open for the life of the process
(instead of one `mosquitto_pub` connection per metric per run) and uses a
Last Will so Home Assistant sees `offline` when this process disconnects
uncleanly, not just when a human remembers to publish it.
"""

from __future__ import annotations

import fnmatch
import json
import logging
import os
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from proxmox_ha_common import (  # noqa: E402
    ENV_FILE_DEFAULT,
    MqttPublisher,
    load_base_config,
    require_cmd,
    setup_logging,
    slugify,
)

log = logging.getLogger("proxmox-ha-hwmon")

STATE_EXPIRE_AFTER = 300

# (glob patterns on the sensors -j field name) -> (component, unit, device_class, state_class, entity_category)
CLASSIFY_RULES: list[tuple[tuple[str, ...], tuple[str, str, str, str, str]]] = [
    (
        ("temp*_input", "temp*_max", "temp*_min", "temp*_crit"),
        ("sensor", "°C", "temperature", "measurement", "diagnostic"),
    ),
    (("in*_input",), ("sensor", "V", "voltage", "measurement", "diagnostic")),
    (("power*_input",), ("sensor", "W", "power", "measurement", "diagnostic")),
    (
        ("current*_input", "curr*_input"),
        ("sensor", "A", "current", "measurement", "diagnostic"),
    ),
    (("fan*_input",), ("sensor", "RPM", "", "measurement", "diagnostic")),
    (("*_alarm",), ("binary_sensor", "", "", "", "diagnostic")),
]
DEFAULT_CLASS = ("sensor", "", "", "measurement", "diagnostic")

FRIENDLY_SUFFIX_RULES: list[tuple[str, str]] = [
    ("temp*_input", "temperature"),
    ("temp*_max", "temperature max"),
    ("temp*_min", "temperature min"),
    ("temp*_crit", "temperature critical"),
    ("*_alarm", "alarm"),
    ("in*_input", "voltage"),
    ("power*_input", "power"),
    ("current*_input", "current"),
    ("curr*_input", "current"),
    ("fan*_input", "fan speed"),
]


def classify_sensor(field: str) -> tuple[str, str, str, str, str]:
    for patterns, classification in CLASSIFY_RULES:
        if any(fnmatch.fnmatch(field, pattern) for pattern in patterns):
            return classification
    return DEFAULT_CLASS


def friendly_suffix(field: str) -> str:
    for pattern, suffix in FRIENDLY_SUFFIX_RULES:
        if fnmatch.fnmatch(field, pattern):
            return suffix
    return field


def iter_metrics(sensors_json: dict):
    for chip, chip_value in sensors_json.items():
        if not isinstance(chip_value, dict):
            continue
        for feature, feature_value in chip_value.items():
            if not isinstance(feature_value, dict):
                continue
            for field, value in feature_value.items():
                if isinstance(value, bool):
                    continue
                if isinstance(value, (int, float)):
                    yield chip, feature, field, value


def build_entity(cfg, chip: str, feature: str, field: str, value):
    raw_id = f"{cfg.node_name}_{chip}_{feature}_{field}"
    sensor_id = slugify(raw_id)
    component, unit, device_class, state_class, entity_category = classify_sensor(field)
    suffix = friendly_suffix(field)

    display_name = f"Proxmox {cfg.node_name} {chip} {feature} {suffix}"
    unique_id = f"proxmox_{sensor_id}"
    state_topic = f"{cfg.base_topic}/{sensor_id}/state"
    config_topic = f"{cfg.discovery_prefix}/{component}/{unique_id}/config"

    device = {
        "identifiers": [cfg.device_id],
        "name": cfg.device_name,
        "manufacturer": "Proxmox VE",
        "model": "Host hardware sensors",
    }

    if component == "binary_sensor":
        payload = {
            "name": display_name,
            "unique_id": unique_id,
            "object_id": unique_id,
            "state_topic": state_topic,
            "availability_topic": cfg.avail_topic,
            "payload_available": "online",
            "payload_not_available": "offline",
            "payload_on": "1",
            "payload_off": "0",
            "device_class": "problem",
            "entity_category": entity_category,
            "device": device,
        }
    else:
        payload = {
            "name": display_name,
            "unique_id": unique_id,
            "object_id": unique_id,
            "state_topic": state_topic,
            "availability_topic": cfg.avail_topic,
            "payload_available": "online",
            "payload_not_available": "offline",
            "entity_category": entity_category,
            "expire_after": STATE_EXPIRE_AFTER,
            "device": device,
        }
        if unit:
            payload["unit_of_measurement"] = unit
        if device_class:
            payload["device_class"] = device_class
        if state_class:
            payload["state_class"] = state_class

    return component, unique_id, config_topic, payload, state_topic, str(value)


def run_cycle(cfg, publisher: MqttPublisher, published_ids: set) -> None:
    result = subprocess.run(
        ["sensors", "-j"], capture_output=True, text=True, check=True
    )
    sensors_json = json.loads(result.stdout)

    current_ids = set()
    for chip, feature, field, value in iter_metrics(sensors_json):
        component, unique_id, config_topic, payload, state_topic, state_value = build_entity(
            cfg, chip, feature, field, value
        )
        current_ids.add(unique_id)
        if unique_id not in published_ids:
            publisher.publish_retained(
                config_topic, json.dumps(payload, separators=(",", ":"))
            )
        publisher.publish_retained(state_topic, state_value)
        log.info("%s %s = %s", component, unique_id, state_value)

    published_ids.clear()
    published_ids.update(current_ids)


class Config:
    def __init__(self, base, env: dict):
        self.node_name = base.node_name
        self.discovery_prefix = base.discovery_prefix
        self.base_topic = env.get("BASE_TOPIC", "").strip() or f"proxmox/{self.node_name}/hwmon"
        self.avail_topic = f"{self.base_topic}/availability"
        self.device_id = f"proxmox_{self.node_name}_hardware"
        self.device_name = f"Proxmox {self.node_name} hardware"
        self.interval_seconds = int(env.get("HWMON_INTERVAL_SECONDS", "60") or "60")


def main() -> None:
    setup_logging()
    require_cmd("sensors")

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
        client_id=f"proxmox-ha-hwmon-{cfg.node_name}",
        availability_topic=cfg.avail_topic,
    )

    log.info(
        "Starting hwmon exporter for node=%s interval=%ss", cfg.node_name, cfg.interval_seconds
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
            log.exception("hwmon cycle failed")
        elapsed = time.monotonic() - cycle_start
        stop_event.wait(max(cfg.interval_seconds - elapsed, 1))

    publisher.shutdown()
    log.info("Stopped")


if __name__ == "__main__":
    main()
