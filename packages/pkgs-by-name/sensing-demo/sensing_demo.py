#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

"""Publish synthetic, typed observations without exposing raw camera data."""

from __future__ import annotations

import argparse
import json
import logging
import os
import signal
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import urlsplit


OBSERVATION_SCHEMA = "ghaf.sensing.observation.v1"
HEALTH_SCHEMA = "ghaf.sensing.health.v1"
SOURCE_ID = "synthetic-camera-0"


def utc_now() -> str:
    """Return an ISO 8601 timestamp with an explicit UTC designator."""
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def synthetic_observation(
    sequence: int, captured_at: str | None = None
) -> dict[str, Any]:
    """Create one deterministic detection from an emulated camera capture."""
    x = round(((sequence * 7) % 80) / 100, 2)
    y = round(((sequence * 3) % 60) / 100, 2)
    return {
        "schema_version": OBSERVATION_SCHEMA,
        "source": {"id": SOURCE_ID, "mode": "synthetic"},
        "sequence": sequence,
        "captured_at": captured_at or utc_now(),
        "observations": [
            {
                "type": "object_detection",
                "class_id": "demo-target",
                "confidence": 0.95,
                "bounding_box": {
                    "x": x,
                    "y": y,
                    "width": 0.2,
                    "height": 0.2,
                },
            }
        ],
        "raw_sensor_data_exported": False,
    }


@dataclass(frozen=True)
class Snapshot:
    observation: dict[str, Any] | None
    age_seconds: float | None


class ObservationState:
    """Thread-safe storage for the latest derived observation."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._observation: dict[str, Any] | None = None
        self._updated_at: float | None = None

    def publish(self, observation: dict[str, Any]) -> None:
        with self._lock:
            self._observation = observation
            self._updated_at = time.monotonic()

    def snapshot(self) -> Snapshot:
        with self._lock:
            age = (
                None
                if self._updated_at is None
                else time.monotonic() - self._updated_at
            )
            return Snapshot(self._observation, age)


class SyntheticCamera(threading.Thread):
    """Emulate capture and trusted processing inside the sensing boundary."""

    def __init__(self, state: ObservationState, frames_per_second: int) -> None:
        super().__init__(name="synthetic-camera", daemon=True)
        self._state = state
        self._interval = 1 / frames_per_second
        self._stopped = threading.Event()

    def stop(self) -> None:
        self._stopped.set()

    def run(self) -> None:
        sequence = 0
        while not self._stopped.is_set():
            self._state.publish(synthetic_observation(sequence))
            sequence += 1
            self._stopped.wait(self._interval)


def health_document(
    snapshot: Snapshot,
    stale_after_seconds: int,
    accelerator_device: str,
) -> tuple[dict[str, Any], bool]:
    source_ready = (
        snapshot.age_seconds is not None and snapshot.age_seconds <= stale_after_seconds
    )
    accelerator_available = os.path.exists(accelerator_device)
    if not source_ready:
        status = "unhealthy"
    elif accelerator_available:
        status = "ready"
    else:
        status = "degraded"

    return (
        {
            "schema_version": HEALTH_SCHEMA,
            "status": status,
            "source": {
                "id": SOURCE_ID,
                "mode": "synthetic",
                "status": "ready" if source_ready else "unavailable",
                "observation_age_seconds": (
                    None
                    if snapshot.age_seconds is None
                    else round(snapshot.age_seconds, 3)
                ),
            },
            "accelerator": {
                "device": accelerator_device,
                "status": "available" if accelerator_available else "unavailable",
            },
            "raw_sensor_data_exported": False,
        },
        source_ready,
    )


def handler_factory(
    state: ObservationState,
    stale_after_seconds: int,
    accelerator_device: str,
) -> type[BaseHTTPRequestHandler]:
    class SensingHandler(BaseHTTPRequestHandler):
        server_version = "ghaf-sensing-demo/0.1"

        def send_json(self, status: HTTPStatus, document: dict[str, Any]) -> None:
            payload = json.dumps(
                document, separators=(",", ":"), sort_keys=True
            ).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
            path = urlsplit(self.path).path
            snapshot = state.snapshot()

            if path == "/healthz":
                document, source_ready = health_document(
                    snapshot, stale_after_seconds, accelerator_device
                )
                status = (
                    HTTPStatus.OK if source_ready else HTTPStatus.SERVICE_UNAVAILABLE
                )
                self.send_json(status, document)
                return

            if path == "/v1/observations/latest":
                if snapshot.observation is None or snapshot.age_seconds is None:
                    self.send_json(
                        HTTPStatus.SERVICE_UNAVAILABLE,
                        {"error": "observation_unavailable"},
                    )
                    return
                if snapshot.age_seconds > stale_after_seconds:
                    self.send_json(
                        HTTPStatus.SERVICE_UNAVAILABLE,
                        {"error": "observation_stale"},
                    )
                    return
                self.send_json(HTTPStatus.OK, snapshot.observation)
                return

            self.send_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})

        def log_message(self, message: str, *args: object) -> None:
            logging.info("%s - %s", self.address_string(), message % args)

    return SensingHandler


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--frames-per-second", type=int, default=2)
    parser.add_argument("--stale-after-seconds", type=int, default=5)
    parser.add_argument("--accelerator-device", default="/dev/nvgpu/igpu0")
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error("--port must be between 1 and 65535")
    if args.frames_per_second <= 0:
        parser.error("--frames-per-second must be positive")
    if args.stale_after_seconds <= 0:
        parser.error("--stale-after-seconds must be positive")
    return args


def main() -> None:
    args = parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    state = ObservationState()
    camera = SyntheticCamera(state, args.frames_per_second)
    server = ThreadingHTTPServer(
        (args.bind, args.port),
        handler_factory(state, args.stale_after_seconds, args.accelerator_device),
    )

    def stop_server(_signum: int, _frame: object) -> None:
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop_server)
    signal.signal(signal.SIGINT, stop_server)
    camera.start()
    logging.info("sensing demo listening on %s:%d", args.bind, args.port)
    try:
        server.serve_forever()
    finally:
        camera.stop()
        camera.join()
        server.server_close()


if __name__ == "__main__":
    main()
