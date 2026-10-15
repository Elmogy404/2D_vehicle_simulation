"""Fast tests for the GUI/Python training control protocol."""

from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "ai"))

from training_control import TrainingControl, parse_reward_config


class TrainingControlTests(unittest.TestCase):
    def test_reward_config_validation(self) -> None:
        self.assertEqual(parse_reward_config(None)["goal_reward"], 40.0)
        self.assertEqual(parse_reward_config(None)["max_speed_reward"], 0.05)
        self.assertEqual(parse_reward_config('{"goal_reward": 75}')["goal_reward"], 75.0)
        self.assertEqual(parse_reward_config('{"max_speed_reward": 0.2}')["max_speed_reward"], 0.2)
        for invalid in ('{"unknown": 1}', '{"goal_reward": -1}', '{"goal_reward": "high"}'):
            with self.assertRaises(ValueError):
                parse_reward_config(invalid)

    def test_pause_resume_and_stop(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            control_path = Path(directory) / "control.json"
            status_path = Path(directory) / "status.json"
            controller = TrainingControl(
                str(control_path), str(status_path), "test-run", "test-model", 1024, 2
            )

            def command(value: str) -> None:
                control_path.write_text(
                    json.dumps({"run_id": "test-run", "command": value}), encoding="utf-8"
                )

            command("pause")
            completed: list[bool] = []
            worker = threading.Thread(target=lambda: completed.append(controller.poll(128)))
            worker.start()
            deadline = time.monotonic() + 3.0
            while not status_path.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertEqual(json.loads(status_path.read_text(encoding="utf-8"))["state"], "paused")
            self.assertTrue(worker.is_alive())
            command("run")
            worker.join(timeout=3.0)
            self.assertEqual(completed, [True])
            command("stop")
            self.assertFalse(controller.poll(256))
            self.assertTrue(controller.stop_requested)
            self.assertEqual(json.loads(status_path.read_text(encoding="utf-8"))["state"], "stopping")


if __name__ == "__main__":
    unittest.main()
