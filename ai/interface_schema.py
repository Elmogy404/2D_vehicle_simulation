"""Authoritative observation/action schema and boundary validation.

The JSON file next to this module is the single source of truth shared with the
Godot runtime. Python loads it at import time and exposes small validation
helpers; it deliberately keeps the existing 31-float observation and 2-float
action contracts unchanged.
"""

from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Any

import numpy as np


SCHEMA_PATH = Path(__file__).with_name("interface_schema.json")


class InterfaceValidationError(ValueError):
    """A malformed observation or action payload."""


class SchemaCompatibilityError(InterfaceValidationError):
    """Python and Godot, or a checkpoint, do not share a compatible schema."""


def _load_schema() -> dict[str, Any]:
    try:
        schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SchemaCompatibilityError(f"Cannot load interface schema {SCHEMA_PATH}: {error}") from error
    _validate_schema_structure(schema)
    return schema


def _validate_schema_structure(schema: dict[str, Any]) -> None:
    if not isinstance(schema, dict):
        raise SchemaCompatibilityError("Interface schema must be a JSON object")
    version = schema.get("schema_version")
    if not isinstance(version, int) or version < 1:
        raise SchemaCompatibilityError("Interface schema_version must be a positive integer")
    for section_name in ("observation", "action"):
        section = schema.get(section_name)
        if not isinstance(section, dict):
            raise SchemaCompatibilityError(f"Interface schema is missing {section_name}")
        size = section.get("size")
        fields = section.get("fields")
        if not isinstance(size, int) or size < 1 or not isinstance(fields, list):
            raise SchemaCompatibilityError(f"Interface {section_name} schema has an invalid size or fields")
        expected_index = 0
        for field in fields:
            if not isinstance(field, dict):
                raise SchemaCompatibilityError(f"Interface {section_name} field must be an object")
            name = field.get("name")
            index = field.get("index")
            field_size = field.get("size")
            if not isinstance(name, str) or not name:
                raise SchemaCompatibilityError(f"Interface {section_name} field is missing a name")
            if not isinstance(index, int) or index != expected_index:
                raise SchemaCompatibilityError(
                    f"Interface {section_name} field {name!r} must start at index {expected_index}"
                )
            if not isinstance(field_size, int) or field_size < 1:
                raise SchemaCompatibilityError(f"Interface {section_name} field {name!r} has an invalid size")
            if not isinstance(field.get("min"), (int, float)) or not isinstance(field.get("max"), (int, float)):
                raise SchemaCompatibilityError(f"Interface {section_name} field {name!r} has invalid bounds")
            if float(field["min"]) > float(field["max"]):
                raise SchemaCompatibilityError(f"Interface {section_name} field {name!r} has reversed bounds")
            if field.get("layout") == "xy":
                if int(field.get("count", -1)) * 2 != field_size:
                    raise SchemaCompatibilityError(
                        f"Interface {section_name} field {name!r} xy layout must have count * 2 values"
                    )
            if field.get("reserved"):
                expected = field.get("expected")
                if not isinstance(expected, list) or len(expected) != field_size:
                    raise SchemaCompatibilityError(
                        f"Interface {section_name} reserved field {name!r} must have one expected value per slot"
                    )
            expected_index += field_size
        if expected_index != size:
            raise SchemaCompatibilityError(
                f"Interface {section_name} fields cover {expected_index} values, expected {size}"
            )


SCHEMA = _load_schema()
SCHEMA_VERSION = int(SCHEMA["schema_version"])
OBSERVATION_SPEC = SCHEMA["observation"]
ACTION_SPEC = SCHEMA["action"]
OBSERVATION_SIZE = int(OBSERVATION_SPEC["size"])
ACTION_SIZE = int(ACTION_SPEC["size"])
OBSERVATION_DTYPE = np.dtype(OBSERVATION_SPEC.get("dtype", "float32"))
ACTION_DTYPE = np.dtype(ACTION_SPEC.get("dtype", "float32"))
OBSERVATION_FIELDS: tuple[dict[str, Any], ...] = tuple(OBSERVATION_SPEC["fields"])
ACTION_FIELDS: tuple[dict[str, Any], ...] = tuple(ACTION_SPEC["fields"])


def metadata() -> dict[str, Any]:
    """Schema metadata exchanged through the existing reset/info messages."""
    return {
        "schema_version": SCHEMA_VERSION,
        "observation_size": OBSERVATION_SIZE,
        "action_size": ACTION_SIZE,
        "observation_dtype": str(OBSERVATION_DTYPE),
        "action_dtype": str(ACTION_DTYPE),
    }


def observation_space_low() -> np.ndarray:
    return np.full(OBSERVATION_SIZE, float(OBSERVATION_SPEC["gym_min"]), dtype=np.float32)


