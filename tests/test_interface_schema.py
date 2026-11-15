"""Dedicated tests for the shared observation/action interface schema."""

from __future__ import annotations

import math
from pathlib import Path
import sys
import tempfile
import unittest

import gymnasium as gym
import numpy as np
from gymnasium import spaces

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ai"))

from interface_schema import (  # noqa: E402
    ACTION_SIZE,
    OBSERVATION_FIELDS,
    OBSERVATION_SIZE,
    SCHEMA_VERSION,
    InterfaceValidationError,
    SchemaCompatibilityError,
    checkpoint_spaces_error,
    compatibility_error,
    manifest_interface_error,
    metadata,
    validate_action,
    validate_observation,
    validate_remote_metadata,
)
from policy_checkpoint import load_policy  # noqa: E402


def valid_observation() -> list[float]:
    observation = [0.0] * OBSERVATION_SIZE
    observation[-1] = 1.0
    return observation


class ObservationSchemaTests(unittest.TestCase):
    def test_schema_metadata_and_field_order(self) -> None:
        self.assertEqual(SCHEMA_VERSION, 1)
        self.assertEqual(OBSERVATION_SIZE, 31)
        self.assertEqual(ACTION_SIZE, 2)
        self.assertEqual(
            [field["name"] for field in OBSERVATION_FIELDS],
            [
                "ray_distances",
                "ego_speed",
                "steering_state",
                "heading_error",
                "lane_error",
                "goal_distance",
                "route_preview_points",
                "road_half_widths",
                "reserved_traffic_signals",
            ],
        )
        preview = next(field for field in OBSERVATION_FIELDS if field["name"] == "route_preview_points")
        self.assertEqual(preview["size"], 8)
        self.assertEqual(preview["count"], 4)
        self.assertEqual(preview["index"], 14)
        self.assertEqual(metadata()["observation_dtype"], "float32")

    def test_valid_observation_is_normalized_to_float32(self) -> None:
        observation = np.asarray(valid_observation(), dtype=np.float64)
        result = validate_observation(observation)
        self.assertEqual(result.dtype, np.float32)
        self.assertEqual(result.shape, (OBSERVATION_SIZE,))
        np.testing.assert_array_equal(result, np.asarray(valid_observation(), dtype=np.float32))

    def test_wrong_shapes_are_rejected(self) -> None:
        for value in (
            valid_observation()[:-1],
            valid_observation() + [0.0],
            np.zeros((1, OBSERVATION_SIZE), dtype=np.float32),
            np.zeros((OBSERVATION_SIZE, 1), dtype=np.float32),
        ):
            with self.assertRaisesRegex(InterfaceValidationError, "shape"):
                validate_observation(value)

    def test_non_numeric_observation_dtypes_are_rejected(self) -> None:
        for value in (
            [str(item) for item in valid_observation()],
            [bool(item) for item in valid_observation()],
            np.asarray(valid_observation(), dtype=complex),
            np.asarray(valid_observation(), dtype=object),
        ):
            with self.assertRaisesRegex(InterfaceValidationError, "dtype"):
                validate_observation(value)

    def test_non_finite_observation_values_are_rejected_with_location(self) -> None:
        for bad_value in (math.nan, math.inf, -math.inf):
            observation = valid_observation()
            observation[2] = bad_value
            with self.assertRaisesRegex(
                InterfaceValidationError,
                r"observation\[2\].*ray_distances.*finite",
            ):
                validate_observation(observation)

    def test_per_field_bounds_are_enforced(self) -> None:
        cases = (
            (0, -0.01, r"ray_distances.*outside"),
            (8, 1.01, r"ray_distances.*outside"),
            (9, 1.01, r"ego_speed.*outside"),
            (22, -0.01, r"road_half_widths.*outside"),
        )
        for index, value, message in cases:
            observation = valid_observation()
            observation[index] = value
            with self.assertRaisesRegex(InterfaceValidationError, message):
                validate_observation(observation)

    def test_reserved_signal_values_must_match_current_contract(self) -> None:
        observation = valid_observation()
        observation[30] = 0.0
        with self.assertRaisesRegex(
            InterfaceValidationError,
            r"reserved_traffic_signals.*reserved value 1\.0",
        ):
            validate_observation(observation)
        observation = valid_observation()
        observation[26] = 0.5
        with self.assertRaisesRegex(InterfaceValidationError, r"reserved value 0\.0"):
            validate_observation(observation)

    def test_reserved_validation_can_be_relaxed_for_diagnostics(self) -> None:
        observation = valid_observation()
        observation[30] = 0.0
        result = validate_observation(observation, strict_reserved=False)
        self.assertEqual(result[30], 0.0)


