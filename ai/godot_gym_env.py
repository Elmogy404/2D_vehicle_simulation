"""Gymnasium interface for the Setup 1 PPO driving task."""

from __future__ import annotations

from typing import Any

import numpy as np
import gymnasium as gym
from gymnasium import spaces

from godot_bridge import GodotBridge, ResetUnavailableError
from interface_schema import (
    ACTION_SIZE,
    OBSERVATION_SIZE,
    SCHEMA_VERSION,
    action_space_high,
    action_space_low,
    metadata as interface_metadata,
    observation_space_high,
    observation_space_low,
    validate_action,
    validate_observation,
    validate_remote_metadata,
)


ENVIRONMENT_VERSION = 3


class GodotRoadEnv(gym.Env[np.ndarray, np.ndarray]):
    """Empty-road route-following environment backed by a Godot subprocess."""

    metadata = {
        "render_modes": [],
        "interface_schema_version": SCHEMA_VERSION,
        "observation_size": OBSERVATION_SIZE,
        "action_size": ACTION_SIZE,
    }

    def __init__(
        self,
        godot_executable: str | None = None,
        *,
        visible: bool = False,
        reward_config: dict[str, float] | None = None,
        parent_window_id: int | None = None,
        close_visible_on_exit: bool = False,
        generator_type: str = "original",
    ) -> None:
        super().__init__()
        if generator_type not in {"original", "segmented"}:
            raise ValueError("generator_type must be original or segmented")
        self.generator_type = generator_type
        self.action_space = spaces.Box(
            low=action_space_low(),
            high=action_space_high(),
            dtype=np.float32,
        )
        self.observation_space = spaces.Box(
            low=observation_space_low(),
            high=observation_space_high(),
            dtype=np.float32,
        )
        self.bridge = GodotBridge(godot_executable, visible=visible,
                                  parent_window_id=parent_window_id,
                                  close_visible_on_exit=close_visible_on_exit)
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
        reset_options["generator_type"] = self.generator_type
        reset_options["reward_config"] = self.reward_config
        reset_options["reuse_map"] = seed is None and not restoring
        if self._pending_training_state is not None:
            reset_options["training_state"] = self._pending_training_state
        # Evaluation uses an exact seed and must expose an invalid map rather
        # than silently replace it. Unseeded training can recover deterministically.
        attempts = 1 if seed is not None and not restoring else 8
        schema_info = interface_metadata()
        for attempt in range(attempts):
            actual_seed = (episode_seed + attempt * 1_000_003) % (2**31 - 1)
            try:
                response = self.bridge.request(
                    {
                        "type": "reset",
                        "seed": actual_seed,
                        "options": reset_options,
                        **schema_info,
                    }
                )
                break
            except ResetUnavailableError:
                if attempt == attempts - 1:
                    raise
        self._pending_training_state = None
        info = dict(response.get("info", {}))
        validate_remote_metadata(info.get("interface_schema"), source="Godot reset response")
        observation = validate_observation(response["observation"])
        info.update(requested_seed=episode_seed, reset_retries=attempt)
        info["godot_pid"] = self.bridge.process_id
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
        clipped_action, action_clipped = validate_action(action, clip=True)
        schema_info = interface_metadata()
        response = self.bridge.request(
            {
                "type": "step",
                "action": clipped_action.tolist(),
                **schema_info,
            }
        )
        info = dict(response.get("info", {}))
        validate_remote_metadata(info.get("interface_schema"), source="Godot step response")
        observation = validate_observation(response["observation"])
        info["action_clipped"] = action_clipped or bool(info.get("action_clipped", False))
        info["godot_pid"] = self.bridge.process_id
        return (
            observation,
            float(response["reward"]),
            bool(response["terminated"]),
            bool(response["truncated"]),
            info,
        )

    def close(self) -> None:
        if hasattr(self, "bridge"):
            self.bridge.close()
