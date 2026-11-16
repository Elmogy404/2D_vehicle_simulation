"""Checkpoint discovery, resolution, compatibility, and integration tests."""

from __future__ import annotations

import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest

import gymnasium as gym
import numpy as np
from gymnasium import spaces

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ai"))
sys.path.insert(0, str(ROOT / "tests"))

from interface_schema import (  # noqa: E402
    ACTION_SIZE,
    OBSERVATION_SIZE,
    SCHEMA_VERSION,
    SchemaCompatibilityError,
    metadata as interface_metadata,
)
from policy_checkpoint import (  # noqa: E402
    CheckpointAmbiguityError,
    CheckpointNotFoundError,
    CheckpointValidationError,
    checkpoint_generator,
    inspect_checkpoint,
    load_policy,
    resolve_checkpoint,
)


class TinyEnvironment(gym.Env):
    def __init__(
        self,
        observation_size: int = OBSERVATION_SIZE,
        action_size: int = ACTION_SIZE,
        observation_dtype: np.dtype = np.float32,
        action_dtype: np.dtype = np.float32,
    ) -> None:
        self.observation_space = spaces.Box(
            -1.0, 1.0, shape=(observation_size,), dtype=observation_dtype
        )
        self.action_space = spaces.Box(
            -1.0, 1.0, shape=(action_size,), dtype=action_dtype
        )

    def reset(self, *, seed=None, options=None):
        super().reset(seed=seed)
        observation = np.zeros(self.observation_space.shape, dtype=self.observation_space.dtype)
        observation[-1] = 1.0
        return observation, {}

    def step(self, action):
        observation = np.zeros(self.observation_space.shape, dtype=self.observation_space.dtype)
        observation[-1] = 1.0
        return observation, 0.0, True, False, {}


def _save_ppo(
    path: Path,
    *,
    timesteps: int = 0,
    observation_size: int = OBSERVATION_SIZE,
    action_size: int = ACTION_SIZE,
    observation_dtype: np.dtype = np.float32,
) -> Path:
    from stable_baselines3 import PPO

    path.parent.mkdir(parents=True, exist_ok=True)
    env = TinyEnvironment(observation_size, action_size, observation_dtype)
    model = PPO(
        "MlpPolicy",
        env,
        n_steps=32,
        batch_size=16,
        n_epochs=1,
        verbose=0,
        device="cpu",
    )
    model.num_timesteps = timesteps
    model.save(path)
    return path.with_suffix(".zip")


def _save_a2c(path: Path) -> Path:
    from stable_baselines3 import A2C

    path.parent.mkdir(parents=True, exist_ok=True)
    A2C("MlpPolicy", TinyEnvironment(), n_steps=16, verbose=0, device="cpu").save(path)
    return path.with_suffix(".zip")


def _manifest_folder(checkpoint: Path) -> Path:
    return checkpoint.parent.parent if checkpoint.parent.name == "checkpoints" else checkpoint.parent


def _write_manifest(checkpoint: Path, run_name: str, *, schema=None, generator="original") -> Path:
    payload = {"generator_type": generator}
    if schema is not None:
        payload["interface_schema"] = schema
    path = _manifest_folder(checkpoint) / (run_name + "_training_config.json")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload), encoding="utf-8")
    return path


def _write_score(checkpoint: Path, score: list[float]) -> Path:
    path = checkpoint.with_name(checkpoint.stem + "_score.json")
    path.write_text(json.dumps({"environment_version": 3, "score": score}), encoding="utf-8")
    return path


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def _wait_for_port(port: int, timeout: float = 20.0) -> None:
    """Wait for the server's own log line without consuming its single accept."""
    log_path = ROOT / "ai" / "runs" / "live_policy.log"
    needle = f"Listening on 127.0.0.1:{port}"
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if needle in log_path.read_text(encoding="utf-8"):
                return
        except OSError:
            pass
        time.sleep(0.05)
    raise AssertionError(f"live policy server did not listen on port {port}")


