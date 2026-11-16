"""Deterministic seeds, recording serialization, and replay comparison tests."""
from __future__ import annotations

from copy import deepcopy
import json
from pathlib import Path
import random
import sys
import tempfile
import unittest
from unittest.mock import patch

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "ai"))

from deterministic_seeds import (
    SEED_DERIVATION_NAME,
    derive_seed,
    environment_seed,
    seed_plan,
    set_global_seeds,
)
from episode_recording import (
    EpisodeRecorder,
    IncompatibleRecordingError,
    RecordingError,
    check_recording_compatibility,
    compare_recordings,
    load_recording,
    replay_recording,
)
from godot_gym_env import ENVIRONMENT_VERSION, GodotRoadEnv
from interface_schema import metadata as interface_metadata
from reward_config import defaults as reward_defaults


OBSERVATION = [0.0] * 31
OBSERVATION[-1] = 1.0
ACTION = [0.0, 0.35]


def reset_info(seed: int = 101) -> dict:
    return {
        "seed": seed,
        "requested_seed": seed,
        "map_attempts": 1,
        "start_progress": 10.0,
        "goal_progress": 510.0,
        "goal_distance": 500.0,
        "curriculum_stage": 0,
        "route_turns": 0,
        "turn_requirement_met": True,
        "reset_ms": 12.5,
        "godot_pid": 1234,
    }


def make_recording(
    path: Path | None = None,
    *,
    seed: int = 101,
    observation: list[float] | None = None,
    reward: float = 1.0,
    full_info: bool = False,
):
    recorder = EpisodeRecorder(
        path,
        environment_version=ENVIRONMENT_VERSION,
        reward_config=reward_defaults(),
        generator_type="original",
        master_seed=7,
        capture_full_info=full_info,
    )
    observation = list(observation or OBSERVATION)
    recorder.record_reset(
        observation,
        reset_info(seed),
        episode_seed=seed,
        options={"curriculum": False, "curriculum_stage": 0},
    )
    recorder.record_step(
        index=0,
        action=ACTION,
        observation=observation,
        reward=reward,
        terminated=True,
        truncated=False,
        info={
            "success": True,
            "crashed": False,
            "off_road": False,
            "collision_count": 0,
            "collision": {"collision_count": 0, "last_collision": {}},
            "episode_steps": 1,
            "reset_ms": 99.0,
            "godot_pid": 5678,
        },
    )
    return recorder.close(terminated=True)


class SeedTests(unittest.TestCase):
    def test_component_and_worker_seeds_are_stable_and_distinct(self) -> None:
        first = seed_plan(7, workers=3, evaluation_seed=10000)
        second = seed_plan(7, workers=3, evaluation_seed=10000)
        self.assertEqual(first, second)
        self.assertEqual(first["derivation"], SEED_DERIVATION_NAME)
        self.assertEqual(len({entry["worker_seed"] for entry in first["workers"]}), 3)
        for component in first["components"]:
            self.assertGreaterEqual(first["components"][component], 1)
            self.assertLess(first["components"][component], 2**31)
        self.assertNotEqual(derive_seed(7, "map", 0), derive_seed(7, "map", 1))
        self.assertNotEqual(environment_seed(7, 0), environment_seed(7, 1))
        with self.assertRaises(ValueError):
            derive_seed(-1, "map")

    def test_global_generators_are_reproducible(self) -> None:
        first = set_global_seeds(123, include_torch=False)
        first_values = (random.random(), float(np.random.random()))
        second = set_global_seeds(123, include_torch=False)
        second_values = (random.random(), float(np.random.random()))
        self.assertEqual(first, second)
        self.assertEqual(first_values, second_values)
        self.assertIn("python", first)
        self.assertIn("numpy", first)


