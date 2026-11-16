"""Dedicated tests for shared reward configuration validation and provenance."""

from __future__ import annotations

from contextlib import redirect_stdout
import io
import json
import math
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ai"))

from reward_config import (  # noqa: E402
    DEFAULTS,
    PARAMETER_ORDER,
    SCHEMA_VERSION,
    RewardConfigError,
    defaults,
    load_reward_config_file,
    parse_reward_config_text,
    reward_config_from_manifest,
    reward_config_hash,
    validate_reward_config,
)
from training_config import REWARD_DEFAULTS, prepare_manifest  # noqa: E402
from training_control import DEFAULT_REWARD_CONFIG, parse_reward_config  # noqa: E402


class ValidRewardConfigurationTests(unittest.TestCase):
    def test_existing_defaults_are_the_central_schema_defaults(self) -> None:
        self.assertEqual(PARAMETER_ORDER, tuple(DEFAULTS))
        self.assertEqual(REWARD_DEFAULTS, DEFAULTS)
        self.assertEqual(DEFAULT_REWARD_CONFIG, DEFAULTS)
        self.assertEqual(len(PARAMETER_ORDER), 10)
        self.assertEqual(SCHEMA_VERSION, 1)
        self.assertEqual(validate_reward_config(defaults()), DEFAULTS)

    def test_existing_project_manifests_remain_valid(self) -> None:
        manifests = sorted((ROOT / "ai" / "models").glob("*_training_config.json"))
        self.assertTrue(manifests, "expected at least one existing training manifest")
        for path in manifests:
            with self.subTest(manifest=path.name):
                manifest = json.loads(path.read_text(encoding="utf-8"))
                config = reward_config_from_manifest(manifest, source=path.name)
                self.assertEqual(tuple(config), PARAMETER_ORDER)
                self.assertEqual(config["max_speed_reward"], float(manifest["reward_config"]["max_speed_reward"]))

    def test_partial_override_and_explicit_zero_weights(self) -> None:
        partial = validate_reward_config({"goal_reward": 75}, allow_partial=True)
        self.assertEqual(partial["goal_reward"], 75.0)
        self.assertEqual(partial["crash_penalty"], DEFAULTS["crash_penalty"])

        zero = validate_reward_config({key: 0 for key in PARAMETER_ORDER})
        self.assertEqual(set(zero.values()), {0.0})
        self.assertEqual(parse_reward_config('{"goal_reward": 75}')["goal_reward"], 75.0)
        self.assertEqual(parse_reward_config(None), DEFAULTS)

    def test_signed_top_speed_reward_is_intentional(self) -> None:
        config = validate_reward_config({"max_speed_reward": -2.5}, allow_partial=True)
        self.assertEqual(config["max_speed_reward"], -2.5)
        self.assertEqual(parse_reward_config('{"max_speed_reward": -2.5}')["max_speed_reward"], -2.5)

    def test_version_metadata_and_nested_documents(self) -> None:
        nested = {
            "schema_version": SCHEMA_VERSION,
            "reward_config": dict(DEFAULTS, goal_reward=55.0),
        }
        self.assertEqual(validate_reward_config(nested)["goal_reward"], 55.0)
        flat_versioned = {"config_version": SCHEMA_VERSION, "goal_reward": 60.0}
        self.assertEqual(validate_reward_config(flat_versioned, allow_partial=True)["goal_reward"], 60.0)

    def test_file_loading_and_partial_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "rewards.json"
            path.write_text(json.dumps({"goal_reward": 12.5}), encoding="utf-8")
            self.assertEqual(load_reward_config_file(path, allow_partial=True)["goal_reward"], 12.5)
            with self.assertRaisesRegex(RewardConfigError, "required field"):
                load_reward_config_file(path)


