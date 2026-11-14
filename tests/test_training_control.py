"""Fast tests for the GUI/Python training control protocol."""

from __future__ import annotations

import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "ai"))

from training_control import TrainingControl, parse_reward_config


class TrainingControlTests(unittest.TestCase):
    def test_transient_windows_lock_retries_without_exposing_partial_json(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "status.json"
            controller = TrainingControl(None, str(path), "test", "model", 100, 1)
            controller.write_status("running", 1)
            replace = os.replace
            failures = 0

            def sharing_violation(source, destination):
                nonlocal failures
                self.assertEqual(json.loads(path.read_text())["timesteps"], 1)
                if failures < 2:
                    failures += 1
                    raise PermissionError(13, "simulated Windows sharing violation")
                return replace(source, destination)

            with patch("training_control.os.replace", side_effect=sharing_violation) as replacement, patch("training_control.time.sleep"):
                self.assertTrue(controller.write_status("running", 2))
            self.assertEqual(replacement.call_count, 3)
            self.assertEqual(json.loads(path.read_text())["timesteps"], 2)
            self.assertEqual(list(path.parent.glob("*.tmp")), [])

    def test_persistent_status_failure_keeps_stop_and_save_states_working(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "status.json"
            command = Path(directory) / "control.json"
            controller = TrainingControl(str(command), str(path), "test", "model", 100, 1)
            controller.write_status("running", 1)
            command.write_text(json.dumps({"run_id": "test", "command": "stop"}))
            with patch("training_control.os.replace", side_effect=PermissionError(13, "locked")), patch("training_control.time.sleep"), self.assertLogs("training_control", level="WARNING") as logs:
                self.assertFalse(controller.write_status("running", 2))
                self.assertFalse(controller.poll(3))
                self.assertTrue(controller.stop_requested)
                self.assertFalse(controller.write_status("saving", 3))
                self.assertFalse(controller.write_status("stopped", 3))
            self.assertEqual(controller.state, "stopped")
            self.assertEqual(len(logs.output), 1, "persistent file failure flooded the training log")
            self.assertEqual(json.loads(path.read_text())["timesteps"], 1)
            self.assertEqual(list(path.parent.glob("*.tmp")), [])
            self.assertTrue(controller.write_status("stopped", 3))
            self.assertEqual(json.loads(path.read_text())["state"], "stopped")

    @unittest.skipUnless(os.name == "nt", "Windows delete-sharing semantics")
    def test_actual_windows_read_handle_cannot_crash_the_status_writer(self) -> None:
        import ctypes
        from ctypes import wintypes

        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                      wintypes.LPVOID, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
        kernel.CreateFileW.restype = wintypes.HANDLE
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "status.json"
            controller = TrainingControl(None, str(path), "test", "model", 100, 1)
            controller.write_status("running", 1)
            handle = kernel.CreateFileW(str(path), 0x80000000, 1, None, 3, 0, None)
            self.assertNotEqual(handle, wintypes.HANDLE(-1).value)
            blocked = threading.Event()
            completed = []
            replace = os.replace

            def observe_lock(source, destination):
                try:
                    return replace(source, destination)
                except PermissionError:
                    blocked.set()
                    raise

            with patch("training_control.os.replace", side_effect=observe_lock):
                writer = threading.Thread(target=lambda: completed.append(controller.write_status("running", 42)))
                writer.start()
                try:
                    self.assertTrue(blocked.wait(timeout=2), "could not reproduce the Windows sharing violation")
                finally:
                    kernel.CloseHandle(handle)
                    writer.join(timeout=3)
            self.assertFalse(writer.is_alive())
            self.assertEqual(completed, [True])
            self.assertEqual(json.loads(path.read_text())["timesteps"], 42)

    def test_reward_config_validation(self) -> None:
        self.assertEqual(parse_reward_config(None)["goal_reward"], 40.0)
        self.assertEqual(parse_reward_config(None)["max_speed_reward"], 0.0)
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