class EnvironmentSeedTests(unittest.TestCase):
    def make_env(self, **kwargs) -> GodotRoadEnv:
        with patch("godot_gym_env.GodotBridge"):
            return GodotRoadEnv(**kwargs)

    def test_master_seed_gives_worker_a_reproducible_independent_stream(self) -> None:
        expected = np.random.default_rng(environment_seed(7, 2)).integers(1, 2**31 - 1, size=2)
        first = self.make_env(master_seed=7, worker_index=2)
        first.bridge.request.return_value = {
            "observation": OBSERVATION,
            "info": {"seed": 10, "interface_schema": interface_metadata()},
        }
        observed = []
        for _ in range(2):
            _observation, info = first.reset()
            observed.append(info["requested_seed"])
            self.assertEqual(info["master_seed"], 7)
            self.assertEqual(info["worker_index"], 2)
            self.assertEqual(info["seed_derivation"], SEED_DERIVATION_NAME)
        self.assertEqual(observed, [int(value) for value in expected])

        second = self.make_env(master_seed=7, worker_index=2)
        second.bridge.request.return_value = {
            "observation": OBSERVATION,
            "info": {"seed": 10, "interface_schema": interface_metadata()},
        }
        self.assertEqual(second.reset()[1]["requested_seed"], observed[0])

        other_worker = self.make_env(master_seed=7, worker_index=3)
        other_worker.bridge.request.return_value = {
            "observation": OBSERVATION,
            "info": {"seed": 10, "interface_schema": interface_metadata()},
        }
        self.assertNotEqual(other_worker.reset()[1]["requested_seed"], observed[0])

    def test_explicit_evaluation_seed_is_not_rewritten(self) -> None:
        env = self.make_env(master_seed=7, worker_index=2)
        env.bridge.request.return_value = {
            "observation": OBSERVATION,
            "info": {"seed": 10, "interface_schema": interface_metadata()},
        }
        _observation, info = env.reset(seed=98765)
        self.assertEqual(info["requested_seed"], 98765)
        self.assertEqual(env.bridge.request.call_args.args[0]["seed"], 98765)