class InvalidRewardConfigurationTests(unittest.TestCase):
    def assert_invalid(self, payload, pattern: str) -> None:
        with self.assertRaisesRegex(RewardConfigError, pattern):
            validate_reward_config(payload)

    def test_missing_and_empty_complete_configurations(self) -> None:
        self.assert_invalid({}, "empty")
        self.assert_invalid({"goal_reward": 40}, "progress_gain.*required")
        self.assert_invalid({"reward_config": {}}, "required")
        self.assertEqual(validate_reward_config({}, allow_partial=True), DEFAULTS)

    def test_unknown_fields_and_conflicting_structures(self) -> None:
        self.assert_invalid(dict(DEFAULTS, unknown_term=1.0), "unknown reward field")
        self.assert_invalid(
            {"reward_config": defaults(), "goal_reward": 2.0},
            "cannot be combined with a nested",
        )
        self.assert_invalid(
            {"reward_config": defaults(), "schema_version": 1, "config_version": 2},
            "unsupported configuration version|disagree",
        )

    def test_wrong_types_and_non_finite_values(self) -> None:
        for value, pattern in (
            (True, "must be a number"),
            ("high", "must be a number"),
            (None, "must be a number"),
            ([1], "must be a number"),
            (math.nan, "must be finite"),
            (math.inf, "must be finite"),
            (-math.inf, "must be finite"),
        ):
            with self.subTest(value=value):
                self.assert_invalid(dict(DEFAULTS, goal_reward=value), pattern)
        with self.assertRaisesRegex(RewardConfigError, "must be finite"):
            parse_reward_config_text('{"goal_reward": NaN}')

    def test_out_of_range_and_invalid_negative_values(self) -> None:
        self.assert_invalid(dict(DEFAULTS, goal_reward=1000.01), "outside the allowed range")
        self.assert_invalid(dict(DEFAULTS, progress_gain=1001), "outside the allowed range")
        self.assert_invalid(dict(DEFAULTS, goal_reward=-1), "must be non-negative")
        self.assert_invalid(dict(DEFAULTS, lane_penalty=-0.1), "must be non-negative")
        self.assert_invalid(dict(DEFAULTS, progress_gain=-0.1), "must be non-negative")
        self.assert_invalid(dict(DEFAULTS, max_speed_reward=-1000.01), "outside the allowed range")

    def test_unsupported_and_malformed_versions(self) -> None:
        self.assert_invalid({"reward_config": defaults(), "config_version": 2}, "unsupported configuration version")
        self.assert_invalid({"reward_config": defaults(), "schema_version": "1"}, "integer version")
        self.assert_invalid({"config_version": 1.5, "goal_reward": 1}, "integer version")

    def test_malformed_json_duplicate_keys_and_empty_text(self) -> None:
        for text, pattern in (
            ("{", "malformed JSON"),
            ("", "malformed JSON"),
            ("[]", "must be a JSON object"),
            ('{"goal_reward": 1, "goal_reward": 2}', "duplicate field"),
        ):
            with self.subTest(text=text):
                with self.assertRaisesRegex(RewardConfigError, pattern):
                    parse_reward_config_text(text)


class RewardProvenanceTests(unittest.TestCase):
    def test_hash_is_stable_order_independent_and_value_sensitive(self) -> None:
        reordered = {key: DEFAULTS[key] for key in reversed(PARAMETER_ORDER)}
        first = reward_config_hash(DEFAULTS)
        self.assertEqual(first, reward_config_hash(reordered))
        self.assertEqual(len(first), 64)
        changed = dict(DEFAULTS, goal_reward=41.0)
        self.assertNotEqual(first, reward_config_hash(changed))

    def test_manifest_records_and_verifies_effective_configuration(self) -> None:
        custom = dict(DEFAULTS, goal_reward=88.0, max_speed_reward=-0.5)
        manifest = {
            "reward_config": custom,
            "reward_config_schema_version": SCHEMA_VERSION,
            "reward_config_hash": reward_config_hash(custom),
        }
        self.assertEqual(reward_config_from_manifest(manifest), custom)
        with self.assertRaisesRegex(RewardConfigError, "hash does not match"):
            reward_config_from_manifest(dict(manifest, reward_config=dict(custom, goal_reward=89.0)))
        with self.assertRaisesRegex(RewardConfigError, "unsupported reward configuration schema version"):
            reward_config_from_manifest(dict(manifest, reward_config_schema_version=2))

    def test_legacy_manifest_without_hash_or_reward_block(self) -> None:
        with_hashless = {"reward_config": DEFAULTS}
        self.assertEqual(reward_config_from_manifest(with_hashless), DEFAULTS)
        output = io.StringIO()
        with redirect_stdout(output):
            self.assertEqual(reward_config_from_manifest({"workers": 1}, source="legacy"), DEFAULTS)
        self.assertIn("legacy", output.getvalue())
        self.assertIn("provenance cannot be verified", output.getvalue())

    def test_resume_accepts_identical_configuration_and_rejects_changes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "run_training_config.json"
            manifest = {
                "generator_type": "original",
                "workers": 1,
                "reward_config": DEFAULTS,
                "reward_config_schema_version": SCHEMA_VERSION,
                "reward_config_hash": reward_config_hash(DEFAULTS),
            }
            prepare_manifest(path, manifest, resume=False)
            prepare_manifest(path, manifest, resume=True)
            with self.assertRaisesRegex(ValueError, "reward configuration differs"):
                prepare_manifest(
                    path,
                    dict(manifest, reward_config=dict(DEFAULTS, goal_reward=99.0),
                         reward_config_hash=reward_config_hash(dict(DEFAULTS, goal_reward=99.0))),
                    resume=True,
                )

    def test_resume_rejects_tampered_hash_and_incomplete_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "run_training_config.json"
            manifest = {
                "generator_type": "original",
                "workers": 1,
                "reward_config": DEFAULTS,
                "reward_config_hash": reward_config_hash(DEFAULTS),
            }
            prepare_manifest(path, manifest, resume=False)
            previous = json.loads(path.read_text(encoding="utf-8"))
            previous["reward_config_hash"] = "0" * 64
            path.write_text(json.dumps(previous), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "does not match"):
                prepare_manifest(path, manifest, resume=True)

            path.write_text(
                json.dumps({"generator_type": "original", "workers": 1, "reward_config_hash": "0" * 64}),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "without a reward_config"):
                prepare_manifest(path, manifest, resume=True)


