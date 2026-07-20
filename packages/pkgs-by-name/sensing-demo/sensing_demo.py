#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

"""Produce synthetic RGB scenes and publish semantics derived from their pixels."""

from __future__ import annotations

import argparse
import hashlib
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
DEMO_SCHEMA = "ghaf.sensing.demo.v1"
SOURCE_ID = "synthetic-camera-0"
PROCESSOR_ID = "reference-color-segmentation"

FRAME_WIDTH = 160
FRAME_HEIGHT = 90
SKY = (126, 191, 255)
GROUND = (65, 68, 74)
SEMANTIC_COLORS: dict[str, tuple[int, int, int]] = {
    "person": (235, 64, 52),
    "vehicle": (45, 116, 218),
    "obstacle": (245, 183, 52),
}


def utc_now() -> str:
    """Return an ISO 8601 timestamp with an explicit UTC designator."""
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


@dataclass(frozen=True)
class BoundingBox:
    x: int
    y: int
    width: int
    height: int

    def as_pixels(self) -> dict[str, int]:
        return {
            "x": self.x,
            "y": self.y,
            "width": self.width,
            "height": self.height,
        }

    def normalized(self, frame_width: int, frame_height: int) -> dict[str, float]:
        return {
            "x": round(self.x / frame_width, 4),
            "y": round(self.y / frame_height, 4),
            "width": round(self.width / frame_width, 4),
            "height": round(self.height / frame_height, 4),
        }


@dataclass(frozen=True)
class SceneObject:
    semantic_label: str
    color: tuple[int, int, int]
    bounding_box: BoundingBox


@dataclass(frozen=True)
class RGBFrame:
    sequence: int
    captured_at: str
    width: int
    height: int
    pixels: bytes
    objects: tuple[SceneObject, ...]

    @property
    def sha256(self) -> str:
        return hashlib.sha256(self.pixels).hexdigest()


def fill_rectangle(
    pixels: bytearray,
    frame_width: int,
    bounding_box: BoundingBox,
    color: tuple[int, int, int],
) -> None:
    """Draw a solid RGB rectangle into a packed RGB byte buffer."""
    row = bytes(color) * bounding_box.width
    for y in range(bounding_box.y, bounding_box.y + bounding_box.height):
        start = (y * frame_width + bounding_box.x) * 3
        pixels[start : start + len(row)] = row


def produce_frame(sequence: int, captured_at: str | None = None) -> RGBFrame:
    """Render a deterministic traffic scene as an actual RGB pixel buffer."""
    pixels = bytearray(bytes(SKY) * FRAME_WIDTH * FRAME_HEIGHT)
    fill_rectangle(
        pixels,
        FRAME_WIDTH,
        BoundingBox(0, 50, FRAME_WIDTH, FRAME_HEIGHT - 50),
        GROUND,
    )

    objects = (
        SceneObject(
            "person",
            SEMANTIC_COLORS["person"],
            BoundingBox(8 + (sequence * 3) % 124, 24, 8, 24),
        ),
        SceneObject(
            "vehicle",
            SEMANTIC_COLORS["vehicle"],
            BoundingBox(112 - (sequence * 5) % 96, 58, 30, 14),
        ),
        SceneObject(
            "obstacle",
            SEMANTIC_COLORS["obstacle"],
            BoundingBox(74, 69, 12, 12),
        ),
    )
    for scene_object in objects:
        fill_rectangle(
            pixels,
            FRAME_WIDTH,
            scene_object.bounding_box,
            scene_object.color,
        )

    return RGBFrame(
        sequence=sequence,
        captured_at=captured_at or utc_now(),
        width=FRAME_WIDTH,
        height=FRAME_HEIGHT,
        pixels=bytes(pixels),
        objects=objects,
    )


def detect_semantics(frame: RGBFrame) -> list[dict[str, Any]]:
    """Derive semantic bounding boxes from pixels without producer metadata."""
    labels_by_color = {color: label for label, color in SEMANTIC_COLORS.items()}
    extents: dict[str, list[int]] = {}

    for pixel_index in range(frame.width * frame.height):
        offset = pixel_index * 3
        color = tuple(frame.pixels[offset : offset + 3])
        label = labels_by_color.get(color)
        if label is None:
            continue
        x = pixel_index % frame.width
        y = pixel_index // frame.width
        if label not in extents:
            extents[label] = [x, y, x, y, 1]
            continue
        extent = extents[label]
        extent[0] = min(extent[0], x)
        extent[1] = min(extent[1], y)
        extent[2] = max(extent[2], x)
        extent[3] = max(extent[3], y)
        extent[4] += 1

    detections = []
    for label in SEMANTIC_COLORS:
        extent = extents.get(label)
        if extent is None:
            continue
        bounding_box = BoundingBox(
            x=extent[0],
            y=extent[1],
            width=extent[2] - extent[0] + 1,
            height=extent[3] - extent[1] + 1,
        )
        detections.append(
            {
                "type": "object_detection",
                "class_id": label,
                "confidence": 1.0,
                "pixel_count": extent[4],
                "bounding_box": bounding_box.normalized(frame.width, frame.height),
                "bounding_box_pixels": bounding_box.as_pixels(),
            }
        )
    return detections