class RecordingTests(unittest.TestCase):
    def test_jsonl_round_trip_and_compact_info(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "episode.jsonl"
            recording = make_recording(path)
            loaded = load_recording(path)
            self.assertEqual(loaded.header["record_version"], 1)
            self.assertEqual(loaded.header["master_seed"], 7)
            self.assertEqual(loaded.episode_seed, 101)
            self.assertEqual(len(loaded.steps), 1)
            self.assertEqual(loaded.initial_observation.tolist(), OBSERVATION)
            self.assertEqual(loaded.summary["complete"], True)
            self.assertNotIn("reset_ms", loaded.reset["info"])
            self.assertNotIn("godot_pid", loaded.steps[0]["info"])
            self.assertEqual(recording.header["reward_config"], reward_defaults())

    def test_full_info_recording_keeps_volatile_fields(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "full.jsonl"
            make_recording(path, full_info=True)
            loaded = load_recording(path)
            self.assertEqual(loaded.reset["info"]["reset_ms"], 12.5)
            self.assertEqual(loaded.steps[0]["info"]["godot_pid"], 5678)

    def test_invalid_recording_is_reported(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.jsonl"
            path.write_text('{"type":"header","record_version":1}\n', encoding="utf-8")
            with self.assertRaisesRegex(RecordingError, "missing|reset"):
                load_recording(path)
            path.write_text("not json\n", encoding="utf-8")
            with self.assertRaisesRegex(RecordingError, "invalid JSON"):
                load_recording(path)

    def test_newer_recording_version_is_incompatible(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "newer.jsonl"
            make_recording(path)
            records = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]
            records[0]["record_version"] = 99
            path.write_text("\n".join(json.dumps(record) for record in records) + "\n", encoding="utf-8")
            with self.assertRaisesRegex(IncompatibleRecordingError, "newer"):
                load_recording(path)


class ReplayTests(unittest.TestCase):
    def test_exact_and_tolerance_matches(self) -> None:
        reference = make_recording()
        exact = compare_recordings(reference, make_recording())
        self.assertEqual(exact["status"], "exact")
        self.assertIsNone(exact["first_divergence"])

        tolerance = make_recording(observation=[0.0] * 30 + [1.000001])
        within = compare_recordings(reference, tolerance, atol=1e-5, rtol=0.0)
        self.assertEqual(within["status"], "tolerance")
        outside = compare_recordings(reference, tolerance, atol=1e-9, rtol=0.0)
        self.assertEqual(outside["status"], "divergence")
        self.assertEqual(outside["first_divergence"]["step"], "reset")

    def test_divergence_identifies_first_step_and_fields(self) -> None:
        reference = make_recording()
        changed = make_recording(reward=2.0)
        report = compare_recordings(reference, changed)
        self.assertEqual(report["status"], "divergence")
        self.assertEqual(report["first_divergence"]["step"], 0)
        fields = {field["field"] for field in report["first_divergence"]["fields"]}
        self.assertIn("step[0].reward", fields)
        self.assertTrue(report["divergences"])

    def test_step_count_mismatch_is_a_divergence(self) -> None:
        reference = make_recording()
        shorter = make_recording()
        shorter.steps = []
        report = compare_recordings(reference, shorter)
        self.assertEqual(report["status"], "divergence")
        self.assertEqual(report["first_divergence"]["step"], 0)
        self.assertEqual(report["first_divergence"]["fields"][0]["field"], "step_count")

    def test_compatibility_rejects_environment_reward_and_generator_changes(self) -> None:
        recording = make_recording()
        check_recording_compatibility(
            recording,
            environment_version=ENVIRONMENT_VERSION,
            reward_config=reward_defaults(),
            generator_type="original",
        )
        with self.assertRaisesRegex(IncompatibleRecordingError, "environment version"):
            check_recording_compatibility(
                recording,
                environment_version=ENVIRONMENT_VERSION + 1,
                reward_config=reward_defaults(),
                generator_type="original",
            )
        with self.assertRaisesRegex(IncompatibleRecordingError, "generator"):
            check_recording_compatibility(
                recording,
                environment_version=ENVIRONMENT_VERSION,
                reward_config=reward_defaults(),
                generator_type="segmented",
            )
        changed_reward = reward_defaults()
        changed_reward["goal_reward"] += 1.0
        with self.assertRaisesRegex(IncompatibleRecordingError, "reward configuration"):
            check_recording_compatibility(
                recording,
                environment_version=ENVIRONMENT_VERSION,
                reward_config=changed_reward,
                generator_type="original",
            )

    def test_incompatible_replay_writes_a_status_report(self) -> None:
        from replay_episode import main as replay_main
        with tempfile.TemporaryDirectory() as directory:
            recording_path = Path(directory) / "episode.jsonl"
            report_path = Path(directory) / "report.json"
            make_recording(recording_path)
            records = [json.loads(line) for line in recording_path.read_text(encoding="utf-8").splitlines()]
            records[0]["environment_version"] = ENVIRONMENT_VERSION + 1
            recording_path.write_text(
                "\n".join(json.dumps(record) for record in records) + "\n",
                encoding="utf-8",
            )
            with patch.object(sys, "argv", [
                "replay_episode.py", "--recording", str(recording_path), "--json", str(report_path),
            ]):
                with self.assertRaises(SystemExit) as raised:
                    replay_main()
            self.assertEqual(raised.exception.code, 2)
            report = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertEqual(report["status"], "incompatible")
            self.assertIn("environment version", report["error"])

    def test_replay_recording_reconstructs_actions(self) -> None:
        class FakeEnv:
            environment_version = ENVIRONMENT_VERSION
            reward_config = reward_defaults()
            generator_type = "original"

            def __init__(self):
                self.reset_calls = []
                self.actions = []

            def reset(self, *, seed=None, options=None):
                self.reset_calls.append((seed, deepcopy(options)))
                return np.asarray(OBSERVATION, dtype=np.float32), reset_info(seed)

            def step(self, action):
                self.actions.append(np.asarray(action).tolist())
                return np.asarray(OBSERVATION, dtype=np.float32), 1.0, True, False, {
                    "success": True,
                    "crashed": False,
                    "off_road": False,
                    "collision_count": 0,
                    "collision": {"collision_count": 0, "last_collision": {}},
                    "episode_steps": 1,
                    "reset_ms": 99.0,
                    "godot_pid": 5678,
                }

        reference = make_recording()
        env = FakeEnv()
        replayed = replay_recording(env, reference)
        self.assertEqual(env.reset_calls, [(101, {"curriculum": False, "curriculum_stage": 0})])
        self.assertTrue(np.allclose(env.actions, [ACTION]))
        self.assertEqual(compare_recordings(reference, replayed)["status"], "exact")


class ManifestSeedTests(unittest.TestCase):
    def test_resume_requires_same_seed_but_accepts_legacy_manifest(self) -> None:
        from training_config import prepare_manifest

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "run_training_config.json"
            base = {"seed": 7, "workers": 1, "generator_type": "original"}
            prepare_manifest(path, base, resume=False)
            prepare_manifest(path, base, resume=True)
            with self.assertRaisesRegex(ValueError, "seed"):
                prepare_manifest(path, dict(base, seed=8), resume=True)
            path.write_text('{"workers":1,"generator_type":"original"}', encoding="utf-8")
            prepare_manifest(path, dict(base, seed=8), resume=True)

    def test_pre_determinism_source_fingerprint_remains_resumable(self) -> None:
        from training_config import PRE_DETERMINISTIC_SOURCE_HASH, prepare_manifest

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "legacy_training_config.json"
            manifest = {
                "generator_type": "original",
                "workers": 1,
                "runtime": {"source_hash": PRE_DETERMINISTIC_SOURCE_HASH},
            }
            prepare_manifest(path, manifest, resume=False)
            with patch("builtins.print") as warning:
                prepare_manifest(
                    path,
                    dict(manifest, seed=7, runtime={"source_hash": "new-hash"}),
                    resume=True,
                )
            self.assertTrue(any("predates seed/replay" in str(call) for call in warning.call_args_list))


if __name__ == "__main__":
    unittest.main()