class _ModelFixtures(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls._cache = tempfile.TemporaryDirectory()
        cls.cache = Path(cls._cache.name)
        cls.valid = _save_ppo(cls.cache / "fixtures" / "valid_100_steps.zip", timesteps=100)
        cls.valid_best = _save_ppo(
            cls.cache / "fixtures" / "valid_run_best.zip", timesteps=50
        )
        cls.latest = _save_ppo(
            cls.cache / "fixtures" / "latest_1000_steps.zip", timesteps=1000
        )
        cls.observation_mismatch = _save_ppo(
            cls.cache / "fixtures" / "wrong_observation.zip",
            observation_size=OBSERVATION_SIZE - 1,
        )
        cls.action_mismatch = _save_ppo(
            cls.cache / "fixtures" / "wrong_action.zip",
            action_size=ACTION_SIZE + 1,
        )
        cls.not_ppo = _save_a2c(cls.cache / "fixtures" / "not_ppo.zip")

    @classmethod
    def tearDownClass(cls) -> None:
        cls._cache.cleanup()

    def copy(self, source: Path, destination: Path) -> Path:
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
        return destination

    def temp_models(self) -> tuple[tempfile.TemporaryDirectory, Path]:
        directory = tempfile.TemporaryDirectory()
        return directory, Path(directory.name) / "models"


class ResolutionTests(_ModelFixtures):
    def test_explicit_valid_checkpoint_is_selected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = self.copy(self.valid, Path(directory) / "models" / "explicit.zip")
            resolved = resolve_checkpoint(target, model_dir=Path(directory) / "models")
            self.assertEqual(resolved.path, target.resolve())
            self.assertEqual(resolved.source, "explicit")
            self.assertEqual(resolved.strategy, "explicit")
            self.assertEqual(resolved.num_timesteps, 100)

    def test_explicit_takes_priority_over_discovery(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            models = Path(directory) / "models"
            self.copy(self.valid_best, models / "run_best.zip")
            explicit = self.copy(self.valid, models / "periodic_100_steps.zip")
            resolved = resolve_checkpoint(explicit, model_dir=models)
            self.assertEqual(resolved.path, explicit.resolve())
            self.assertEqual(resolved.source, "explicit")

    def test_missing_explicit_checkpoint_fails_clearly(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            missing = Path(directory) / "missing.zip"
            with self.assertRaisesRegex(CheckpointNotFoundError, "does not exist") as caught:
                resolve_checkpoint(missing)
            self.assertIn(str(missing), str(caught.exception))

    def test_automatic_discovery_finds_valid_checkpoint(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            models = Path(directory) / "models"
            self.copy(self.valid_best, models / "run_best.zip")
            resolved = resolve_checkpoint(model_dir=models)
            self.assertEqual(resolved.path, (models / "run_best.zip").resolve())
            self.assertEqual(resolved.source, "discovered")
            self.assertEqual(resolved.strategy, "best")

    def test_temporary_incomplete_and_invalid_files_are_ignored(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            models = Path(directory) / "models"
            valid = self.copy(self.valid, models / "checkpoints" / "run_100_steps.zip")
            self.copy(self.valid_best, models / "run_recovery_900_steps.zip")
            self.copy(self.valid_best, models / ".hidden_best.zip")
            (models / "broken_best.zip").write_bytes(b"not a pytorch zip")
            (models / "broken_1000000_steps.zip").write_bytes(b"not a pytorch zip")
            (models / "unfinished_best.zip.tmp").write_bytes(b"partial")
            _write_manifest(valid, "run")
            resolved = resolve_checkpoint(model_dir=models, strategy="latest")
            self.assertEqual(resolved.path, valid.resolve())
            self.assertEqual(resolved.num_timesteps, 100)

    def test_selection_is_deterministic(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            models = Path(directory) / "models"
            self.copy(self.valid, models / "checkpoints" / "run_100_steps.zip")
            self.copy(self.latest, models / "checkpoints" / "run_1000_steps.zip")
            first = resolve_checkpoint(model_dir=models, strategy="latest")
            for _ in range(3):
                self.assertEqual(
                    resolve_checkpoint(model_dir=models, strategy="latest").path,
                    first.path,
                )
            self.assertEqual(first.path.name, "run_1000_steps.zip")

    def test_missing_checkpoint_directory_fails_clearly(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            missing = Path(directory) / "no-models"
            with self.assertRaisesRegex(CheckpointNotFoundError, "does not exist"):
                resolve_checkpoint(model_dir=missing)

    def test_empty_checkpoint_directory_fails_clearly(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            empty = Path(directory) / "models"
            empty.mkdir()
            with self.assertRaisesRegex(CheckpointNotFoundError, "No valid Stable-Baselines3 PPO"):
                resolve_checkpoint(model_dir=empty)

    def test_multiple_best_candidates_use_recorded_scores(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            models = Path(directory) / "models"
            lower = self.copy(self.valid_best, models / "run_a_best.zip")
            higher = self.copy(self.valid_best, models / "run_b_best.zip")
            _write_score(lower, [0.2, 0.1])
            _write_score(higher, [0.9, 0.4])
            resolved = resolve_checkpoint(model_dir=models)
            self.assertEqual(resolved.path, higher.resolve())
            self.assertEqual(resolved.strategy, "best")

    def test_ambiguous_best_candidates_without_scores_fail(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            models = Path(directory) / "models"
            first = self.copy(self.valid_best, models / "run_a_best.zip")
            second = self.copy(self.valid_best, models / "run_b_best.zip")
            with self.assertRaises(CheckpointAmbiguityError) as caught:
                resolve_checkpoint(model_dir=models)
            message = str(caught.exception)
            self.assertIn(str(first), message)
            self.assertIn(str(second), message)
            self.assertIn("--model", message)

    def test_latest_strategy_uses_completed_timesteps_and_stable_ties(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            models = Path(directory) / "models"
            older = self.copy(self.valid, models / "checkpoints" / "run_100_steps.zip")
            newer = self.copy(self.latest, models / "checkpoints" / "run_1000_steps.zip")
            resolved = resolve_checkpoint(model_dir=models, strategy="latest")
            self.assertEqual(resolved.path, newer.resolve())
            self.assertNotEqual(resolved.path, older.resolve())

            tied = self.copy(self.latest, models / "checkpoints" / "run_zzz_1000_steps.zip")
            decided = resolve_checkpoint(model_dir=models, strategy="latest")
            self.assertEqual(decided.path, max(newer, tied).resolve())

    def test_best_then_latest_falls_back_to_latest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            models = Path(directory) / "models"
            self.copy(self.latest, models / "checkpoints" / "run_1000_steps.zip")
            resolved = resolve_checkpoint(model_dir=models, strategy="best_then_latest")
            self.assertEqual(resolved.strategy, "latest")

    def test_configured_default_checkpoint_overrides_discovery(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            models = root / "models"
            configured = self.copy(self.valid, models / "configured_100_steps.zip")
            self.copy(self.valid_best, models / "run_best.zip")
            config = root / "checkpoint_config.json"
            config.write_text(json.dumps({
                "model_dir": str(models),
                "default_checkpoint": str(configured),
                "manifest": None,
                "strategy": "best_then_latest",
                "require_manifest": False,
            }))
            resolved = resolve_checkpoint(config_path=config)
            self.assertEqual(resolved.path, configured.resolve())
            self.assertEqual(resolved.source, "configured-default")

    def test_environment_override_is_explicit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            models = Path(directory) / "models"
            target = self.copy(self.valid, models / "chosen_100_steps.zip")
            self.copy(self.valid_best, models / "run_best.zip")
            previous = os.environ.get("AI_CHECKPOINT")
            try:
                os.environ["AI_CHECKPOINT"] = str(target)
                resolved = resolve_checkpoint(model_dir=models)
            finally:
                if previous is None:
                    os.environ.pop("AI_CHECKPOINT", None)
                else:
                    os.environ["AI_CHECKPOINT"] = previous
            self.assertEqual(resolved.path, target.resolve())
            self.assertEqual(resolved.source, "environment")

    def test_required_manifest_is_enforced_and_validated(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            models = Path(directory) / "models"
            checkpoint = self.copy(self.valid, models / "run_100_steps.zip")
            with self.assertRaisesRegex(CheckpointNotFoundError, "requires one"):
                resolve_checkpoint(model_dir=models, require_manifest=True)
            _write_manifest(checkpoint, "run", schema=interface_metadata())
            resolved = resolve_checkpoint(model_dir=models, require_manifest=True)
            self.assertEqual(resolved.manifest_path, (models / "run_training_config.json").resolve())

    def test_malformed_manifest_rejects_checkpoint(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            models = Path(directory) / "models"
            self.copy(self.valid, models / "run_100_steps.zip")
            (models / "run_training_config.json").write_text("{not json", encoding="utf-8")
            with self.assertRaisesRegex(CheckpointNotFoundError, "not valid JSON"):
                resolve_checkpoint(model_dir=models)


class CompatibilityTests(_ModelFixtures):
    def test_valid_current_schema_checkpoint_loads(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            checkpoint = self.copy(self.valid, Path(directory) / "run_100_steps.zip")
            _write_manifest(checkpoint, "run", schema=interface_metadata())
            model = load_policy(checkpoint)
            self.assertEqual(model.num_timesteps, 100)
            self.assertEqual(model.observation_space.shape, (OBSERVATION_SIZE,))
            self.assertEqual(model.action_space.shape, (ACTION_SIZE,))

    def test_legacy_checkpoint_without_manifest_loads(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            checkpoint = self.copy(self.valid, Path(directory) / "legacy_100_steps.zip")
            model = load_policy(checkpoint)
            self.assertEqual(model.observation_space.shape, (OBSERVATION_SIZE,))

    def test_legacy_manifest_without_schema_metadata_loads(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            checkpoint = self.copy(self.valid, Path(directory) / "legacy_100_steps.zip")
            _write_manifest(checkpoint, "legacy", schema=None)
            model = load_policy(checkpoint)
            self.assertEqual(model.action_space.shape, (ACTION_SIZE,))

    def test_observation_space_mismatch_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            checkpoint = self.copy(
                self.observation_mismatch, Path(directory) / "wrong_observation.zip"
            )
            with self.assertRaisesRegex(SchemaCompatibilityError, "observation shape"):
                load_policy(checkpoint)

    def test_action_space_mismatch_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            checkpoint = self.copy(
                self.action_mismatch, Path(directory) / "wrong_action.zip"
            )
            with self.assertRaisesRegex(SchemaCompatibilityError, "action shape"):
                load_policy(checkpoint)

    def test_schema_version_mismatch_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            checkpoint = self.copy(self.valid, Path(directory) / "run_100_steps.zip")
            _write_manifest(
                checkpoint,
                "run",
                schema=dict(interface_metadata(), schema_version=SCHEMA_VERSION + 1),
            )
            with self.assertRaisesRegex(SchemaCompatibilityError, "schema version"):
                load_policy(checkpoint)

    def test_corrupted_checkpoint_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            checkpoint = Path(directory) / "corrupt.zip"
            checkpoint.write_bytes(b"this is not a checkpoint")
            with self.assertRaisesRegex(CheckpointValidationError, "unreadable or corrupted"):
                load_policy(checkpoint)

    def test_unsupported_algorithm_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            checkpoint = self.copy(self.not_ppo, Path(directory) / "not_ppo.zip")
            with self.assertRaisesRegex(CheckpointValidationError, "not a Stable-Baselines3 PPO"):
                load_policy(checkpoint)

    def test_generator_type_comes_from_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            checkpoint = self.copy(self.valid, Path(directory) / "run_100_steps.zip")
            _write_manifest(checkpoint, "run", generator="segmented")
            self.assertEqual(checkpoint_generator(checkpoint), "segmented")
            with self.assertRaisesRegex(ValueError, "trained on segmented roads"):
                checkpoint_generator(checkpoint, "original")

    def test_inspection_reports_selected_path_and_reason(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            checkpoint = self.copy(self.action_mismatch, Path(directory) / "wrong_action.zip")
            with self.assertRaisesRegex(SchemaCompatibilityError, "wrong_action.zip.*action shape"):
                inspect_checkpoint(checkpoint)


class EvaluationIntegrationTests(_ModelFixtures):
    def test_evaluation_loads_requested_checkpoint(self) -> None:
        import evaluate as evaluate_module

        class FakeEnvironment:
            def __init__(self, *args, **kwargs):
                self.generator_type = kwargs.get("generator_type", "original")

            def reset(self, *, seed=None, options=None):
                observation = np.zeros(OBSERVATION_SIZE, dtype=np.float32)
                observation[-1] = 1.0
                return observation, {}

            def step(self, action):
                observation = np.zeros(OBSERVATION_SIZE, dtype=np.float32)
                observation[-1] = 1.0
                return observation, 1.0, True, False, {
                    "success": True,
                    "crashed": False,
                    "off_road": False,
                    "route_turns": 0,
                    "turn_requirement_met": True,
                }

            def close(self):
                pass

        with tempfile.TemporaryDirectory() as directory:
            checkpoint = self.copy(self.valid, Path(directory) / "run_100_steps.zip")
            output = io.StringIO()
            argv = ["evaluate.py", "--model", str(checkpoint), "--episodes", "1"]
            import sys as runtime_sys
            from unittest.mock import patch

            with patch.object(runtime_sys, "argv", argv), \
                    patch.object(evaluate_module, "GodotRoadEnv", FakeEnvironment), \
                    contextlib.redirect_stdout(output):
                evaluate_module.main()
            text = output.getvalue()
            self.assertIn(f"Using checkpoint {checkpoint.resolve()}", text)
            self.assertIn("SUMMARY episodes=1", text)


class LivePolicyServerIntegrationTests(_ModelFixtures):
    def test_live_server_loads_requested_checkpoint_and_serves_action(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            checkpoint = self.copy(self.valid, Path(directory) / "run_100_steps.zip")
            port = _free_port()
            process = subprocess.Popen(
                [
                    sys.executable,
                    "-u",
                    str(ROOT / "ai" / "live_policy_server.py"),
                    "--model",
                    str(checkpoint),
                    "--port",
                    str(port),
                ],
                cwd=ROOT,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                text=True,
            )
            try:
                _wait_for_port(port)
                observation = [0.0] * OBSERVATION_SIZE
                observation[-1] = 1.0
                request = {
                    "type": "predict",
                    "request_id": 7,
                    "observation": observation,
                    "schema_version": SCHEMA_VERSION,
                    "observation_size": OBSERVATION_SIZE,
                    "action_size": ACTION_SIZE,
                    "observation_dtype": "float32",
                    "action_dtype": "float32",
                }
                with socket.create_connection(("127.0.0.1", port), timeout=10) as connection:
                    stream = connection.makefile("rwb")
                    stream.write((json.dumps(request) + "\n").encode("utf-8"))
                    stream.flush()
                    response = json.loads(stream.readline())
                    self.assertEqual(response["request_id"], 7)
                    self.assertNotIn("error", response)
                    self.assertEqual(len(response["action"]), ACTION_SIZE)
                    stream.write(b'{"type":"shutdown"}\n')
                    stream.flush()
                    self.assertTrue(json.loads(stream.readline())["closed"])
            finally:
                process.wait(timeout=20)

    def test_live_server_rejects_incompatible_checkpoint_before_serving(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            checkpoint = self.copy(
                self.observation_mismatch, Path(directory) / "wrong_observation.zip"
            )
            port = _free_port()
            process = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "ai" / "live_policy_server.py"),
                    "--model",
                    str(checkpoint),
                    "--port",
                    str(port),
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
                timeout=60,
            )
            self.assertEqual(process.returncode, 2)
            log = (ROOT / "ai" / "runs" / "live_policy.log").read_text(encoding="utf-8")
            self.assertIn(str(checkpoint), log)
            self.assertIn("observation", log)


class TrainingResumeIntegrationTests(_ModelFixtures):
    def test_resume_resolution_loads_validated_checkpoint(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            checkpoint = self.copy(self.valid, Path(directory) / "run_100_steps.zip")
            resolved = resolve_checkpoint(checkpoint)
            model = load_policy(resolved.path, manifest=resolved.manifest_path)
            self.assertEqual(model.num_timesteps, 100)
            self.assertEqual(resolved.source, "explicit")


if __name__ == "__main__":
    unittest.main()
