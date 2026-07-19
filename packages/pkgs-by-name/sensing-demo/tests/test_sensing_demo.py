# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

import json
import sys
import threading
import unittest
from http.server import ThreadingHTTPServer
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import urlopen

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from sensing_demo import (  # noqa: E402
    OBSERVATION_SCHEMA,
    ObservationState,
    Snapshot,
    handler_factory,
    health_document,
    synthetic_observation,
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

    def test_observation_contract_does_not_export_raw_data(self) -> None:
        observation = synthetic_observation(7, "2026-07-19T12:00:00Z")
        self.state.publish(observation)

        status, document = self.get_json("/v1/observations/latest")

        self.assertEqual(status, 200)
        self.assertEqual(document["schema_version"], OBSERVATION_SCHEMA)
        self.assertEqual(document["sequence"], 7)
        self.assertFalse(document["raw_sensor_data_exported"])
        self.assertNotIn("frame", document)
        self.assertNotIn("image", document)

    def test_health_reports_synthetic_source_and_missing_accelerator(self) -> None:
        self.state.publish(synthetic_observation(0))

        status, document = self.get_json("/healthz")

        self.assertEqual(status, 200)
        self.assertEqual(document["status"], "degraded")
        self.assertEqual(document["source"]["mode"], "synthetic")
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
            Snapshot(synthetic_observation(0), age_seconds=6),
            stale_after_seconds=5,
            accelerator_device="/device/that/does/not/exist",
        )

        self.assertFalse(source_ready)
        self.assertEqual(document["status"], "unhealthy")
        self.assertEqual(document["source"]["status"], "unavailable")


if __name__ == "__main__":
    unittest.main()
