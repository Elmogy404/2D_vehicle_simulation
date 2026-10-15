"""Gymnasium interface for the Setup 1 PPO driving task."""

from __future__ import annotations

from typing import Any

import numpy as np
import gymnasium as gym
from gymnasium import spaces

from godot_bridge import GodotBridge


OBSERVATION_SIZE = 31
ACTION_SIZE = 2


class GodotRoadEnv(gym.Env[np.ndarray, np.ndarray]):
    """Empty-road route-following environment backed by a Godot subprocess."""

    metadata = {"render_modes": []}

    def __init__(
        self,
        godot_executable: str | None = None,
        *,
        visible: bool = False,
        reward_config: dict[str, float] | None = None,
    ) -> None:
        super().__init__()
        self.action_space = spaces.Box(
            low=np.full(ACTION_SIZE, -1.0, dtype=np.float32),
            high=np.full(ACTION_SIZE, 1.0, dtype=np.float32),
            dtype=np.float32,
        )
        self.observation_space = spaces.Box(
            low=np.full(OBSERVATION_SIZE, -1.0, dtype=np.float32),
            high=np.full(OBSERVATION_SIZE, 1.0, dtype=np.float32),
            dtype=np.float32,
        )
        self.bridge = GodotBridge(godot_executable, visible=visible)
        self.reward_config = dict(reward_config or {})

    def reset(
        self,
        *,
        seed: int | None = None,
        options: dict[str, Any] | None = None,
    ) -> tuple[np.ndarray, dict[str, Any]]:
        super().reset(seed=seed)
        episode_seed = (
            int(seed)
            if seed is not None
            else int(self.np_random.integers(1, 2**31 - 1))
        )
        reset_options = dict(options or {})
        reset_options["reward_config"] = self.reward_config
        response = self.bridge.request(
            {"type": "reset", "seed": episode_seed, "options": reset_options}
        )
        observation = np.asarray(response["observation"], dtype=np.float32)
        self._validate_observation(observation)
        return observation, dict(response.get("info", {}))

    def step(
        self,
        action: np.ndarray,
    ) -> tuple[np.ndarray, float, bool, bool, dict[str, Any]]:
        clipped_action = np.asarray(action, dtype=np.float32).reshape(ACTION_SIZE)
        clipped_action = np.clip(clipped_action, -1.0, 1.0)
        response = self.bridge.request(
            {"type": "step", "action": clipped_action.tolist()}
        )
        observation = np.asarray(response["observation"], dtype=np.float32)
        self._validate_observation(observation)
        return (
            observation,
            float(response["reward"]),
            bool(response["terminated"]),
            bool(response["truncated"]),
            dict(response.get("info", {})),
        )

    def close(self) -> None:
        if hasattr(self, "bridge"):
            self.bridge.close()

    def _validate_observation(self, observation: np.ndarray) -> None:
        if observation.shape != (OBSERVATION_SIZE,):
            raise RuntimeError(
                f"Expected {OBSERVATION_SIZE} observation values, got {observation.shape}"
            )
        if not np.isfinite(observation).all():
            raise RuntimeError("Godot returned a non-finite observation")