def scene_description(frame: RGBFrame) -> dict[str, Any]:
    """Describe producer intent without exporting the raw RGB frame."""
    return {
        "id": SOURCE_ID,
        "mode": "synthetic-rgb",
        "frame": {
            "format": "RGB8",
            "width": frame.width,
            "height": frame.height,
            "byte_length": len(frame.pixels),
            "sha256": frame.sha256,
        },
        "background": {
            "sky_rgb": list(SKY),
            "ground_rgb": list(GROUND),
        },
        "objects": [
            {
                "semantic_label": scene_object.semantic_label,
                "color_rgb": list(scene_object.color),
                "bounding_box_pixels": scene_object.bounding_box.as_pixels(),
            }
            for scene_object in frame.objects
        ],
    }


def process_frame(frame: RGBFrame) -> dict[str, Any]:
    """Process one frame and return producer, receiver, and observation views."""
    detections = detect_semantics(frame)
    produced_labels = [scene_object.semantic_label for scene_object in frame.objects]
    detected_labels = [detection["class_id"] for detection in detections]
    produced_boxes = [
        scene_object.bounding_box.as_pixels() for scene_object in frame.objects
    ]
    detected_boxes = [detection["bounding_box_pixels"] for detection in detections]
    labels_match = produced_labels == detected_labels
    boxes_match = produced_boxes == detected_boxes
    observation = {
        "schema_version": OBSERVATION_SCHEMA,
        "source": {
            "id": SOURCE_ID,
            "mode": "synthetic-rgb",
            "frame_sha256": frame.sha256,
        },
        "sequence": frame.sequence,
        "captured_at": frame.captured_at,
        "observations": detections,
        "raw_sensor_data_exported": False,
    }
    return {
        "schema_version": DEMO_SCHEMA,
        "sequence": frame.sequence,
        "captured_at": frame.captured_at,
        "producer": scene_description(frame),
        "receiver": {
            "processor": PROCESSOR_ID,
            "uses_accelerator": False,
            "detected_semantics": detections,
        },
        "comparison": {
            "produced_labels": produced_labels,
            "detected_labels": detected_labels,
            "semantic_labels_match": labels_match,
            "bounding_boxes_match": boxes_match,
            "all_detections_match_ground_truth": labels_match and boxes_match,
        },
        "observation": observation,
        "raw_sensor_data_exported": False,
    }


def synthetic_observation(
    sequence: int, captured_at: str | None = None
) -> dict[str, Any]:
    """Return the observation view for compatibility with existing consumers."""
    return process_frame(produce_frame(sequence, captured_at))["observation"]


@dataclass(frozen=True)
class Snapshot:
    capture: dict[str, Any] | None
    age_seconds: float | None


