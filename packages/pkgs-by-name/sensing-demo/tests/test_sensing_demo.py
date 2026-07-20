# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

import json
import sys
import threading
import unittest
from dataclasses import replace
from http.server import ThreadingHTTPServer
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import urlopen

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from sensing_demo import (  # noqa: E402
    DEMO_SCHEMA,
    FRAME_HEIGHT,
    FRAME_WIDTH,
    HEALTH_SCHEMA,
    OBSERVATION_SCHEMA,
    ObservationState,
    Snapshot,
    detect_semantics,
    handler_factory,
    health_document,
    process_frame,
    produce_frame,
)


class SensingDemoTest(unittest.TestCase):
    def setUp(self) -> None:
        self.state = ObservationState()
        handler = handler_factory(self.state, 5, "/device/that/does/not/exist")
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base_url = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def get_json(self, path: str) -> tuple[int, dict]:
        try:
            response = urlopen(f"{self.base_url}{path}", timeout=2)
        except HTTPError as error:
            response = error
        with response:
            return response.status, json.load(response)

    def test_producer_renders_real_rgb_pixels(self) -> None:
        first = produce_frame(7, "2026-07-20T12:00:00Z")
        second = produce_frame(8, "2026-07-20T12:00:01Z")

        self.assertEqual(len(first.pixels), FRAME_WIDTH * FRAME_HEIGHT * 3)
        self.assertNotEqual(first.pixels, second.pixels)
        self.assertNotEqual(first.sha256, second.sha256)

    def test_receiver_derives_semantics_from_pixels(self) -> None:
        frame = produce_frame(7)

        detections = detect_semantics(frame)

        self.assertEqual(
            [detection["class_id"] for detection in detections],
            ["person", "vehicle", "obstacle"],
        )
        self.assertEqual(
            [detection["bounding_box_pixels"] for detection in detections],
            [scene_object.bounding_box.as_pixels() for scene_object in frame.objects],
        )

    def test_receiver_does_not_use_producer_ground_truth(self) -> None:
        frame = produce_frame(7)
        blank_frame = replace(frame, pixels=bytes(len(frame.pixels)))

        self.assertEqual(detect_semantics(blank_frame), [])

    def test_demo_contract_compares_producer_and_receiver(self) -> None:
        capture = process_frame(produce_frame(7, "2026-07-20T12:00:00Z"))

        self.assertEqual(capture["schema_version"], DEMO_SCHEMA)
        self.assertEqual(capture["producer"]["frame"]["format"], "RGB8")
        self.assertEqual(
            capture["producer"]["frame"]["byte_length"],
            FRAME_WIDTH * FRAME_HEIGHT * 3,
        )
        self.assertEqual(
            capture["comparison"]["produced_labels"],
            ["person", "vehicle", "obstacle"],
        )
        self.assertTrue(capture["comparison"]["semantic_labels_match"])
        self.assertTrue(capture["comparison"]["bounding_boxes_match"])
        self.assertTrue(capture["comparison"]["all_detections_match_ground_truth"])
        self.assertFalse(capture["raw_sensor_data_exported"])
        self.assertNotIn("pixels", capture)

    def test_observation_contract_does_not_export_raw_data(self) -> None:
        capture = process_frame(produce_frame(7, "2026-07-20T12:00:00Z"))
        self.state.publish(capture)

        status, document = self.get_json("/v1/observations/latest")

        self.assertEqual(status, 200)
        self.assertEqual(document["schema_version"], OBSERVATION_SCHEMA)
        self.assertEqual(document["sequence"], 7)
        self.assertFalse(document["raw_sensor_data_exported"])
        self.assertNotIn("frame", document)
        self.assertNotIn("image", document)

    def test_demo_endpoint_exposes_descriptions_not_pixels(self) -> None:
        self.state.publish(process_frame(produce_frame(7)))

        status, document = self.get_json("/v1/demo/latest")

        def keys(value: object) -> set[str]:
            if isinstance(value, dict):
                return set(value) | {
                    key for child in value.values() for key in keys(child)
                }
            if isinstance(value, list):
                return {key for child in value for key in keys(child)}
            return set()

        self.assertEqual(status, 200)
        self.assertIn("producer", document)
        self.assertIn("receiver", document)
        self.assertNotIn("pixels", keys(document))
        self.assertNotIn("image", keys(document))

    def test_health_reports_processor_and_missing_accelerator(self) -> None:
        self.state.publish(process_frame(produce_frame(0)))

        status, document = self.get_json("/healthz")

        self.assertEqual(status, 200)
        self.assertEqual(document["schema_version"], HEALTH_SCHEMA)
        self.assertEqual(document["status"], "degraded")
        self.assertEqual(document["source"]["mode"], "synthetic-rgb")
        self.assertEqual(document["processor"]["status"], "ready")
        self.assertFalse(document["processor"]["uses_accelerator"])
        self.assertEqual(document["accelerator"]["status"], "unavailable")

    def test_observation_is_unavailable_before_first_capture(self) -> None:
        status, document = self.get_json("/v1/observations/latest")

        self.assertEqual(status, 503)
        self.assertEqual(document, {"error": "observation_unavailable"})

    def test_raw_frame_endpoint_is_not_present(self) -> None:
        status, document = self.get_json("/v1/frames/latest")

        self.assertEqual(status, 404)
        self.assertEqual(document, {"error": "not_found"})

    def test_stale_source_is_unhealthy(self) -> None:
        document, source_ready = health_document(
            Snapshot(process_frame(produce_frame(0)), age_seconds=6),
            stale_after_seconds=5,
            accelerator_device="/device/that/does/not/exist",
        )

        self.assertFalse(source_ready)
        self.assertEqual(document["status"], "unhealthy")
        self.assertEqual(document["source"]["status"], "unavailable")


if __name__ == "__main__":
    unittest.main()