def observation_space_high() -> np.ndarray:
    return np.full(OBSERVATION_SIZE, float(OBSERVATION_SPEC["gym_max"]), dtype=np.float32)


def action_space_low() -> np.ndarray:
    return np.asarray([field["min"] for field in ACTION_FIELDS], dtype=np.float32)


def action_space_high() -> np.ndarray:
    return np.asarray([field["max"] for field in ACTION_FIELDS], dtype=np.float32)


def compatibility_error(
    schema_version: int,
    observation_size: int,
    action_size: int,
    *,
    source: str = "remote environment",
    observation_dtype: str | None = None,
    action_dtype: str | None = None,
) -> str | None:
    """Return a human-readable mismatch, or None when the contract matches."""
    if schema_version != SCHEMA_VERSION:
        return (
            f"{source} uses interface schema version {schema_version}, "
            f"this process expects {SCHEMA_VERSION}"
        )
    if observation_size != OBSERVATION_SIZE:
        return (
            f"{source} uses {observation_size} observation values, "
            f"this process expects {OBSERVATION_SIZE} (schema v{SCHEMA_VERSION})"
        )
    if action_size != ACTION_SIZE:
        return (
            f"{source} uses {action_size} action values, "
            f"this process expects {ACTION_SIZE} (schema v{SCHEMA_VERSION})"
        )
    if observation_dtype is not None and str(observation_dtype) != str(OBSERVATION_DTYPE):
        return (
            f"{source} uses observation dtype {observation_dtype}, "
            f"this process expects {OBSERVATION_DTYPE} (schema v{SCHEMA_VERSION})"
        )
    if action_dtype is not None and str(action_dtype) != str(ACTION_DTYPE):
        return (
            f"{source} uses action dtype {action_dtype}, "
            f"this process expects {ACTION_DTYPE} (schema v{SCHEMA_VERSION})"
        )
    return None


def _metadata_int(value: Any) -> int:
    if isinstance(value, bool):
        return -1
    if isinstance(value, int):
        return value
    if isinstance(value, float) and value.is_integer():
        return int(value)
    return -1


def validate_remote_metadata(remote: Any, *, source: str = "Godot") -> dict[str, Any]:
    """Validate schema metadata from a reset/step response or live request."""
    if not isinstance(remote, dict):
        raise SchemaCompatibilityError(
            f"{source} did not provide interface schema metadata (expected schema v{SCHEMA_VERSION})"
        )
    error = compatibility_error(
        _metadata_int(remote.get("schema_version")),
        _metadata_int(remote.get("observation_size")),
        _metadata_int(remote.get("action_size")),
        source=source,
        observation_dtype=remote.get("observation_dtype"),
        action_dtype=remote.get("action_dtype"),
    )
    if error:
        raise SchemaCompatibilityError(error)
    return remote


def _field_for_index(index: int) -> dict[str, Any] | None:
    for field in OBSERVATION_FIELDS:
        start = int(field["index"])
        if start <= index < start + int(field["size"]):
            return field
    return None


def _field_text(field: dict[str, Any], index: int) -> str:
    field_index = index - int(field["index"])
    if int(field["size"]) == 1:
        return f"observation[{index}] ('{field['name']}')"
    return f"observation[{index}] ('{field['name']}'[{field_index}])"


def _numeric_array(value: Any, *, name: str, expected_size: int) -> np.ndarray:
    if isinstance(value, (list, tuple)) and any(isinstance(item, (bool, np.bool_)) for item in value):
        raise InterfaceValidationError(
            f"{name} contains a boolean dtype; expected float32-compatible numbers "
            f"(schema v{SCHEMA_VERSION})"
        )
    array = np.asarray(value)
    if array.dtype.kind not in "fiu":
        raise InterfaceValidationError(
            f"{name} dtype {array.dtype} is not a real numeric dtype; "
            f"expected float32-compatible numbers (schema v{SCHEMA_VERSION})"
        )
    expected_shape = (expected_size,)
    if array.shape != expected_shape:
        raise InterfaceValidationError(
            f"{name} shape {array.shape} is invalid; expected {expected_shape} "
            f"(schema v{SCHEMA_VERSION})"
        )
    return array


