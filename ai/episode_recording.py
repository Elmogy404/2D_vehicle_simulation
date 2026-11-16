"""Versioned episode recording, loading, and deterministic comparison.

The on-disk format is JSON Lines:

* one ``header`` record describing the environment and seed,
* one ``reset`` record with the initial observation and conditions,
* one ``step`` record per action, and
* one ``summary`` record when the recorder is closed.

Every record carries the format version so old recordings can be rejected with
a useful message instead of being silently misinterpreted.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import sys
from typing import Any, Iterable

import numpy as np

from deterministic_seeds import runtime_metadata
from interface_schema import metadata as interface_metadata
from reward_config import (
    SCHEMA_VERSION as REWARD_SCHEMA_VERSION,
    reward_config_hash,
    validate_reward_config,
)


RECORDING_FORMAT_VERSION = 1
DEFAULT_ATOL = 1e-6
DEFAULT_RTOL = 1e-6
RECORD_TYPES = ("header", "reset", "step", "summary")
VOLATILE_INFO_KEYS = frozenset({"reset_ms", "godot_pid", "episode_reset_ms"})
ESSENTIAL_INFO_KEYS = (
    "seed",
    "requested_seed",
    "master_seed",
    "worker_index",
    "map_attempts",
    "map_seed",
    "start_progress",
    "goal_progress",
    "goal_distance",
    "curriculum_stage",
    "route_turns",
    "turn_requirement_met",
    "success",
    "crashed",
    "off_road",
    "off_road_and_collision",
    "collision",
    "collision_count",
    "terminal_collision",
    "drivable",
    "progress",
    "progress_fraction",
    "episode_steps",
    "physics_ticks",
    "stalled",
    "speed_kmh",
    "speed_cap_kmh",
    "action_clipped",
    "interface_schema",
)


class RecordingError(ValueError):
    """A recording is missing, malformed, or internally inconsistent."""


class IncompatibleRecordingError(RecordingError):
    """A recording was made for an environment this replay cannot reproduce."""


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _jsonable(value: Any) -> Any:
    """Convert NumPy and nested values into strict JSON-compatible data."""
    if isinstance(value, np.ndarray):
        return value.tolist()
    if isinstance(value, np.generic):
        return value.item()
    if isinstance(value, Path):
        return str(value)
    if isinstance(value, dict):
        return {str(key): _jsonable(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_jsonable(item) for item in value]
    if isinstance(value, bool) or value is None or isinstance(value, str):
        return value
    if isinstance(value, (int, float)):
        number = float(value)
        if not math.isfinite(number):
            raise RecordingError("recording contains a non-finite numeric value")
        return value
    raise RecordingError(f"recording cannot serialise value of type {type(value).__name__}")


def _compact_info(info: dict[str, Any]) -> dict[str, Any]:
    return {key: _jsonable(info[key]) for key in ESSENTIAL_INFO_KEYS if key in info}


def _validate_observation(value: Any, *, step: str) -> np.ndarray:
    try:
        observation = np.asarray(value, dtype=np.float32)
    except (TypeError, ValueError) as error:
        raise RecordingError(f"{step}: observation is not numeric: {error}") from error
    metadata = interface_metadata()
    expected = (int(metadata["observation_size"]),)
    if observation.shape != expected:
        raise RecordingError(f"{step}: observation shape {observation.shape} != {expected}")
    if not np.all(np.isfinite(observation)):
        raise RecordingError(f"{step}: observation contains non-finite values")
    return observation


def _validate_action(value: Any, *, step: str) -> np.ndarray:
    try:
        action = np.asarray(value, dtype=np.float32)
    except (TypeError, ValueError) as error:
        raise RecordingError(f"{step}: action is not numeric: {error}") from error
    expected = (int(interface_metadata()["action_size"]),)
    if action.shape != expected:
        raise RecordingError(f"{step}: action shape {action.shape} != {expected}")
    if not np.all(np.isfinite(action)):
        raise RecordingError(f"{step}: action contains non-finite values")
    return action


def _require_int(value: Any, name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise RecordingError(f"{name} must be an integer")
    return value


def _require_flag(value: Any, name: str) -> bool:
    if not isinstance(value, bool):
        raise RecordingError(f"{name} must be true or false")
    return value


@dataclass
class EpisodeRecording:
    """In-memory representation of one recorded episode."""

    header: dict[str, Any]
    reset: dict[str, Any]
    steps: list[dict[str, Any]] = field(default_factory=list)
    summary: dict[str, Any] | None = None

    @property
    def format_version(self) -> int:
        return int(self.header["record_version"])

    @property
    def master_seed(self) -> int:
        return int(self.header["master_seed"])

    @property
    def episode_seed(self) -> int:
        return int(self.header["episode_seed"])

    @property
    def reset_options(self) -> dict[str, Any]:
        return dict(self.header.get("reset_options") or {})

    @property
    def initial_observation(self) -> np.ndarray:
        return _validate_observation(self.reset["observation"], step="reset")

    @property
    def actions(self) -> list[np.ndarray]:
        return [_validate_action(step["action"], step=f"step {step['index']}") for step in self.steps]

    def to_records(self) -> list[dict[str, Any]]:
        records = [self.header, self.reset, *self.steps]
        if self.summary is not None:
            records.append(self.summary)
        return records

    def write(self, path: str | Path) -> Path:
        destination = Path(path)
        destination.parent.mkdir(parents=True, exist_ok=True)
        temporary = destination.with_name(destination.name + f".{os.getpid()}.tmp")
        try:
            with temporary.open("w", encoding="utf-8", newline="\n") as file:
                for record in self.to_records():
                    file.write(json.dumps(_jsonable(record), separators=(",", ":"), allow_nan=False))
                    file.write("\n")
            os.replace(temporary, destination)
        finally:
            try:
                temporary.unlink(missing_ok=True)
            except OSError:
                pass
        return destination


class EpisodeRecorder:
    """Accumulate reset/step results and write one versioned recording."""

    def __init__(
        self,
        path: str | Path | None,
        *,
        environment_version: int,
        reward_config: dict[str, float],
        generator_type: str,
        interface_schema: dict[str, Any] | None = None,
        master_seed: int,
        capture_full_info: bool = False,
        runtime: dict[str, Any] | None = None,
    ) -> None:
        self.path = Path(path) if path is not None else None
        self.environment_version = int(environment_version)
        self.reward_config = validate_reward_config(
            reward_config,
            allow_partial=False,
            source="episode recording reward_config",
        )
        self.generator_type = str(generator_type)
        self.interface_schema = dict(interface_schema or interface_metadata())
        self.master_seed = _require_int(master_seed, "master_seed")
        self.capture_full_info = bool(capture_full_info)
        self.runtime = dict(runtime or runtime_metadata())
        self.header: dict[str, Any] | None = None
        self.reset: dict[str, Any] | None = None
        self.steps: list[dict[str, Any]] = []
        self.summary: dict[str, Any] | None = None
        self.episode_seed: int | None = None
        self.reset_options: dict[str, Any] = {}
        self.total_return = 0.0

    @property
    def recording(self) -> EpisodeRecording:
        if self.header is None or self.reset is None:
            raise RecordingError("no reset has been recorded yet")
        return EpisodeRecording(
            header=dict(self.header),
            reset=dict(self.reset),
            steps=[dict(step) for step in self.steps],
            summary=dict(self.summary) if self.summary is not None else None,
        )

    def _format_info(self, info: dict[str, Any]) -> dict[str, Any]:
        rendered = _jsonable(info)
        return rendered if self.capture_full_info else _compact_info(rendered)

    def record_reset(
        self,
        observation: Any,
        info: dict[str, Any],
        *,
        episode_seed: int | None = None,
        options: dict[str, Any] | None = None,
    ) -> None:
        if self.reset is not None:
            raise RecordingError("reset has already been recorded")
        seed = episode_seed
        if seed is None:
            seed = info.get("requested_seed", info.get("seed"))
        seed = _require_int(seed, "episode_seed")
        if seed < 0:
            raise RecordingError("episode_seed must be non-negative")
        observation = _validate_observation(observation, step="reset")
        formatted_info = self._format_info(info)
        initial_conditions = {
            key: formatted_info[key]
            for key in (
                "seed",
                "requested_seed",
                "start_progress",
                "goal_progress",
                "goal_distance",
                "curriculum_stage",
                "route_turns",
                "turn_requirement_met",
            )
            if key in formatted_info
        }
        self.episode_seed = seed
        self.reset_options = dict(options or {})
        self.header = {
            "type": "header",
            "record_version": RECORDING_FORMAT_VERSION,
            "created_at": _utc_now(),
            "environment_version": self.environment_version,
            "interface_schema": self.interface_schema,
            "reward_config": self.reward_config,
            "reward_config_schema_version": REWARD_SCHEMA_VERSION,
            "reward_config_hash": reward_config_hash(self.reward_config),
            "generator_type": self.generator_type,
            "master_seed": self.master_seed,
            "episode_seed": seed,
            "reset_options": _jsonable(self.reset_options),
            "initial_conditions": initial_conditions,
            "capture_full_info": self.capture_full_info,
            "runtime": self.runtime,
            "determinism_scope": "same-platform configuration and action replay",
        }
        self.reset = {
            "type": "reset",
            "observation": observation.tolist(),
            "info": formatted_info,
        }

    def record_step(
        self,
        *,
        index: int,
        action: Any,
        observation: Any,
        reward: float,
        terminated: bool,
        truncated: bool,
        info: dict[str, Any],
    ) -> None:
        if self.reset is None or self.header is None:
            raise RecordingError("record_reset must be called before record_step")
        if self.summary is not None:
            raise RecordingError("cannot record a step after the episode summary")
        expected_index = len(self.steps)
        if int(index) != expected_index:
            raise RecordingError(f"step index {index} does not follow {expected_index}")
        action_array = _validate_action(action, step=f"step {index}")
        observation_array = _validate_observation(observation, step=f"step {index}")
        reward_value = float(reward)
        if not math.isfinite(reward_value):
            raise RecordingError(f"step {index}: reward is not finite")
        self.steps.append(
            {
                "type": "step",
                "index": expected_index,
                "action": action_array.tolist(),
                "observation": observation_array.tolist(),
                "reward": reward_value,
                "terminated": _require_flag(terminated, f"step {index}.terminated"),
                "truncated": _require_flag(truncated, f"step {index}.truncated"),
                "info": self._format_info(info),
            }
        )
        self.total_return += reward_value

    def close(self, *, terminated: bool = False, truncated: bool = False) -> EpisodeRecording | None:
        if self.header is None or self.reset is None:
            return None
        if self.summary is None:
            self.summary = {
                "type": "summary",
                "record_version": RECORDING_FORMAT_VERSION,
                "steps": len(self.steps),
                "return": self.total_return,
                "terminated": bool(terminated),
                "truncated": bool(truncated),
                "complete": bool(terminated or truncated),
            }
        recording = self.recording
        if self.path is not None:
            recording.write(self.path)
        return recording

    def __enter__(self) -> "EpisodeRecorder":
        return self

    def __exit__(self, *_exc: object) -> None:
        self.close()


def _parse_record(line: str, line_number: int) -> dict[str, Any]:
    try:
        record = json.loads(line)
    except json.JSONDecodeError as error:
        raise RecordingError(f"line {line_number}: invalid JSON: {error}") from error
    if not isinstance(record, dict):
        raise RecordingError(f"line {line_number}: record must be a JSON object")
    return record


def load_recording(path: str | Path) -> EpisodeRecording:
    """Read and structurally validate a recording file."""
    source = Path(path)
    try:
        lines = [line for line in source.read_text(encoding="utf-8").splitlines() if line.strip()]
    except OSError as error:
        raise RecordingError(f"could not read recording {source}: {error}") from error
    if not lines:
        raise RecordingError(f"recording {source} is empty")
    records = [_parse_record(line, index + 1) for index, line in enumerate(lines)]
    header = records[0]
    if header.get("type") != "header":
        raise RecordingError("recording must start with a header record")
    version = header.get("record_version")
    if not isinstance(version, int) or version < 1:
        raise RecordingError("recording header has no valid record_version")
    if version > RECORDING_FORMAT_VERSION:
        raise IncompatibleRecordingError(
            f"recording format version {version} is newer than supported version {RECORDING_FORMAT_VERSION}"
        )
    if version != RECORDING_FORMAT_VERSION:
        raise IncompatibleRecordingError(
            f"recording format version {version} is unsupported; expected {RECORDING_FORMAT_VERSION}"
        )
    for key in ("environment_version", "interface_schema", "reward_config", "reward_config_hash", "generator_type"):
        if key not in header:
            raise RecordingError(f"recording header is missing {key}")
    _require_int(header.get("master_seed"), "header.master_seed")
    _require_int(header.get("episode_seed"), "header.episode_seed")
    reset = records[1] if len(records) > 1 else None
    if reset is None or reset.get("type") != "reset":
        raise RecordingError("recording must contain a reset record after its header")
    _validate_observation(reset.get("observation"), step="reset")
    if not isinstance(reset.get("info"), dict):
        raise RecordingError("reset.info must be an object")
    steps: list[dict[str, Any]] = []
    summary = None
    for record in records[2:]:
        if record.get("type") == "step":
            if summary is not None:
                raise RecordingError("step record appears after the summary")
            expected_index = len(steps)
            if _require_int(record.get("index"), "step.index") != expected_index:
                raise RecordingError(f"step index {record.get('index')} does not follow {expected_index}")
            _validate_action(record.get("action"), step=f"step {expected_index}")
            _validate_observation(record.get("observation"), step=f"step {expected_index}")
            reward = record.get("reward")
            if isinstance(reward, bool) or not isinstance(reward, (int, float)) or not math.isfinite(float(reward)):
                raise RecordingError(f"step {expected_index}: reward must be a finite number")
            _require_flag(record.get("terminated"), f"step {expected_index}.terminated")
            _require_flag(record.get("truncated"), f"step {expected_index}.truncated")
            if not isinstance(record.get("info"), dict):
                raise RecordingError(f"step {expected_index}.info must be an object")
            steps.append(record)
        elif record.get("type") == "summary":
            if summary is not None:
                raise RecordingError("recording contains more than one summary")
            summary = record
        else:
            raise RecordingError(f"unknown recording record type {record.get('type')!r}")
    if not isinstance(header.get("reward_config"), dict):
        raise RecordingError("header.reward_config must be an object")
    return EpisodeRecording(header=header, reset=reset, steps=steps, summary=summary)


def check_recording_compatibility(
    recording: EpisodeRecording,
    *,
    environment_version: int,
    reward_config: dict[str, float],
    generator_type: str,
    interface_schema: dict[str, Any] | None = None,
) -> None:
    """Reject a recording tied to a different environment contract."""
    if recording.format_version != RECORDING_FORMAT_VERSION:
        raise IncompatibleRecordingError(
            f"recording format {recording.format_version} is incompatible with {RECORDING_FORMAT_VERSION}"
        )
    recorded_environment = recording.header.get("environment_version")
    if recorded_environment != environment_version:
        raise IncompatibleRecordingError(
            f"recording environment version {recorded_environment} != current {environment_version}"
        )
    current_schema = dict(interface_schema or interface_metadata())
    if recording.header.get("interface_schema") != current_schema:
        raise IncompatibleRecordingError("recording interface schema differs from the current observation/action contract")
    if str(recording.header.get("generator_type")) != str(generator_type):
        raise IncompatibleRecordingError(
            f"recording generator {recording.header.get('generator_type')!r} != current {generator_type!r}"
        )
    try:
        recorded_reward = validate_reward_config(
            recording.header.get("reward_config"),
            allow_partial=False,
            source="recording reward_config",
        )
        current_reward = validate_reward_config(
            reward_config,
            allow_partial=False,
            source="current reward_config",
        )
    except ValueError as error:
        raise IncompatibleRecordingError(f"invalid reward configuration: {error}") from error
    recorded_hash = reward_config_hash(recorded_reward)
    if recording.header.get("reward_config_hash") != recorded_hash:
        raise IncompatibleRecordingError("recording reward_config_hash does not match its reward configuration")
    if recorded_hash != reward_config_hash(current_reward):
        raise IncompatibleRecordingError("recording reward configuration differs from the current environment")
    if recording.header.get("reward_config_schema_version") != REWARD_SCHEMA_VERSION:
        raise IncompatibleRecordingError("recording reward configuration schema version is unsupported")


def _format_scalar(value: Any) -> Any:
    if isinstance(value, float):
        if not math.isfinite(value):
            return str(value)
        return float(f"{value:.12g}")
    if isinstance(value, (str, bool, int)) or value is None:
        return value
    if isinstance(value, list):
        return [_format_scalar(item) for item in value]
    if isinstance(value, dict):
        return {key: _format_scalar(item) for key, item in value.items()}
    return repr(value)


def _compare_value(
    path: str,
    expected: Any,
    actual: Any,
    *,
    atol: float,
    rtol: float,
    differences: list[dict[str, Any]],
    exact: list[bool],
    max_numeric_error: list[float],
) -> None:
    if isinstance(expected, bool) or isinstance(actual, bool):
        if expected != actual:
            differences.append({"field": path, "reference": _format_scalar(expected), "replay": _format_scalar(actual)})
            exact.append(False)
        return
    if isinstance(expected, (int, float)) and isinstance(actual, (int, float)):
        expected_float, actual_float = float(expected), float(actual)
        if not math.isfinite(expected_float) or not math.isfinite(actual_float):
            if expected_float != actual_float:
                differences.append({"field": path, "reference": _format_scalar(expected), "replay": _format_scalar(actual)})
                exact.append(False)
            return
        error = abs(expected_float - actual_float)
        max_numeric_error[0] = max(max_numeric_error[0], error)
        if not math.isclose(expected_float, actual_float, rel_tol=rtol, abs_tol=atol):
            differences.append({"field": path, "reference": _format_scalar(expected), "replay": _format_scalar(actual)})
            exact.append(False)
        elif expected_float != actual_float:
            exact.append(False)
        return
    if isinstance(expected, dict) and isinstance(actual, dict):
        expected_keys, actual_keys = set(expected), set(actual)
        for key in sorted(expected_keys - actual_keys):
            differences.append({"field": f"{path}.{key}", "reference": _format_scalar(expected[key]), "replay": "<missing>"})
            exact.append(False)
        for key in sorted(actual_keys - expected_keys):
            differences.append({"field": f"{path}.{key}", "reference": "<missing>", "replay": _format_scalar(actual[key])})
            exact.append(False)
        for key in sorted(expected_keys & actual_keys):
            _compare_value(
                f"{path}.{key}", expected[key], actual[key],
                atol=atol, rtol=rtol, differences=differences, exact=exact,
                max_numeric_error=max_numeric_error,
            )
        return
    if isinstance(expected, (list, tuple)) and isinstance(actual, (list, tuple)):
        if len(expected) != len(actual):
            differences.append({"field": f"{path}.length", "reference": len(expected), "replay": len(actual)})
            exact.append(False)
        for index in range(min(len(expected), len(actual))):
            _compare_value(
                f"{path}[{index}]", expected[index], actual[index],
                atol=atol, rtol=rtol, differences=differences, exact=exact,
                max_numeric_error=max_numeric_error,
            )
        return
    if expected != actual:
        differences.append({"field": path, "reference": _format_scalar(expected), "replay": _format_scalar(actual)})
        exact.append(False)


def _compare_arrays(
    path: str,
    expected: Any,
    actual: Any,
    *,
    atol: float,
    rtol: float,
    differences: list[dict[str, Any]],
    exact: list[bool],
    max_numeric_error: list[float],
) -> None:
    expected_array = _validate_observation(expected, step=path)
    actual_array = _validate_observation(actual, step=path)
    error = np.abs(expected_array.astype(np.float64) - actual_array.astype(np.float64))
    max_numeric_error[0] = max(max_numeric_error[0], float(error.max(initial=0.0)))
    if not np.allclose(expected_array, actual_array, atol=atol, rtol=rtol, equal_nan=False):
        indexes = np.flatnonzero(~np.isclose(expected_array, actual_array, atol=atol, rtol=rtol, equal_nan=False))
        differences.append(
            {
                "field": path,
                "reference": [float(expected_array[index]) for index in indexes[:8]],
                "replay": [float(actual_array[index]) for index in indexes[:8]],
                "indices": [int(index) for index in indexes[:8]],
                "max_abs_error": float(error.max(initial=0.0)),
            }
        )
        exact.append(False)
    elif not np.array_equal(expected_array, actual_array):
        exact.append(False)


def compare_recordings(
    reference: EpisodeRecording,
    replay: EpisodeRecording,
    *,
    atol: float = DEFAULT_ATOL,
    rtol: float = DEFAULT_RTOL,
    compare_info: bool = True,
) -> dict[str, Any]:
    """Compare two recordings and return an exact/tolerance/divergence report."""
    if atol < 0 or rtol < 0:
        raise ValueError("comparison tolerances must be non-negative")
    differences: list[dict[str, Any]] = []
    exact_flags: list[bool] = []
    max_numeric_error = [0.0]
    _compare_arrays(
        "reset.observation", reference.reset.get("observation"), replay.reset.get("observation"),
        atol=atol, rtol=rtol, differences=differences, exact=exact_flags,
        max_numeric_error=max_numeric_error,
    )
    _compare_value(
        "reset.info",
        {
            key: value for key, value in (reference.reset.get("info") or {}).items()
            if key not in VOLATILE_INFO_KEYS
        },
        {
            key: value for key, value in (replay.reset.get("info") or {}).items()
            if key not in VOLATILE_INFO_KEYS
        },
        atol=atol, rtol=rtol, differences=differences, exact=exact_flags,
        max_numeric_error=max_numeric_error,
    )
    first_divergence: dict[str, Any] | None = None
    if differences:
        first_divergence = {"step": "reset", "fields": differences}
    max_step_error = [0.0]
    step_count = min(len(reference.steps), len(replay.steps))
    for index in range(step_count):
        expected_step, actual_step = reference.steps[index], replay.steps[index]
        step_differences: list[dict[str, Any]] = []
        step_exact: list[bool] = []
        step_error = [0.0]
        _compare_arrays(
            f"step[{index}].observation", expected_step.get("observation"), actual_step.get("observation"),
            atol=atol, rtol=rtol, differences=step_differences, exact=step_exact,
            max_numeric_error=step_error,
        )
        _compare_value(
            f"step[{index}].reward", expected_step.get("reward"), actual_step.get("reward"),
            atol=atol, rtol=rtol, differences=step_differences, exact=step_exact,
            max_numeric_error=step_error,
        )
        for flag in ("terminated", "truncated"):
            _compare_value(
                f"step[{index}].{flag}", expected_step.get(flag), actual_step.get(flag),
                atol=atol, rtol=rtol, differences=step_differences, exact=step_exact,
                max_numeric_error=step_error,
            )
        if compare_info:
            expected_info = {
                key: value for key, value in (expected_step.get("info") or {}).items()
                if key not in VOLATILE_INFO_KEYS
            }
            actual_info = {
                key: value for key, value in (actual_step.get("info") or {}).items()
                if key not in VOLATILE_INFO_KEYS
            }
            _compare_value(
                f"step[{index}].info", expected_info, actual_info,
                atol=atol, rtol=rtol, differences=step_differences, exact=step_exact,
                max_numeric_error=step_error,
            )
        max_step_error[0] = max(max_step_error[0], step_error[0])
        max_numeric_error[0] = max(max_numeric_error[0], step_error[0])
        exact_flags.extend(step_exact)
        if step_differences:
            differences.extend(step_differences)
            if first_divergence is None:
                first_divergence = {"step": index, "fields": step_differences}
            # Continue checking so the report remains useful, but preserve the
            # first step at which reproducibility broke.
    if len(reference.steps) != len(replay.steps):
        differences.append(
            {
                "field": "step_count",
                "reference": len(reference.steps),
                "replay": len(replay.steps),
            }
        )
        exact_flags.append(False)
        if first_divergence is None:
            first_divergence = {
                "step": step_count,
                "fields": [{
                    "field": "step_count",
                    "reference": len(reference.steps),
                    "replay": len(replay.steps),
                }],
            }
    if not differences:
        exact = all(exact_flags)
        status = "exact" if exact else "tolerance"
    else:
        exact = False
        status = "divergence"
    return {
        "status": status,
        "exact": exact,
        "steps_compared": step_count,
        "tolerances": {"atol": atol, "rtol": rtol},
        "max_abs_observation_error": max_numeric_error[0],
        "max_abs_step_error": max_step_error[0],
        "first_divergence": first_divergence,
        "divergences": differences,
        "divergence_count": len(differences),
    }


def replay_recording(
    env: Any,
    recording: EpisodeRecording,
    *,
    capture_full_info: bool | None = None,
) -> EpisodeRecording:
    """Reset ``env`` to the recorded seed and replay its action sequence."""
    check_recording_compatibility(
        recording,
        environment_version=int(env.environment_version),
        reward_config=env.reward_config,
        generator_type=env.generator_type,
    )
    full_info = (
        bool(recording.header.get("capture_full_info", False))
        if capture_full_info is None else bool(capture_full_info)
    )
    recorder = EpisodeRecorder(
        None,
        environment_version=int(env.environment_version),
        reward_config=env.reward_config,
        generator_type=env.generator_type,
        interface_schema=interface_metadata(),
        master_seed=recording.master_seed,
        capture_full_info=full_info,
        runtime=runtime_metadata(),
    )
    observation, info = env.reset(
        seed=recording.episode_seed,
        options=recording.reset_options,
    )
    recorder.record_reset(observation, info, episode_seed=recording.episode_seed, options=recording.reset_options)
    terminated = truncated = False
    for step in recording.steps:
        terminated = truncated = False
        observation, reward, terminated, truncated, info = env.step(np.asarray(step["action"], dtype=np.float32))
        recorder.record_step(
            index=int(step["index"]),
            action=step["action"],
            observation=observation,
            reward=reward,
            terminated=terminated,
            truncated=truncated,
            info=info,
        )
        if terminated or truncated:
            break
    recorder.close(terminated=terminated, truncated=truncated)
    return recorder.recording
