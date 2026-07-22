#!/usr/bin/env python3
"""Shared helpers for the proxmox-ha-mqtt exporter daemons."""

from __future__ import annotations

import logging
import re
import shutil
import subprocess
import sys
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

ENV_FILE_DEFAULT = "/etc/proxmox-ha-mqtt.env"

log = logging.getLogger("proxmox-ha-mqtt")

_SLUG_INVALID = re.compile(r"[^a-z0-9]+")


def setup_logging() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(levelname)s: %(message)s",
        stream=sys.stdout,
    )


def slugify(value: str) -> str:
    slug = _SLUG_INVALID.sub("_", value.lower())
    return slug.strip("_")


def load_env_file(path: str) -> dict:
    """Parse simple `KEY="value"` / `KEY=value` lines, ignoring comments and blanks.

    Not a full shell parser - matches the subset of syntax used in
    examples/proxmox-ha-mqtt.env.example (no interpolation, no export, no
    command substitution).
    """
    env: dict = {}
    with open(path, encoding="utf-8") as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            env[key] = value
    return env


def detect_node_name() -> str:
    try:
        result = subprocess.run(
            ["hostname", "-s"], capture_output=True, text=True, check=True
        )
        name = result.stdout.strip()
        if name:
            return name
    except (OSError, subprocess.CalledProcessError):
        pass
    import socket

    return socket.gethostname().split(".")[0]


def require_cmd(name: str) -> None:
    if shutil.which(name) is None:
        log.error("missing command: %s", name)
        sys.exit(1)


@dataclass
class BaseConfig:
    mqtt_host: str
    mqtt_port: int
    mqtt_user: Optional[str]
    mqtt_pass: Optional[str]
    node_name: str
    discovery_prefix: str


def load_base_config(env_path: str) -> tuple[dict, BaseConfig]:
    if not Path(env_path).is_file():
        log.error("Missing %s", env_path)
        sys.exit(1)

    env = load_env_file(env_path)

    mqtt_host = env.get("MQTT_HOST", "").strip()
    if not mqtt_host:
        log.error("Missing MQTT_HOST")
        sys.exit(1)

    mqtt_port = int(env.get("MQTT_PORT", "1883") or "1883")
    node_name = env.get("NODE_NAME", "").strip() or detect_node_name()
    discovery_prefix = env.get("DISCOVERY_PREFIX", "").strip() or "homeassistant"
    mqtt_user = env.get("MQTT_USER", "").strip() or None
    mqtt_pass = env.get("MQTT_PASS", "").strip() or None

    return env, BaseConfig(
        mqtt_host=mqtt_host,
        mqtt_port=mqtt_port,
        mqtt_user=mqtt_user,
        mqtt_pass=mqtt_pass,
        node_name=node_name,
        discovery_prefix=discovery_prefix,
    )


class MqttPublisher:
    """Single persistent MQTT connection for the lifetime of the daemon.

    Sets a Last Will on `availability_topic` so an unclean disconnect (crash,
    lost network, host power loss) is reported to Home Assistant as
    `offline` by the broker itself, instead of the availability topic
    staying retained `online` forever. A graceful shutdown publishes
    `offline` explicitly, since a clean MQTT disconnect never triggers the
    will.
    """

    def __init__(
        self,
        host: str,
        port: int,
        username: Optional[str],
        password: Optional[str],
        client_id: str,
        availability_topic: str,
    ) -> None:
        import paho.mqtt.client as mqtt

        self._mqtt = mqtt
        try:
            client = mqtt.Client(
                mqtt.CallbackAPIVersion.VERSION1, client_id=client_id, clean_session=True
            )
        except AttributeError:
            # paho-mqtt < 2.0 has no CallbackAPIVersion; old-style callbacks are the default.
            client = mqtt.Client(client_id=client_id, clean_session=True)

        if username:
            client.username_pw_set(username, password or None)

        client.will_set(availability_topic, payload="offline", qos=1, retain=True)
        client.on_connect = self._on_connect
        client.on_disconnect = self._on_disconnect
        client.reconnect_delay_set(min_delay=1, max_delay=60)

        self._client = client
        self._host = host
        self._port = port
        self._availability_topic = availability_topic
        self._connected = threading.Event()
        self._stopping = False

    def _on_connect(self, _client, _userdata, _flags, rc) -> None:
        if rc == 0:
            log.info("MQTT connected to %s:%s", self._host, self._port)
            self._connected.set()
            self.publish_retained(self._availability_topic, "online")
        else:
            log.error("MQTT connect failed, rc=%s", rc)

    def _on_disconnect(self, _client, _userdata, rc) -> None:
        self._connected.clear()
        if not self._stopping and rc != 0:
            log.warning("MQTT disconnected unexpectedly (rc=%s); auto-reconnect is enabled", rc)

    def connect_with_retry(self, stop_event: threading.Event, max_backoff: int = 60) -> bool:
        backoff = 1
        while not stop_event.is_set():
            try:
                self._client.connect(self._host, self._port, keepalive=60)
                self._client.loop_start()
                if self._connected.wait(timeout=10):
                    return True
                log.warning("MQTT connect did not confirm within timeout, retrying")
                self._client.loop_stop()
            except OSError as exc:
                log.error("MQTT connect error: %s (retry in %ss)", exc, backoff)
            if stop_event.wait(backoff):
                return False
            backoff = min(backoff * 2, max_backoff)
        return False

    def publish_retained(self, topic: str, payload: str, qos: int = 1, timeout: int = 10) -> None:
        info = self._client.publish(topic, payload, qos=qos, retain=True)
        info.wait_for_publish(timeout=timeout)

    def shutdown(self) -> None:
        self._stopping = True
        try:
            self.publish_retained(self._availability_topic, "offline")
        except Exception:
            log.exception("Failed to publish offline availability during shutdown")
        self._client.loop_stop()
        self._client.disconnect()