def validate_observation(
    observation: Any,
    *,
    strict_reserved: bool = True,
    cast: bool = True,
) -> np.ndarray:
    """Validate one observation, returning a float32 array.

    Numeric integer/float payloads are accepted and normalized to float32
    according to the declared contract. Non-numeric, non-finite, malformed,
    out-of-bounds, and reserved-field violations are rejected; values are never
    silently replaced or clipped.
    """
    array = _numeric_array(observation, name="observation", expected_size=OBSERVATION_SIZE)
    for index in range(OBSERVATION_SIZE):
        value = array[index]
        if not np.isfinite(value):
            field = _field_for_index(index)
            label = _field_text(field, index) if field else f"observation[{index}]"
            raise InterfaceValidationError(
                f"{label} = {value!r} must be finite (schema v{SCHEMA_VERSION})"
            )
    for field in OBSERVATION_FIELDS:
        start = int(field["index"])
        size = int(field["size"])
        low = float(field["min"])
        high = float(field["max"])
        for offset in range(size):
            index = start + offset
            value = float(array[index])
            if value < low or value > high:
                raise InterfaceValidationError(
                    f"{_field_text(field, index)} = {value!r} is outside "
                    f"[{low!r}, {high!r}] (schema v{SCHEMA_VERSION})"
                )
        if strict_reserved and field.get("reserved"):
            expected = field.get("expected")
            if isinstance(expected, list) and len(expected) == size:
                for offset, expected_value in enumerate(expected):
                    index = start + offset
                    value = float(array[index])
                    if not math.isclose(value, float(expected_value), rel_tol=0.0, abs_tol=1e-6):
                        raise InterfaceValidationError(
                            f"{_field_text(field, index)} = {value!r} does not match "
                            f"reserved value {float(expected_value)!r} (schema v{SCHEMA_VERSION})"
                        )
    return array.astype(OBSERVATION_DTYPE, copy=False) if cast else array


def validate_action(action: Any, *, clip: bool = True) -> tuple[np.ndarray, bool]:
    """Validate one action and apply the documented clipping policy.

    Returns ``(float32_action, was_clipped)``. Out-of-bounds finite values are
    clipped when ``clip`` is true (the existing PPO/environment behavior);
    with ``clip=False`` they are rejected. Non-finite values are always
    rejected, never clipped.
    """
    array = _numeric_array(action, name="action", expected_size=ACTION_SIZE)
    for field in ACTION_FIELDS:
        index = int(field["index"])
        value = float(array[index])
        if not np.isfinite(value):
            raise InterfaceValidationError(
                f"action[{index}] ('{field['name']}') = {value!r} must be finite "
                f"(schema v{SCHEMA_VERSION})"
            )
    clipped = False
    output = array.astype(np.float64, copy=True)
    for field in ACTION_FIELDS:
        index = int(field["index"])
        low = float(field["min"])
        high = float(field["max"])
        value = float(output[index])
        if value < low or value > high:
            if not clip:
                raise InterfaceValidationError(
                    f"action[{index}] ('{field['name']}') = {value!r} is outside "
                    f"[{low!r}, {high!r}] (schema v{SCHEMA_VERSION})"
                )
            output[index] = min(max(value, low), high)
            clipped = True
    return output.astype(ACTION_DTYPE, copy=False), clipped


def checkpoint_spaces_error(observation_space: Any, action_space: Any) -> str | None:
    """Return a checkpoint-space mismatch message, or None when compatible."""
    observation_shape = getattr(observation_space, "shape", None)
    action_shape = getattr(action_space, "shape", None)
    if observation_shape != (OBSERVATION_SIZE,):
        return (
            f"checkpoint observation shape {observation_shape} is incompatible with "
            f"the current interface: expected ({OBSERVATION_SIZE},) (schema v{SCHEMA_VERSION})"
        )
    if action_shape != (ACTION_SIZE,):
        return (
            f"checkpoint action shape {action_shape} is incompatible with "
            f"the current interface: expected ({ACTION_SIZE},) (schema v{SCHEMA_VERSION})"
        )
    observation_dtype = getattr(observation_space, "dtype", None)
    action_dtype = getattr(action_space, "dtype", None)
    if observation_dtype is not None and np.dtype(observation_dtype) != OBSERVATION_DTYPE:
        return (
            f"checkpoint observation dtype {observation_dtype} is incompatible; "
            f"expected {OBSERVATION_DTYPE} (schema v{SCHEMA_VERSION})"
        )
    if action_dtype is not None and np.dtype(action_dtype) != ACTION_DTYPE:
        return (
            f"checkpoint action dtype {action_dtype} is incompatible; "
            f"expected {ACTION_DTYPE} (schema v{SCHEMA_VERSION})"
        )
    return None


def manifest_interface_error(manifest: dict[str, Any]) -> str | None:
    """Check optional schema metadata stored in a training manifest."""
    recorded = manifest.get("interface_schema")
    if not recorded:
        # Legacy manifests predate this field. Their actual model spaces are
        # still checked by checkpoint_spaces_error before load/run.
        return None
    if not isinstance(recorded, dict):
        return "checkpoint manifest interface_schema must be an object"
    return compatibility_error(
        _metadata_int(recorded.get("schema_version")),
        _metadata_int(recorded.get("observation_size")),
        _metadata_int(recorded.get("action_size")),
        source="checkpoint manifest",
        observation_dtype=recorded.get("observation_dtype"),
        action_dtype=recorded.get("action_dtype"),
    )