class ActionSchemaTests(unittest.TestCase):
    def test_valid_actions_are_float32(self) -> None:
        action, clipped = validate_action([0.25, -0.5])
        self.assertFalse(clipped)
        self.assertEqual(action.dtype, np.float32)
        np.testing.assert_array_equal(action, np.asarray([0.25, -0.5], dtype=np.float32))

    def test_out_of_range_actions_follow_documented_clipping(self) -> None:
        action, clipped = validate_action([-2.0, 3.0])
        self.assertTrue(clipped)
        np.testing.assert_array_equal(action, np.asarray([-1.0, 1.0], dtype=np.float32))
        with self.assertRaisesRegex(InterfaceValidationError, r"steering.*outside"):
            validate_action([-2.0, 3.0], clip=False)

    def test_malformed_action_shapes_are_rejected(self) -> None:
        for value in ([0.0], [0.0, 0.0, 0.0], [[0.0, 0.0]], 0.0, None):
            with self.assertRaises(InterfaceValidationError):
                validate_action(value)

    def test_non_finite_actions_are_rejected_never_clipped(self) -> None:
        for bad_value in (math.nan, math.inf, -math.inf):
            with self.assertRaisesRegex(InterfaceValidationError, r"action\[0\].*steering.*finite"):
                validate_action([bad_value, 0.0])

    def test_non_numeric_actions_are_rejected(self) -> None:
        for value in (( "left", 0.0), (True, 0.0), np.asarray([0.0, 0.0], dtype=complex)):
            with self.assertRaises(InterfaceValidationError):
                validate_action(value)

    def test_action_clipping_metadata_is_exposed(self) -> None:
        self.assertEqual(metadata()["action_size"], ACTION_SIZE)
        self.assertEqual(metadata()["schema_version"], SCHEMA_VERSION)


class ProtocolCompatibilityTests(unittest.TestCase):
    def test_compatible_metadata_passes(self) -> None:
        self.assertIsNone(compatibility_error(SCHEMA_VERSION, OBSERVATION_SIZE, ACTION_SIZE))
        validate_remote_metadata(metadata())

    def test_version_and_dimension_mismatches_are_explicit(self) -> None:
        self.assertIn("schema version", compatibility_error(SCHEMA_VERSION + 1, OBSERVATION_SIZE, ACTION_SIZE))
        self.assertIn("observation", compatibility_error(SCHEMA_VERSION, OBSERVATION_SIZE - 1, ACTION_SIZE))
        self.assertIn("action", compatibility_error(SCHEMA_VERSION, OBSERVATION_SIZE, ACTION_SIZE + 1))
        with self.assertRaisesRegex(SchemaCompatibilityError, "did not provide"):
            validate_remote_metadata(None)
        with self.assertRaisesRegex(SchemaCompatibilityError, "schema version"):
            validate_remote_metadata(dict(metadata(), schema_version=SCHEMA_VERSION + 1))
        with self.assertRaisesRegex(SchemaCompatibilityError, "observation dtype"):
            validate_remote_metadata(dict(metadata(), observation_dtype="float64"))

    def test_manifest_metadata_is_optional_for_legacy_checkpoints(self) -> None:
        self.assertIsNone(manifest_interface_error({}))
        self.assertIsNone(manifest_interface_error({"interface_schema": metadata()}))
        self.assertIn("schema version", manifest_interface_error(
            {"interface_schema": dict(metadata(), schema_version=SCHEMA_VERSION + 1)}
        ))

    def test_checkpoint_space_validation(self) -> None:
        correct_observation = spaces.Box(-1.0, 1.0, shape=(OBSERVATION_SIZE,), dtype=np.float32)
        correct_action = spaces.Box(-1.0, 1.0, shape=(ACTION_SIZE,), dtype=np.float32)
        self.assertIsNone(checkpoint_spaces_error(correct_observation, correct_action))
        wrong_observation = spaces.Box(-1.0, 1.0, shape=(OBSERVATION_SIZE - 1,), dtype=np.float32)
        self.assertIn("observation shape", checkpoint_spaces_error(wrong_observation, correct_action))
        wrong_action = spaces.Box(-1.0, 1.0, shape=(ACTION_SIZE + 1,), dtype=np.float32)
        self.assertIn("action shape", checkpoint_spaces_error(correct_observation, wrong_action))
        float64_observation = spaces.Box(-1.0, 1.0, shape=(OBSERVATION_SIZE,), dtype=np.float64)
        self.assertIn("observation dtype", checkpoint_spaces_error(float64_observation, correct_action))


class LegacyCheckpointTests(unittest.TestCase):
    def test_existing_legacy_checkpoint_remains_loadable(self) -> None:
        path = ROOT / "ai/models/setup2_gui_1792691773_54707_best.zip"
        if not path.is_file():
            self.skipTest("legacy checkpoint is not present in this checkout")
        model = load_policy(path)
        self.assertIsNone(checkpoint_spaces_error(model.observation_space, model.action_space))

    def test_incompatible_saved_checkpoint_fails_before_training_or_evaluation(self) -> None:
        from stable_baselines3 import PPO

        class WrongEnvironment(gym.Env):
            observation_space = spaces.Box(-1.0, 1.0, shape=(OBSERVATION_SIZE - 1,), dtype=np.float32)
            action_space = spaces.Box(-1.0, 1.0, shape=(ACTION_SIZE,), dtype=np.float32)

            def reset(self, *, seed=None, options=None):
                super().reset(seed=seed)
                return np.zeros(OBSERVATION_SIZE - 1, dtype=np.float32), {}

            def step(self, action):
                return np.zeros(OBSERVATION_SIZE - 1, dtype=np.float32), 0.0, True, False, {}

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "wrong_interface.zip"
            PPO("MlpPolicy", WrongEnvironment()).save(path)
            with self.assertRaisesRegex(SchemaCompatibilityError, "observation shape"):
                load_policy(path)


if __name__ == "__main__":
    unittest.main()
