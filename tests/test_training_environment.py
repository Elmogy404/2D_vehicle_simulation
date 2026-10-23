"""Reset recovery and checkpoint state must preserve reproducibility."""
from __future__ import annotations

from copy import deepcopy
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

import numpy as np
import gymnasium as gym
from gymnasium import spaces

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "ai"))
from godot_bridge import ResetUnavailableError
from godot_gym_env import ENVIRONMENT_VERSION, GodotRoadEnv
from train import capture_training_state, restore_training_state
import train


def reset_response() -> dict:
    return {"observation": [0.0] * 31, "info": {"seed": 10}}


class EnvironmentStateTests(unittest.TestCase):
    def make_env(self) -> GodotRoadEnv:
        with patch("godot_gym_env.GodotBridge"):
            return GodotRoadEnv()

    def test_training_retries_only_recoverable_reset_failures(self) -> None:
        env = self.make_env()
        env.bridge.request.side_effect = [ResetUnavailableError("no trip"), reset_response()]
        _obs, info = env.reset()
        self.assertEqual(info["reset_retries"], 1)
        calls = env.bridge.request.call_args_list
        self.assertEqual((calls[1].args[0]["seed"] - calls[0].args[0]["seed"]) % (2**31 - 1), 1_000_003)
        env.bridge.request.reset_mock()
        env.bridge.request.side_effect = RuntimeError("invalid reward configuration")
        with self.assertRaisesRegex(RuntimeError, "invalid reward"):
            env.reset()
        self.assertEqual(env.bridge.request.call_count, 1)

    def test_seeded_evaluation_does_not_hide_exhausted_map_search(self) -> None:
        env = self.make_env()
        env.bridge.request.side_effect = ResetUnavailableError("no validated trip")
        with self.assertRaises(ResetUnavailableError):
            env.reset(seed=10)
        self.assertEqual(env.bridge.request.call_count, 1)

    def test_retry_limit_preserves_failure(self) -> None:
        env = self.make_env()
        env.bridge.request.side_effect = ResetUnavailableError("unavailable")
        with self.assertRaises(ResetUnavailableError):
            env.reset()
        self.assertEqual(env.bridge.request.call_count, 8)

    def test_resume_restores_curriculum_and_rng_before_first_reset(self) -> None:
        env = self.make_env()
        generator = np.random.default_rng(1234)
        random_state = deepcopy(generator.bit_generator.state)
        expected_seed = int(generator.integers(1, 2**31 - 1))
        curriculum = {"curriculum_stage": 5, "recent_results": [True, False]}
        env.set_training_state({"curriculum": curriculum, "random_state": random_state})
        env.bridge.request.return_value = reset_response()
        # SB3 supplies its startup seed even when loading a saved policy.
        env.reset(seed=7)
        message = env.bridge.request.call_args.args[0]
        self.assertEqual(message["seed"], expected_seed)
        self.assertEqual(message["options"]["training_state"], curriculum)
        env.reset()
        self.assertNotIn("training_state", env.bridge.request.call_args.args[0]["options"])

    def test_checkpoint_captures_and_restores_each_worker(self) -> None:
        model = Mock()
        env = model.get_env.return_value
        env.num_envs = 2
        states = [{"curriculum": {"curriculum_stage": 2}}, {"curriculum": {"curriculum_stage": 6}}]
        env.env_method.return_value = states
        capture_training_state(model)
        self.assertEqual(model.training_environment_state["version"], ENVIRONMENT_VERSION)
        env.env_method.reset_mock()
        restore_training_state(model)
        for index, state in enumerate(states):
            env.env_method.assert_any_call("set_training_state", state, indices=index)
        env.num_envs = 1
        with self.assertRaisesRegex(ValueError, "worker count"):
            restore_training_state(model)

    def test_old_checkpoints_require_fresh_training(self) -> None:
        model = Mock(training_environment_state={"version": 1, "workers": []})
        with self.assertRaisesRegex(ValueError, "old training environment"):
            restore_training_state(model)


class TinyDrivingEnv(gym.Env):
    """Fast simulator substitute to exercise real PPO checkpoint callbacks."""
    observation_space = spaces.Box(-1.0, 1.0, shape=(31,), dtype=np.float32)
    action_space = spaces.Box(-1.0, 1.0, shape=(2,), dtype=np.float32)

    def __init__(self, success: bool = True, fail: bool = False) -> None:
        self.success = success
        self.fail = fail
        self.stage = 5

    def reset(self, *, seed=None, options=None):
        super().reset(seed=seed)
        return np.zeros(31, dtype=np.float32), {}

    def step(self, action):
        if self.fail:
            raise RuntimeError("injected environment failure")
        return np.zeros(31, dtype=np.float32), 1.0, True, False, {
            "success": self.success, "turn_requirement_met": True, "route_turns": 4,
        }

    def get_training_state(self):
        return {"curriculum": {"curriculum_stage": self.stage}, "random_state": self.np_random.bit_generator.state}

    def set_training_state(self, state):
        self.stage = state["curriculum"]["curriculum_stage"]
        self.np_random.bit_generator.state = state["random_state"]


class TrainerCheckpointTests(unittest.TestCase):
    def test_resume_preserves_best_model_and_worker_state(self) -> None:
        from stable_baselines3.common.monitor import Monitor
        with tempfile.TemporaryDirectory() as directory:
            base = ["train.py", "--run-name", "checkpoint_test", "--output-root", directory,
                    "--eval-every", "1024", "--eval-episodes", "8", "--early-stop-patience", "0"]
            with patch.object(train, "make_training_env", side_effect=lambda *args: Monitor(TinyDrivingEnv())), patch.object(sys, "argv", base + ["--steps", "64"]):
                train.main()
            best = Path(directory) / "models/checkpoint_test_best.zip"
            original_best = best.read_bytes()
            latest = Path(directory) / "models/checkpoint_test.zip"
            restored_envs = []
            def make_env(*args):
                env = TinyDrivingEnv(success=False)
                env.stage = 0
                restored_envs.append(env)
                return Monitor(env)
            with patch.object(train, "make_training_env", side_effect=make_env), patch.object(sys, "argv", base + ["--steps", "1088", "--resume", str(latest)]):
                train.main()
            self.assertEqual(restored_envs[0].stage, 5)
            self.assertEqual(best.read_bytes(), original_best, "worse resumed evaluation overwrote best policy")

    def test_environment_failure_saves_recoverable_policy(self) -> None:
        from stable_baselines3.common.monitor import Monitor
        with tempfile.TemporaryDirectory() as directory:
            argv = ["train.py", "--steps", "64", "--run-name", "recovery_test", "--output-root", directory,
                    "--eval-every", "0", "--early-stop-patience", "0"]
            with patch.object(train, "make_training_env", side_effect=lambda *args: Monitor(TinyDrivingEnv(fail=True))), patch.object(sys, "argv", argv):
                with self.assertRaisesRegex(RuntimeError, "injected environment failure"):
                    train.main()
            recovery = list((Path(directory) / "models").glob("recovery_test_recovery_*_steps.zip"))
            self.assertEqual(len(recovery), 1)
            model = train.load_sb3_checkpoint(str(recovery[0]), None)
            self.assertEqual(model.training_environment_state["workers"][0]["curriculum"]["curriculum_stage"], 5)


if __name__ == "__main__":
    unittest.main()