class ObservationState:
    """Thread-safe storage for the latest processed capture."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._capture: dict[str, Any] | None = None
        self._updated_at: float | None = None

    def publish(self, capture: dict[str, Any]) -> None:
        with self._lock:
            self._capture = capture
            self._updated_at = time.monotonic()

    def snapshot(self) -> Snapshot:
        with self._lock:
            age = (
                None
                if self._updated_at is None
                else time.monotonic() - self._updated_at
            )
            return Snapshot(self._capture, age)


class SyntheticCamera(threading.Thread):
    """Produce RGB frames and process their pixels inside the sensing boundary."""

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
            frame = produce_frame(sequence)
            self._state.publish(process_frame(frame))
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
                "mode": "synthetic-rgb",
                "status": "ready" if source_ready else "unavailable",
                "observation_age_seconds": (
                    None
                    if snapshot.age_seconds is None
                    else round(snapshot.age_seconds, 3)
                ),
            },
            "processor": {
                "id": PROCESSOR_ID,
                "status": "ready" if source_ready else "unavailable",
                "uses_accelerator": False,
            },
            "accelerator": {
                "device": accelerator_device,
                "status": "available" if accelerator_available else "unavailable",
            },
            "raw_sensor_data_exported": False,
        },
        source_ready,
    )


DEMO_HTML = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Ghaf sensing boundary demo</title>
  <style>
    :root { color-scheme: dark; font-family: system-ui, sans-serif; }
    body { max-width: 1100px; margin: 0 auto; padding: 2rem; background: #101418; }
    header, .card { background: #192127; border: 1px solid #33434e; border-radius: 12px; }
    header { padding: 1.2rem 1.5rem; margin-bottom: 1rem; }
    h1, h2, p { margin: .25rem 0 .7rem; }
    .grid { display: grid; grid-template-columns: repeat(auto-fit,minmax(320px,1fr)); gap: 1rem; }
    .card { padding: 1rem; }
    svg { width: 100%; background: #20282e; border-radius: 8px; }
    .label { fill: white; font: 7px monospace; }
    code { color: #8ed3ff; }
    .ok { color: #77dd99; }
  </style>
</head>
<body>
  <header>
    <h1>Ghaf sensing boundary</h1>
    <p>Actual RGB pixels are generated and processed inside <code>sensing-vm</code>.
       This page reconstructs producer intent and receiver semantics from metadata;
       it never receives the raw frame.</p>
    <p id="status">Waiting for observations…</p>
  </header>
  <main class="grid">
    <section class="card"><h2>Producer: synthetic RGB scene</h2><svg id="producer" viewBox="0 0 160 90"></svg></section>
    <section class="card"><h2>Receiver: detected semantics</h2><svg id="receiver" viewBox="0 0 160 90"></svg></section>
  </main>
  <script>
    const ns = "http://www.w3.org/2000/svg";
    function rect(svg, box, color, label) {
      const node = document.createElementNS(ns, "rect");
      Object.entries({x:box.x,y:box.y,width:box.width,height:box.height,fill:color,stroke:"white","stroke-width":1}).forEach(([k,v]) => node.setAttribute(k,v));
      svg.appendChild(node);
      const text = document.createElementNS(ns, "text");
      text.setAttribute("x", box.x); text.setAttribute("y", Math.max(7, box.y - 2));
      text.setAttribute("class", "label"); text.textContent = label; svg.appendChild(text);
    }
    function draw(data) {
      const producer = document.querySelector("#producer"); producer.replaceChildren();
      const sky = document.createElementNS(ns, "rect");
      sky.setAttribute("width",160); sky.setAttribute("height",90); sky.setAttribute("fill","rgb(126,191,255)"); producer.appendChild(sky);
      rect(producer,{x:0,y:50,width:160,height:40},"rgb(65,68,74)","");
      data.producer.objects.forEach(o => rect(producer,o.bounding_box_pixels,`rgb(${o.color_rgb.join(",")})`,o.semantic_label));
      const receiver = document.querySelector("#receiver"); receiver.replaceChildren();
      data.receiver.detected_semantics.forEach(o => rect(receiver,o.bounding_box_pixels,"transparent",`${o.class_id} (${o.pixel_count}px)`));
      const matched = data.comparison.all_detections_match_ground_truth;
      document.querySelector("#status").innerHTML = `Frame <code>${data.sequence}</code> · <code>${data.producer.frame.width}×${data.producer.frame.height} RGB8</code> · processor <code>${data.receiver.processor}</code> · <span class="${matched ? "ok" : ""}">${matched ? "all semantics matched" : "mismatch"}</span>`;
    }
    async function update() {
      try { const response = await fetch("/v1/demo/latest", {cache:"no-store"}); draw(await response.json()); }
      catch (error) { document.querySelector("#status").textContent = `Unavailable: ${error}`; }
    }
    update(); setInterval(update, 500);
  </script>
</body>
</html>
"""


def handler_factory(
    state: ObservationState,
    stale_after_seconds: int,
    accelerator_device: str,
) -> type[BaseHTTPRequestHandler]:
    class SensingHandler(BaseHTTPRequestHandler):
        server_version = "ghaf-sensing-demo/0.2"

        def send_payload(
            self, status: HTTPStatus, content_type: str, payload: bytes
        ) -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Referrer-Policy", "no-referrer")
            if content_type.startswith("text/html"):
                self.send_header(
                    "Content-Security-Policy",
                    "default-src 'none'; connect-src 'self'; "
                    "script-src 'unsafe-inline'; style-src 'unsafe-inline'",
                )
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def send_json(self, status: HTTPStatus, document: dict[str, Any]) -> None:
            payload = json.dumps(
                document, separators=(",", ":"), sort_keys=True
            ).encode()
            self.send_payload(status, "application/json", payload)

        def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
            path = urlsplit(self.path).path
            snapshot = state.snapshot()

            if path in ("/", "/demo"):
                self.send_payload(
                    HTTPStatus.OK,
                    "text/html; charset=utf-8",
                    DEMO_HTML.encode(),
                )
                return

            if path == "/healthz":
                document, source_ready = health_document(
                    snapshot, stale_after_seconds, accelerator_device
                )
                status = (
                    HTTPStatus.OK if source_ready else HTTPStatus.SERVICE_UNAVAILABLE
                )
                self.send_json(status, document)
                return

            if path in ("/v1/demo/latest", "/v1/observations/latest"):
                if snapshot.capture is None or snapshot.age_seconds is None:
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
                document = (
                    snapshot.capture
                    if path == "/v1/demo/latest"
                    else snapshot.capture["observation"]
                )
                self.send_json(HTTPStatus.OK, document)
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
