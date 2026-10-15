"""File-based control and status for training launched from the Godot GUI."""

from __future__ import annotations

import json
import os
from pathlib import Path
import time
from typing import Any


DEFAULT_REWARD_CONFIG: dict[str, float] = {
    "progress_gain": 1.0,
    "max_speed_reward": 0.05,
    "lane_penalty": 0.12,
    "edge_penalty": 0.6,
    "heading_penalty": 0.08,
    "step_penalty": 0.01,
    "crash_penalty": 35.0,
    "off_road_penalty": 35.0,
    "goal_reward": 40.0,
    "timeout_penalty": 20.0,
}


def parse_reward_config(raw: str | None) -> dict[str, float]:
    """Validate GUI/CLI reward overrides without accepting unknown settings."""
    result = DEFAULT_REWARD_CONFIG.copy()
    if not raw:
        return result
    supplied = json.loads(raw)
    if not isinstance(supplied, dict):
        raise ValueError("--reward-config must be a JSON object")
    for key, value in supplied.items():
        if key not in result:
            raise ValueError(f"Unknown reward setting: {key}")
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise ValueError(f"Reward setting {key} must be numeric")
        number = float(value)
        if not 0.0 <= number <= 1000.0 or number != number:
            raise ValueError(f"Reward setting {key} must be finite and between 0 and 1000")
        result[key] = number
    return result


class TrainingControl:
    def __init__(
        self,
        control_file: str | None,
        status_file: str | None,
        run_id: str,
        run_name: str,
        total_steps: int,
        workers: int,
        log_path: str = "",
    ) -> None:
        self.control_file = Path(control_file) if control_file else None
        self.status_file = Path(status_file) if status_file else None
        self.run_id = run_id
        self.run_name = run_name
        self.total_steps = total_steps
        self.workers = workers
        self.log_path = log_path
        self.state = "starting"
        self.stop_requested = False
        self.last_reported_steps = -1
        self.last_evaluation: dict[str, Any] = {}
        self.message = "Starting PPO training"

    def write_status(self, state: str, timesteps: int, message: str = "") -> None:
        self.state = state
        if message:
            self.message = message
        if self.status_file is None:
            return
        payload = {
            "run_id": self.run_id,
            "pid": os.getpid(),
            "state": state,
            "timesteps": timesteps,
            "total_steps": self.total_steps,
            "workers": self.workers,
            "run_name": self.run_name,
            "log_path": self.log_path,
            "message": self.message,
            "last_evaluation": self.last_evaluation,
            "updated_at": time.time(),
        }
        self.status_file.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.status_file.with_name(self.status_file.name + f".{os.getpid()}.tmp")
        temporary.write_text(json.dumps(payload), encoding="utf-8")
        os.replace(temporary, self.status_file)

    def _command(self) -> str:
        if self.control_file is None:
            return "run"
        try:
            payload = json.loads(self.control_file.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            # The GUI may be between truncating and rewriting the small file.
            return "pause" if self.state == "paused" else "run"
        if not isinstance(payload, dict) or payload.get("run_id") != self.run_id:
            return "run"
        command = str(payload.get("command", "run"))
        return command if command in {"run", "pause", "stop"} else "run"

    def poll(self, timesteps: int) -> bool:
        command = self._command()
        if command == "stop":
            self.stop_requested = True
            self.write_status("stopping", timesteps, "Saving the current model and stopping")
            return False
        if command == "pause":
            self.write_status("paused", timesteps, "Training paused; workers are idle")
            while command == "pause":
                time.sleep(0.2)
                command = self._command()
            if command == "stop":
                self.stop_requested = True
                self.write_status("stopping", timesteps, "Saving the current model and stopping")
                return False
            self.write_status("running", timesteps, "Training resumed")
        elif timesteps - self.last_reported_steps >= 256 or self.state != "running":
            self.write_status("running", timesteps, "Training in progress")
            self.last_reported_steps = timesteps
        return True
