#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

"""Generate animated RGB scenes and publish semantics derived from their pixels."""

from __future__ import annotations

import argparse
import binascii
import hashlib
import json
import logging
import os
import signal
import struct
import threading
import time
import zlib
from collections import OrderedDict
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
GENERATOR_ID = "procedural-scene-engine"
PROCESSOR_ID = "reference-color-segmentation"

FRAME_WIDTH = 320
FRAME_HEIGHT = 180
SKY = (112, 183, 235)
GROUND = (55, 70, 62)
SEMANTIC_COLORS: dict[str, tuple[int, int, int]] = {
    "person": (239, 71, 67),
    "vehicle": (58, 127, 231),
    "obstacle": (250, 188, 58),
    "deer": (161, 98, 54),
    "fox": (238, 111, 45),
    "bird": (155, 103, 211),
    "cow": (232, 224, 207),
    "sheep": (190, 205, 214),
    "dog": (133, 91, 63),
    "cat": (91, 166, 129),
    "forklift": (241, 154, 42),
    "parcel": (177, 126, 76),
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
class Scene:
    id: str
    title: str
    prompt: str
    objects: tuple[SceneObject, ...]


@dataclass(frozen=True)
class RGBFrame:
    sequence: int
    captured_at: str
    width: int
    height: int
    pixels: bytes
    scene: Scene

    @property
    def objects(self) -> tuple[SceneObject, ...]:
        return self.scene.objects

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


def fill_ellipse(
    pixels: bytearray,
    frame_width: int,
    bounding_box: BoundingBox,
    color: tuple[int, int, int],
) -> None:
    """Draw a filled ellipse that touches every side of its bounding box."""
    center_x = bounding_box.x + (bounding_box.width - 1) / 2
    center_y = bounding_box.y + (bounding_box.height - 1) / 2
    radius_x = max(0.5, (bounding_box.width - 1) / 2)
    radius_y = max(0.5, (bounding_box.height - 1) / 2)
    for y in range(bounding_box.y, bounding_box.y + bounding_box.height):
        for x in range(bounding_box.x, bounding_box.x + bounding_box.width):
            dx = (x - center_x) / radius_x
            dy = (y - center_y) / radius_y
            if dx * dx + dy * dy <= 1.0:
                offset = (y * frame_width + x) * 3
                pixels[offset : offset + 3] = bytes(color)
    # Preserve exact, deterministic extents for the reference receiver.
    for x, y in (
        (bounding_box.x, round(center_y)),
        (bounding_box.x + bounding_box.width - 1, round(center_y)),
        (round(center_x), bounding_box.y),
        (round(center_x), bounding_box.y + bounding_box.height - 1),
    ):
        offset = (y * frame_width + x) * 3
        pixels[offset : offset + 3] = bytes(color)


def fill_triangle(
    pixels: bytearray,
    frame_width: int,
    bounding_box: BoundingBox,
    color: tuple[int, int, int],
) -> None:
    """Draw an upright filled triangle."""
    center_x = bounding_box.x + bounding_box.width // 2
    for row in range(bounding_box.height):
        half_width = max(
            0,
            round(
                row * (bounding_box.width - 1) / (2 * max(1, bounding_box.height - 1))
            ),
        )
        left = max(bounding_box.x, center_x - half_width)
        right = min(bounding_box.x + bounding_box.width - 1, center_x + half_width)
        fill_rectangle(
            pixels,
            frame_width,
            BoundingBox(left, bounding_box.y + row, right - left + 1, 1),
            color,
        )


def preserve_extents(
    pixels: bytearray,
    frame_width: int,
    bounding_box: BoundingBox,
    color: tuple[int, int, int],
) -> None:
    """Keep detector extents aligned with the declared object box."""
    center_x = bounding_box.x + bounding_box.width // 2
    center_y = bounding_box.y + bounding_box.height // 2
    for x, y in (
        (bounding_box.x, center_y),
        (bounding_box.x + bounding_box.width - 1, center_y),
        (center_x, bounding_box.y),
        (center_x, bounding_box.y + bounding_box.height - 1),
    ):
        offset = (y * frame_width + x) * 3
        pixels[offset : offset + 3] = bytes(color)


def draw_background(pixels: bytearray, scene_id: str) -> None:
    """Render a scene-specific landscape without semantic marker colors."""
    for y in range(FRAME_HEIGHT):
        if y < 105:
            shade = (
                min(255, SKY[0] + y // 12),
                min(255, SKY[1] + y // 18),
                SKY[2],
            )
        else:
            shade = GROUND
        fill_rectangle(pixels, FRAME_WIDTH, BoundingBox(0, y, FRAME_WIDTH, 1), shade)

    if scene_id == "wildlife":
        fill_rectangle(pixels, FRAME_WIDTH, BoundingBox(0, 120, 320, 60), (45, 92, 57))
        for x in (18, 72, 250, 292):
            fill_rectangle(pixels, FRAME_WIDTH, BoundingBox(x, 62, 7, 72), (74, 61, 46))
            fill_ellipse(
                pixels, FRAME_WIDTH, BoundingBox(x - 18, 42, 43, 42), (38, 105, 60)
            )
    elif scene_id == "farm":
        fill_rectangle(pixels, FRAME_WIDTH, BoundingBox(0, 112, 320, 68), (92, 132, 70))
        fill_rectangle(pixels, FRAME_WIDTH, BoundingBox(224, 64, 72, 52), (139, 57, 52))
        fill_rectangle(pixels, FRAME_WIDTH, BoundingBox(218, 61, 84, 8), (92, 46, 43))
        for y in (135, 158):
            fill_rectangle(
                pixels, FRAME_WIDTH, BoundingBox(0, y, 320, 3), (176, 151, 106)
            )
    elif scene_id == "road":
        fill_rectangle(pixels, FRAME_WIDTH, BoundingBox(0, 116, 320, 64), (55, 58, 64))
        for x in range(0, FRAME_WIDTH, 48):
            fill_rectangle(
                pixels, FRAME_WIDTH, BoundingBox(x, 147, 26, 3), (230, 225, 184)
            )
        fill_rectangle(pixels, FRAME_WIDTH, BoundingBox(18, 42, 72, 74), (78, 92, 105))
        fill_rectangle(pixels, FRAME_WIDTH, BoundingBox(235, 32, 62, 84), (83, 96, 108))
    else:
        fill_rectangle(pixels, FRAME_WIDTH, BoundingBox(0, 0, 320, 180), (48, 57, 65))
        fill_rectangle(pixels, FRAME_WIDTH, BoundingBox(0, 130, 320, 50), (64, 69, 74))
        for x in (20, 112, 232):
            fill_rectangle(
                pixels, FRAME_WIDTH, BoundingBox(x, 42, 68, 62), (92, 103, 111)
            )
            fill_rectangle(
                pixels, FRAME_WIDTH, BoundingBox(x + 5, 50, 58, 5), (132, 146, 153)
            )


def object_at(label: str, x: int, y: int, width: int, height: int) -> SceneObject:
    return SceneObject(label, SEMANTIC_COLORS[label], BoundingBox(x, y, width, height))


def scene_for_sequence(sequence: int) -> Scene:
    """Select and animate one of four deterministic generated scenes."""
    scene_index = (sequence // 40) % 4
    phase = sequence % 40
    if scene_index == 0:
        return Scene(
            "wildlife",
            "Forest wildlife",
            "A deer, fox and bird moving through a Nordic forest",
            (
                object_at("deer", 104 + phase, 104, 42, 31),
                object_at("fox", 242 - phase * 2, 132, 32, 20),
                object_at("bird", 142 + phase * 2, 52 + phase // 4, 18, 12),
            ),
        )
    if scene_index == 1:
        return Scene(
            "farm",
            "Smart farm",
            "Livestock and companion animals in a connected farmyard",
            (
                object_at("cow", 32 + phase, 110, 48, 32),
                object_at("sheep", 126 + phase // 2, 126, 36, 24),
                object_at("dog", 252 - phase, 139, 25, 18),
            ),
        )
    if scene_index == 2:
        return Scene(
            "road",
            "Urban mobility",
            "A person, vehicle and obstacle in a monitored city street",
            (
                object_at("person", 56 + phase * 2, 88, 14, 38),
                object_at("vehicle", 224 - phase * 3, 128, 58, 25),
                object_at("obstacle", 154, 144, 20, 22),
            ),
        )
    return Scene(
        "warehouse",
        "Autonomous warehouse",
        "A forklift, worker, parcel and cat sharing a warehouse aisle",
        (
            object_at("person", 166, 96, 14, 38),
            object_at("cat", 270 - phase, 148, 22, 15),
            object_at("forklift", 34 + phase * 2, 126, 50, 32),
            object_at("parcel", 204, 142, 24, 24),
        ),
    )


def draw_scene_object(pixels: bytearray, scene_object: SceneObject) -> None:
    """Render a recognizable semantic silhouette from simple pixel primitives."""
    box = scene_object.bounding_box
    color = scene_object.color
    label = scene_object.semantic_label
    x, y, width, height = box.x, box.y, box.width, box.height

    if label == "person":
        head = max(5, width // 2)
        fill_ellipse(
            pixels,
            FRAME_WIDTH,
            BoundingBox(x + (width - head) // 2, y, head, head),
            color,
        )
        fill_rectangle(
            pixels,
            FRAME_WIDTH,
            BoundingBox(x + width // 4, y + head - 1, max(3, width // 2), height // 2),
            color,
        )
        fill_rectangle(
            pixels,
            FRAME_WIDTH,
            BoundingBox(x, y + head + 3, width, max(2, height // 8)),
            color,
        )
        leg_y = y + head + height // 2 - 2
        fill_rectangle(
            pixels,
            FRAME_WIDTH,
            BoundingBox(x + width // 4, leg_y, 3, y + height - leg_y),
            color,
        )
        fill_rectangle(
            pixels,
            FRAME_WIDTH,
            BoundingBox(x + width - width // 4 - 3, leg_y, 3, y + height - leg_y),
            color,
        )
    elif label == "vehicle":
        fill_rectangle(
            pixels,
            FRAME_WIDTH,
            BoundingBox(x, y + height // 3, width, height * 2 // 3 - 3),
            color,
        )
        fill_rectangle(
            pixels,
            FRAME_WIDTH,
            BoundingBox(x + width // 4, y, width // 2, height // 2),
            color,
        )
        window = (166, 213, 231)
        fill_rectangle(
            pixels,
            FRAME_WIDTH,
            BoundingBox(x + width // 3, y + 3, max(3, width // 6), max(3, height // 4)),
            window,
        )
        fill_rectangle(
            pixels,
            FRAME_WIDTH,
            BoundingBox(
                x + width // 2 + 2, y + 3, max(3, width // 6), max(3, height // 4)
            ),
            window,
        )
        for wheel_x in (x + width // 5, x + width * 4 // 5 - 5):
            fill_ellipse(
                pixels,
                FRAME_WIDTH,
                BoundingBox(wheel_x, y + height - 9, 9, 9),
                (29, 34, 38),
            )
    elif label == "obstacle":
        fill_triangle(pixels, FRAME_WIDTH, BoundingBox(x, y, width, height - 3), color)
        fill_rectangle(
            pixels, FRAME_WIDTH, BoundingBox(x, y + height - 4, width, 4), color
        )
        fill_rectangle(
            pixels,
            FRAME_WIDTH,
            BoundingBox(x + width // 4, y + height // 2, width // 2, 3),
            (247, 243, 222),
        )
    elif label in {"deer", "fox", "cow", "dog", "cat"}:
        body_width = width * 3 // 4
        body_y = y + height // 3
        fill_ellipse(
            pixels,
            FRAME_WIDTH,
            BoundingBox(x, body_y, body_width, max(7, height // 2)),
            color,
        )
        head_width = max(7, width // 4)
        fill_ellipse(
            pixels,
            FRAME_WIDTH,
            BoundingBox(
                x + width - head_width, y + height // 4, head_width, max(7, height // 3)
            ),
            color,
        )
        leg_width = max(2, width // 12)
        for leg_x in (x + width // 6, x + width // 2):
            fill_rectangle(
                pixels,
                FRAME_WIDTH,
                BoundingBox(
                    leg_x,
                    y + height * 2 // 3,
                    leg_width,
                    y + height - (y + height * 2 // 3),
                ),
                color,
            )
        fill_triangle(
            pixels,
            FRAME_WIDTH,
            BoundingBox(
                x + width - head_width, y, max(5, head_width // 2), max(4, height // 4)
            ),
            color,
        )
        if label == "deer":
            fill_rectangle(
                pixels,
                FRAME_WIDTH,
                BoundingBox(x + width - 5, y, 2, height // 3),
                color,
            )
            fill_rectangle(
                pixels, FRAME_WIDTH, BoundingBox(x + width - 9, y + 2, 8, 2), color
            )
        elif label == "fox":
            fill_triangle(
                pixels,
                FRAME_WIDTH,
                BoundingBox(x, y + height // 3, width // 3, height // 2),
                color,
            )
        elif label == "cow":
            fill_ellipse(
                pixels,
                FRAME_WIDTH,
                BoundingBox(x + width // 4, body_y + 3, width // 5, height // 4),
                (73, 65, 58),
            )
        else:
            fill_triangle(
                pixels,
                FRAME_WIDTH,
                BoundingBox(x, y + height // 3, width // 4, height // 3),
                color,
            )
    elif label == "sheep":
        for offset_x, offset_y in ((0, 5), (7, 0), (15, 4), (23, 1)):
            fill_ellipse(
                pixels,
                FRAME_WIDTH,
                BoundingBox(
                    x + offset_x,
                    y + offset_y,
                    min(16, width - offset_x),
                    max(10, height * 2 // 3),
                ),
                color,
            )
        fill_ellipse(
            pixels,
            FRAME_WIDTH,
            BoundingBox(x + width - 10, y + height // 3, 10, 11),
            (66, 72, 75),
        )
        for leg_x in (x + 8, x + width - 12):
            fill_rectangle(
                pixels, FRAME_WIDTH, BoundingBox(leg_x, y + height - 7, 3, 7), color
            )
    elif label == "bird":
        fill_ellipse(
            pixels,
            FRAME_WIDTH,
            BoundingBox(
                x + width // 4, y + height // 3, width * 3 // 4, height * 2 // 3
            ),
            color,
        )
        fill_triangle(
            pixels,
            FRAME_WIDTH,
            BoundingBox(x, y, width * 2 // 3, height * 2 // 3),
            color,
        )
        fill_triangle(
            pixels,
            FRAME_WIDTH,
            BoundingBox(x + width - 8, y + height // 2, 8, 6),
            (235, 182, 56),
        )
    elif label == "forklift":
        fill_rectangle(
            pixels,
            FRAME_WIDTH,
            BoundingBox(x, y + height // 3, width * 2 // 3, height * 2 // 3 - 4),
            color,
        )
        fill_rectangle(
            pixels,
            FRAME_WIDTH,
            BoundingBox(x + width // 4, y, width // 3, height // 2),
            color,
        )
        fill_rectangle(
            pixels, FRAME_WIDTH, BoundingBox(x + width - 7, y, 4, height - 5), color
        )
        fill_rectangle(
            pixels, FRAME_WIDTH, BoundingBox(x + width - 7, y + height - 7, 7, 3), color
        )
        for wheel_x in (x + 5, x + width // 2):
            fill_ellipse(
                pixels,
                FRAME_WIDTH,
                BoundingBox(wheel_x, y + height - 9, 9, 9),
                (28, 33, 36),
            )
    elif label == "parcel":
        fill_rectangle(pixels, FRAME_WIDTH, box, color)
        fill_rectangle(
            pixels,
            FRAME_WIDTH,
            BoundingBox(x + width // 2 - 2, y, 4, height),
            (218, 181, 113),
        )
        fill_rectangle(
            pixels,
            FRAME_WIDTH,
            BoundingBox(x, y + height // 3, width, 2),
            (115, 80, 49),
        )
    else:
        fill_ellipse(pixels, FRAME_WIDTH, box, color)

    preserve_extents(pixels, FRAME_WIDTH, box, color)


def produce_frame(sequence: int, captured_at: str | None = None) -> RGBFrame:
    """Render a deterministic generated scene as an actual RGB pixel buffer."""
    scene = scene_for_sequence(sequence)
    pixels = bytearray(FRAME_WIDTH * FRAME_HEIGHT * 3)
    draw_background(pixels, scene.id)
    for scene_object in scene.objects:
        draw_scene_object(pixels, scene_object)
    return RGBFrame(
        sequence=sequence,
        captured_at=captured_at or utc_now(),
        width=FRAME_WIDTH,
        height=FRAME_HEIGHT,
        pixels=bytes(pixels),
        scene=scene,
    )


def detect_semantics(frame: RGBFrame) -> list[dict[str, Any]]:
    """Derive semantic bounding boxes from pixels without producer metadata."""
    labels_by_color = {color: label for label, color in SEMANTIC_COLORS.items()}
    extents: dict[str, list[int]] = {}
    for pixel_index in range(frame.width * frame.height):
        offset = pixel_index * 3
        label = labels_by_color.get(tuple(frame.pixels[offset : offset + 3]))
        if label is None:
            continue
        x = pixel_index % frame.width
        y = pixel_index // frame.width
        extent = extents.setdefault(label, [x, y, x, y, 0])
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
        box = BoundingBox(
            extent[0], extent[1], extent[2] - extent[0] + 1, extent[3] - extent[1] + 1
        )
        detections.append(
            {
                "type": "object_detection",
                "class_id": label,
                "confidence": 1.0,
                "pixel_count": extent[4],
                "bounding_box": box.normalized(frame.width, frame.height),
                "bounding_box_pixels": box.as_pixels(),
            }
        )
    return detections


def png_chunk(chunk_type: bytes, payload: bytes) -> bytes:
    checksum = binascii.crc32(chunk_type + payload) & 0xFFFFFFFF
    return (
        struct.pack(">I", len(payload))
        + chunk_type
        + payload
        + struct.pack(">I", checksum)
    )


def encode_png(frame: RGBFrame) -> bytes:
    """Encode an RGB frame as a browser-native PNG using the standard library."""
    row_bytes = frame.width * 3
    scanlines = b"".join(
        b"\x00" + frame.pixels[offset : offset + row_bytes]
        for offset in range(0, len(frame.pixels), row_bytes)
    )
    header = struct.pack(">IIBBBBB", frame.width, frame.height, 8, 2, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", header)
        + png_chunk(b"IDAT", zlib.compress(scanlines, level=3))
        + png_chunk(b"IEND", b"")
    )


def scene_description(frame: RGBFrame) -> dict[str, Any]:
    return {
        "id": SOURCE_ID,
        "mode": "synthetic-rgb",
        "generator": {"id": GENERATOR_ID, "kind": "procedural", "uses_ai": False},
        "scene": {
            "id": frame.scene.id,
            "title": frame.scene.title,
            "prompt": frame.scene.prompt,
        },
        "frame": {
            "format": "RGB8",
            "width": frame.width,
            "height": frame.height,
            "byte_length": len(frame.pixels),
            "sha256": frame.sha256,
        },
        "objects": [
            {
                "semantic_label": item.semantic_label,
                "color_rgb": list(item.color),
                "bounding_box_pixels": item.bounding_box.as_pixels(),
            }
            for item in frame.objects
        ],
    }


def process_frame(
    frame: RGBFrame, generation_ms: float = 0.0, raw_frame_export: bool = False
) -> dict[str, Any]:
    started = time.perf_counter()
    detections = detect_semantics(frame)
    inference_ms = (time.perf_counter() - started) * 1000
    produced = {
        item.semantic_label: item.bounding_box.as_pixels() for item in frame.objects
    }
    detected = {item["class_id"]: item["bounding_box_pixels"] for item in detections}
    labels_match = set(produced) == set(detected)
    boxes_match = produced == detected
    observation = {
        "schema_version": OBSERVATION_SCHEMA,
        "source": {
            "id": SOURCE_ID,
            "mode": "synthetic-rgb",
            "frame_sha256": frame.sha256,
            "scene_id": frame.scene.id,
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
        "telemetry": {
            "generation_ms": round(generation_ms, 3),
            "inference_ms": round(inference_ms, 3),
        },
        "comparison": {
            "produced_labels": list(produced),
            "detected_labels": list(detected),
            "semantic_labels_match": labels_match,
            "bounding_boxes_match": boxes_match,
            "all_detections_match_ground_truth": labels_match and boxes_match,
        },
        "observation": observation,
        "raw_sensor_data_exported": raw_frame_export,
    }


def synthetic_observation(
    sequence: int, captured_at: str | None = None
) -> dict[str, Any]:
    return process_frame(produce_frame(sequence, captured_at))["observation"]


@dataclass(frozen=True)
class Snapshot:
    capture: dict[str, Any] | None
    frame_png: bytes | None
    age_seconds: float | None


class ObservationState:
    """Thread-safe storage for recent synchronized captures and PNG frames."""

    def __init__(self, history_size: int = 24) -> None:
        self._lock = threading.Lock()
        self._history_size = history_size
        self._captures: OrderedDict[int, tuple[dict[str, Any], bytes | None]] = (
            OrderedDict()
        )
        self._updated_at: float | None = None

    def publish(self, capture: dict[str, Any], frame_png: bytes | None = None) -> None:
        with self._lock:
            self._captures[capture["sequence"]] = (capture, frame_png)
            self._captures.move_to_end(capture["sequence"])
            while len(self._captures) > self._history_size:
                self._captures.popitem(last=False)
            self._updated_at = time.monotonic()

    def snapshot(self, sequence: int | None = None) -> Snapshot:
        with self._lock:
            if not self._captures:
                return Snapshot(None, None, None)
            selected = (
                self._captures.get(sequence)
                if sequence is not None
                else next(reversed(self._captures.values()))
            )
            if selected is None:
                return Snapshot(None, None, None)
            age = (
                None
                if self._updated_at is None
                else time.monotonic() - self._updated_at
            )
            return Snapshot(selected[0], selected[1], age)


class SyntheticCamera(threading.Thread):
    """Generate frames and process their pixels inside the sensing boundary."""

    def __init__(
        self, state: ObservationState, frames_per_second: int, raw_frame_export: bool
    ) -> None:
        super().__init__(name="synthetic-camera", daemon=True)
        self._state = state
        self._interval = 1 / frames_per_second
        self._raw_frame_export = raw_frame_export
        self._stopped = threading.Event()

    def stop(self) -> None:
        self._stopped.set()

    def run(self) -> None:
        sequence = 0
        while not self._stopped.is_set():
            started = time.perf_counter()
            frame = produce_frame(sequence)
            generation_ms = (time.perf_counter() - started) * 1000
            capture = process_frame(frame, generation_ms, self._raw_frame_export)
            frame_png = encode_png(frame) if self._raw_frame_export else None
            self._state.publish(capture, frame_png)
            sequence += 1
            elapsed = time.perf_counter() - started
            self._stopped.wait(max(0, self._interval - elapsed))


def health_document(
    snapshot: Snapshot,
    stale_after_seconds: int,
    accelerator_device: str,
    raw_frame_export: bool = False,
) -> tuple[dict[str, Any], bool]:
    source_ready = (
        snapshot.age_seconds is not None and snapshot.age_seconds <= stale_after_seconds
    )
    accelerator_available = os.path.exists(accelerator_device)
    status = (
        "unhealthy"
        if not source_ready
        else "ready"
        if accelerator_available
        else "degraded"
    )
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
            "generator": {"id": GENERATOR_ID, "kind": "procedural", "uses_ai": False},
            "processor": {
                "id": PROCESSOR_ID,
                "status": "ready" if source_ready else "unavailable",
                "uses_accelerator": False,
            },
            "accelerator": {
                "device": accelerator_device,
                "status": "available" if accelerator_available else "unavailable",
            },
            "raw_sensor_data_exported": raw_frame_export,
        },
        source_ready,
    )


DEMO_HTML = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Ghaf live sensing pipeline</title>
  <style>
    :root { color-scheme: dark; font-family: Inter,ui-sans-serif,system-ui,sans-serif; }
    * { box-sizing: border-box; }
    body { margin: 0; min-height: 100vh; background: radial-gradient(circle at 30% 0,#16323d,#071014 55%); color: #edf7f7; }
    main { max-width: 1240px; margin: auto; padding: 28px; }
    header { display:flex; justify-content:space-between; gap:24px; align-items:end; margin-bottom:18px; }
    .eyebrow { color:#52e0c4; font:700 12px/1.2 monospace; letter-spacing:.16em; text-transform:uppercase; }
    h1 { font-size:clamp(28px,4vw,48px); margin:6px 0; letter-spacing:-.04em; }
    p { color:#a9bec3; margin:5px 0; }
    .live { color:#60ef9a; font:700 13px monospace; }
    .live::before { content:""; display:inline-block; width:9px; height:9px; margin-right:8px; border-radius:50%; background:#60ef9a; box-shadow:0 0 14px #60ef9a; }
    .stage { position:relative; overflow:hidden; border-radius:18px; border:1px solid #34505a; background:#0b171c; box-shadow:0 28px 70px #0008; aspect-ratio:16/9; }
    #feed { display:block; width:100%; height:100%; image-rendering:pixelated; object-fit:cover; }
    #overlay { position:absolute; inset:0; width:100%; height:100%; }
    .box { fill:transparent; stroke:#5fffd4; stroke-width:2; vector-effect:non-scaling-stroke; }
    .label-bg { fill:#061216dd; }
    .label { fill:#eafff9; font:700 7px monospace; }
    .hud { position:absolute; inset:14px 14px auto auto; padding:7px 10px; border-radius:8px; background:#061216cc; color:#8df5d8; font:700 11px monospace; backdrop-filter:blur(8px); }
    .grid { display:grid; grid-template-columns:1.25fr .75fr; gap:16px; margin-top:16px; }
    .card { border:1px solid #29434c; background:#102027cc; border-radius:14px; padding:17px; }
    .card h2 { margin:0 0 10px; font-size:14px; color:#d9eeee; }
    .prompt { font-size:18px; color:#fff; line-height:1.4; }
    .metrics { display:grid; grid-template-columns:repeat(4,1fr); gap:10px; }
    .metric span { display:block; color:#7f9ca3; font-size:11px; text-transform:uppercase; letter-spacing:.08em; }
    .metric strong { display:block; margin-top:5px; font:700 16px monospace; color:#75e9ce; }
    .tags { display:flex; flex-wrap:wrap; gap:8px; }
    .tag { padding:6px 9px; border:1px solid #39606a; border-radius:99px; color:#bde8df; font:12px monospace; }
    .truth { color:#78eda6; }
    .warn { color:#ffc968; }
    footer { margin-top:14px; color:#6f8990; font-size:12px; }
    code { color:#7fead0; }
    @media(max-width:800px) { header{display:block}.grid{grid-template-columns:1fr}.metrics{grid-template-columns:repeat(2,1fr)} }
  </style>
</head>
<body><main>
  <header><div><div class="eyebrow">Ghaf · isolated sensing VM</div><h1>Live semantic pipeline</h1><p id="scene">Waiting for the on-device producer…</p></div><div class="live">LIVE OVER ETHERNET</div></header>
  <section class="stage"><img id="feed" alt="Live generated frame"><svg id="overlay" viewBox="0 0 320 180"></svg><div class="hud" id="hud">CONNECTING</div></section>
  <section class="grid">
    <div class="card"><h2>Generated scene prompt</h2><div class="prompt" id="prompt">—</div><h2 style="margin-top:16px">Detected semantics</h2><div class="tags" id="detections"></div></div>
    <div class="card"><h2>Pipeline telemetry</h2><div class="metrics"><div class="metric"><span>Frame</span><strong id="seq">—</strong></div><div class="metric"><span>Generate</span><strong id="generate">—</strong></div><div class="metric"><span>Detect</span><strong id="infer">—</strong></div><div class="metric"><span>Match</span><strong id="match">—</strong></div></div></div>
  </section>
  <footer><span class="warn" id="boundary">CHECKING FRAME POLICY</span> · Data travels through <code>net-vm</code> and the SSH tunnel. Generator: <code>procedural-scene-engine</code>; detector: <code>reference-color-segmentation</code>. Neither currently claims AI acceleration.</footer>
  <script>
    const ns="http://www.w3.org/2000/svg", feed=document.querySelector("#feed"), overlay=document.querySelector("#overlay");
    let nextAt=0;
    function addOverlay(item){
      const b=item.bounding_box_pixels, rect=document.createElementNS(ns,"rect");
      Object.entries({x:b.x,y:b.y,width:b.width,height:b.height,class:"box"}).forEach(([k,v])=>rect.setAttribute(k,v)); overlay.appendChild(rect);
      const width=Math.max(34,item.class_id.length*5+8), bg=document.createElementNS(ns,"rect");
      Object.entries({x:b.x,y:Math.max(0,b.y-10),width,height:10,rx:2,class:"label-bg"}).forEach(([k,v])=>bg.setAttribute(k,v)); overlay.appendChild(bg);
      const text=document.createElementNS(ns,"text"); text.setAttribute("x",b.x+3); text.setAttribute("y",Math.max(7,b.y-3)); text.setAttribute("class","label"); text.textContent=item.class_id.toUpperCase(); overlay.appendChild(text);
    }
    async function update(){
      try{
        const response=await fetch("/v1/demo/latest",{cache:"no-store"}); if(!response.ok) throw new Error(`HTTP ${response.status}`);
        const data=await response.json(), seq=data.sequence, raw=data.raw_sensor_data_exported;
        if(raw) await new Promise((resolve,reject)=>{feed.onload=resolve;feed.onerror=reject;feed.src=`/v1/frames/${seq}.png`;});
        else feed.removeAttribute("src");
        overlay.replaceChildren();
        if(!raw){const bg=document.createElementNS(ns,"rect");Object.entries({width:320,height:180,fill:"#102027"}).forEach(([k,v])=>bg.setAttribute(k,v));overlay.appendChild(bg);}
        data.receiver.detected_semantics.forEach(addOverlay);
        document.querySelector("#scene").textContent=data.producer.scene.title;
        document.querySelector("#prompt").textContent=`“${data.producer.scene.prompt}”`;
        document.querySelector("#seq").textContent=seq;
        document.querySelector("#generate").textContent=`${data.telemetry.generation_ms.toFixed(1)} ms`;
        document.querySelector("#infer").textContent=`${data.telemetry.inference_ms.toFixed(1)} ms`;
        const matched=data.comparison.all_detections_match_ground_truth;
        document.querySelector("#match").textContent=matched?"100%":"CHECK"; document.querySelector("#match").className=matched?"truth":"warn";
        document.querySelector("#hud").textContent=`${data.producer.frame.width}×${data.producer.frame.height} RGB · ${data.receiver.detected_semantics.length} OBJECTS`;
        const boundary=document.querySelector("#boundary"); boundary.textContent=raw?"DEBUG RAW-FRAME EXPORT":"SEMANTICS-ONLY MODE"; boundary.className=raw?"warn":"truth";
        const tags=document.querySelector("#detections"); tags.replaceChildren(); data.receiver.detected_semantics.forEach(item=>{const tag=document.createElement("span");tag.className="tag";tag.textContent=`${item.class_id} · ${(item.confidence*100).toFixed(0)}%`;tags.appendChild(tag);});
      }catch(error){document.querySelector("#hud").textContent=`OFFLINE · ${error}`;}
      nextAt=window.setTimeout(update,200);
    }
    window.addEventListener("beforeunload",()=>clearTimeout(nextAt)); update();
  </script>
</main></body></html>
"""


def handler_factory(
    state: ObservationState,
    stale_after_seconds: int,
    accelerator_device: str,
    raw_frame_export: bool = False,
) -> type[BaseHTTPRequestHandler]:
    class SensingHandler(BaseHTTPRequestHandler):
        server_version = "ghaf-sensing-demo/0.3"

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
                    "default-src 'none'; connect-src 'self'; img-src 'self'; "
                    "script-src 'unsafe-inline'; style-src 'unsafe-inline'",
                )
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def send_json(self, status: HTTPStatus, document: dict[str, Any]) -> None:
            self.send_payload(
                status,
                "application/json",
                json.dumps(document, separators=(",", ":"), sort_keys=True).encode(),
            )

        def current_capture(self) -> Snapshot | None:
            snapshot = state.snapshot()
            if snapshot.capture is None or snapshot.age_seconds is None:
                self.send_json(
                    HTTPStatus.SERVICE_UNAVAILABLE, {"error": "observation_unavailable"}
                )
                return None
            if snapshot.age_seconds > stale_after_seconds:
                self.send_json(
                    HTTPStatus.SERVICE_UNAVAILABLE, {"error": "observation_stale"}
                )
                return None
            return snapshot

        def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
            parsed = urlsplit(self.path)
            path = parsed.path
            if path in ("/", "/demo"):
                self.send_payload(
                    HTTPStatus.OK, "text/html; charset=utf-8", DEMO_HTML.encode()
                )
                return
            if path == "/healthz":
                document, source_ready = health_document(
                    state.snapshot(),
                    stale_after_seconds,
                    accelerator_device,
                    raw_frame_export,
                )
                self.send_json(
                    HTTPStatus.OK if source_ready else HTTPStatus.SERVICE_UNAVAILABLE,
                    document,
                )
                return
            if path in ("/v1/demo/latest", "/v1/observations/latest"):
                snapshot = self.current_capture()
                if snapshot is None:
                    return
                document = (
                    snapshot.capture
                    if path == "/v1/demo/latest"
                    else snapshot.capture["observation"]
                )
                self.send_json(HTTPStatus.OK, document)
                return
            if path == "/v1/frames/latest.png":
                snapshot = self.current_capture()
                if snapshot is None:
                    return
                self.send_frame(snapshot)
                return
            if path.startswith("/v1/frames/") and path.endswith(".png"):
                try:
                    sequence = int(
                        path.removeprefix("/v1/frames/").removesuffix(".png")
                    )
                except ValueError:
                    self.send_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})
                    return
                snapshot = state.snapshot(sequence)
                self.send_frame(snapshot)
                return
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})

        def send_frame(self, snapshot: Snapshot) -> None:
            if not raw_frame_export:
                self.send_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})
            elif snapshot.frame_png is None:
                self.send_json(HTTPStatus.GONE, {"error": "frame_unavailable"})
            else:
                self.send_payload(HTTPStatus.OK, "image/png", snapshot.frame_png)

        def log_message(self, message: str, *args: object) -> None:
            logging.info("%s - %s", self.address_string(), message % args)

    return SensingHandler


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--frames-per-second", type=int, default=5)
    parser.add_argument("--stale-after-seconds", type=int, default=5)
    parser.add_argument("--accelerator-device", default="/dev/nvgpu/igpu0")
    parser.add_argument("--raw-frame-export", action="store_true")
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
    camera = SyntheticCamera(state, args.frames_per_second, args.raw_frame_export)
    server = ThreadingHTTPServer(
        (args.bind, args.port),
        handler_factory(
            state,
            args.stale_after_seconds,
            args.accelerator_device,
            args.raw_frame_export,
        ),
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