class RewardIntegrationTests(unittest.TestCase):
    def test_environment_rejects_invalid_overrides_before_starting_godot(self) -> None:
        from godot_gym_env import GodotRoadEnv

        with patch("godot_gym_env.GodotBridge") as bridge:
            with self.assertRaisesRegex(ValueError, "must be non-negative"):
                GodotRoadEnv(reward_config={"goal_reward": -1})
            bridge.assert_not_called()

    def test_training_and_evaluation_share_the_effective_configuration(self) -> None:
        custom = dict(DEFAULTS, goal_reward=77.0, crash_penalty=12.0)
        training_effective = parse_reward_config(json.dumps({"goal_reward": 77.0, "crash_penalty": 12.0}))
        manifest = {
            "reward_config": training_effective,
            "reward_config_schema_version": SCHEMA_VERSION,
            "reward_config_hash": reward_config_hash(training_effective),
        }
        evaluation_effective = reward_config_from_manifest(manifest)
        self.assertEqual(training_effective, evaluation_effective)
        self.assertEqual(training_effective, custom)

    def test_invalid_configuration_prevents_training_startup(self) -> None:
        with self.assertRaisesRegex(RewardConfigError, "must be non-negative"):
            parse_reward_config('{"crash_penalty": -5}')
        with self.assertRaisesRegex(RewardConfigError, "unknown reward field"):
            parse_reward_config('{"typo_penalty": 1}')
        result = subprocess.run(
            [sys.executable, str(ROOT / "ai/train.py"), "--steps", "1",
             "--reward-config", '{"goal_reward": -1}'],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=60,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("reward-config.goal_reward", result.stderr)
        self.assertIn("non-negative", result.stderr)

    def test_invalid_configuration_prevents_evaluation_startup(self) -> None:
        checkpoint = ROOT / "ai/models/checkpoints/setup2_gui_1794657337_67102_10240_steps.zip"
        manifest_source = ROOT / "ai/models/setup2_gui_1794657337_67102_training_config.json"
        if not checkpoint.is_file() or not manifest_source.is_file():
            self.skipTest("project checkpoint fixture is unavailable")
        with tempfile.TemporaryDirectory() as directory:
            manifest = json.loads(manifest_source.read_text(encoding="utf-8"))
            manifest["reward_config"] = dict(manifest["reward_config"], goal_reward=-1)
            manifest_path = Path(directory) / "invalid_training_config.json"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(ROOT / "ai/evaluate.py"), "--model", str(checkpoint),
                 "--manifest", str(manifest_path), "--episodes", "1"],
                cwd=ROOT,
                capture_output=True,
                text=True,
                timeout=120,
            )
        self.assertEqual(result.returncode, 2)
        self.assertIn("reward_config.goal_reward", result.stderr)
        self.assertIn("non-negative", result.stderr)


if __name__ == "__main__":
    unittest.main()
