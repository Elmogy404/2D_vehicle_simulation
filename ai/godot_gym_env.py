"""Gymnasium interface for the Setup 1 PPO driving task."""

from __future__ import annotations

from typing import Any

import numpy as np
import gymnasium as gym
from gymnasium import spaces

from godot_bridge import GodotBridge, ResetUnavailableError


OBSERVATION_SIZE = 31
ACTION_SIZE = 2
ENVIRONMENT_VERSION = 2


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
        self._pending_training_state: dict[str, Any] | None = None

    def reset(
        self,
        *,
        seed: int | None = None,
        options: dict[str, Any] | None = None,
    ) -> tuple[np.ndarray, dict[str, Any]]:
        restoring = self._pending_training_state is not None
        super().reset(seed=None if restoring else seed)
        episode_seed = (
            int(seed)
            if seed is not None and not restoring
            else int(self.np_random.integers(1, 2**31 - 1))
        )
        reset_options = dict(options or {})
        reset_options["reward_config"] = self.reward_config
        if self._pending_training_state is not None:
            reset_options["training_state"] = self._pending_training_state
        # Evaluation uses an exact seed and must expose an invalid map rather
        # than silently replace it. Unseeded training can recover deterministically.
        attempts = 1 if seed is not None and not restoring else 8
        for attempt in range(attempts):
            actual_seed = (episode_seed + attempt * 1_000_003) % (2**31 - 1)
            try:
                response = self.bridge.request(
                    {"type": "reset", "seed": actual_seed, "options": reset_options}
                )
                break
            except ResetUnavailableError:
                if attempt == attempts - 1:
                    raise
        self._pending_training_state = None
        observation = np.asarray(response["observation"], dtype=np.float32)
        self._validate_observation(observation)
        info = dict(response.get("info", {}))
        info.update(requested_seed=episode_seed, reset_retries=attempt)
        return observation, info

    def get_training_state(self) -> dict[str, Any]:
        return {
            "curriculum": self.bridge.request({"type": "training_state"}),
            "random_state": self.np_random.bit_generator.state,
        }

    def set_training_state(self, state: dict[str, Any]) -> None:
        self._pending_training_state = dict(state.get("curriculum", {}))
        if "random_state" in state:
            self.np_random.bit_generator.state = state["random_state"]

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
