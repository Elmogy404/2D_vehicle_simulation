"""Shared reward-configuration schema, validation, and provenance helpers.

The parameter definitions live in ``ai/reward_config.json`` so the Python
training/evaluation stack and the Godot environment validate exactly the same
fields, ranges, and signedness rules.  This module is the Python entry point;
``scripts/reward_config.gd`` reads the same JSON file for the runtime side.

A *complete* reward configuration (training manifests, checkpoint manifests,
and full files) must contain every field in ``PARAMETER_ORDER``.  An
*override* (CLI ``--reward-config``, GUI previews, and per-episode reset
messages) may contain only the fields it wants to change; omitted fields keep
the documented schema defaults.  Callers must opt into that behaviour with
``allow_partial=True``.
"""

from __future__ import annotations

from collections.abc import Mapping
import hashlib
import json
import math
from pathlib import Path
from typing import Any


SCHEMA_PATH = Path(__file__).with_name("reward_config.json")


class RewardConfigError(ValueError):
    """A reward configuration is malformed, incomplete, or out of range."""


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise RewardConfigError(f"reward_config.{key}: duplicate field is not allowed")
        result[key] = value
    return result


def _load_json_object(path: Path) -> dict[str, Any]:
    try:
        parsed = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=_reject_duplicate_keys,
        )
    except OSError as error:
        raise RewardConfigError(f"Could not read reward configuration schema {path}: {error}") from error
    except json.JSONDecodeError as error:
        raise RewardConfigError(f"Reward configuration schema {path} is not valid JSON: {error}") from error
    if not isinstance(parsed, dict):
        raise RewardConfigError(f"Reward configuration schema {path} must be a JSON object")
    return parsed


def _load_schema() -> dict[str, Any]:
    schema = _load_json_object(SCHEMA_PATH)
    version = schema.get("schema_version")
    if type(version) is not int or version < 1:
        raise RewardConfigError("reward_config.schema_version: the schema must declare a positive integer version")
    order = schema.get("order")
    parameters = schema.get("parameters")
    defaults = schema.get("defaults")
    if not isinstance(order, list) or not order or any(not isinstance(key, str) for key in order):
        raise RewardConfigError("reward_config.order: the schema must declare a non-empty list of parameter names")
    if len(order) != len(set(order)):
        raise RewardConfigError("reward_config.order: duplicate parameter names are not allowed")
    if not isinstance(parameters, dict) or set(parameters) != set(order):
        raise RewardConfigError("reward_config.parameters: parameters must exactly match the declared order")
    if not isinstance(defaults, dict) or set(defaults) != set(order):
        raise RewardConfigError("reward_config.defaults: defaults must define every declared parameter")
    for key in order:
        rule = parameters[key]
        if not isinstance(rule, dict):
            raise RewardConfigError(f"reward_config.{key}: the parameter rule must be an object")
        if rule.get("type") != "number":
            raise RewardConfigError(f"reward_config.{key}.type: only 'number' is supported")
        if not isinstance(rule.get("label"), str) or not rule["label"].strip():
            raise RewardConfigError(f"reward_config.{key}.label: a non-empty label is required")
        if rule.get("required") is not True:
            raise RewardConfigError(f"reward_config.{key}.required: complete reward configurations require this field")
        for bound in ("min", "max"):
            value = rule.get(bound)
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(float(value)):
                raise RewardConfigError(f"reward_config.{key}.{bound}: a finite number is required")
        if float(rule["min"]) > float(rule["max"]):
            raise RewardConfigError(f"reward_config.{key}: min must not exceed max")
        if not isinstance(rule.get("allow_negative"), bool):
            raise RewardConfigError(f"reward_config.{key}.allow_negative: a boolean is required")
        if not isinstance(rule.get("allow_zero"), bool):
            raise RewardConfigError(f"reward_config.{key}.allow_zero: a boolean is required")
        default = defaults[key]
        if isinstance(default, bool) or not isinstance(default, (int, float)) or not math.isfinite(float(default)):
            raise RewardConfigError(f"reward_config.{key}: the default must be a finite number")
        number = float(default)
        if not float(rule["min"]) <= number <= float(rule["max"]):
            raise RewardConfigError(f"reward_config.{key}: the default is outside its declared range")
        if number < 0.0 and not rule["allow_negative"]:
            raise RewardConfigError(f"reward_config.{key}: the default is negative but the field is non-negative")
        if number == 0.0 and not rule["allow_zero"]:
            raise RewardConfigError(f"reward_config.{key}: the default is zero but zero is not allowed")
    return schema


SCHEMA = _load_schema()
SCHEMA_VERSION = int(SCHEMA["schema_version"])
PARAMETER_ORDER = tuple(SCHEMA["order"])
PARAMETERS: dict[str, dict[str, Any]] = SCHEMA["parameters"]
DEFAULTS: dict[str, float] = {key: float(SCHEMA["defaults"][key]) for key in PARAMETER_ORDER}
_METADATA_KEYS = frozenset({"schema_version", "config_version", "reward_config"})


def defaults() -> dict[str, float]:
    """Return a fresh copy of the schema defaults."""
    return dict(DEFAULTS)


def _format_number(value: float) -> str:
    return format(value, ".12g")


def _version_error(field: str, value: Any) -> str | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return f"reward_config.{field}: must be an integer version number"
    if not math.isfinite(float(value)) or float(value) != int(float(value)):
        return f"reward_config.{field}: must be an integer version number"
    if int(value) != SCHEMA_VERSION:
        return (
            f"reward_config.{field}: unsupported configuration version {int(value)} "
            f"(this project supports version {SCHEMA_VERSION})"
        )
    return None


def _version_errors(schema_version: Any, config_version: Any) -> list[str]:
    errors: list[str] = []
    schema_error = _version_error("schema_version", schema_version) if schema_version is not None else None
    config_error = _version_error("config_version", config_version) if config_version is not None else None
    if schema_error:
        errors.append(schema_error)
    if config_error:
        errors.append(config_error)
    if (
        schema_version is not None
        and config_version is not None
        and schema_error is None
        and config_error is None
        and int(schema_version) != int(config_version)
    ):
        errors.append("reward_config: schema_version and config_version disagree; remove one or make them equal")
    return errors


def _split_versioned_payload(payload: Mapping[str, Any]) -> tuple[Mapping[str, Any], list[str]]:
    """Return the reward body and structural/version errors."""
    errors: list[str] = []
    if "reward_config" in payload:
        extras = sorted(set(payload) - _METADATA_KEYS)
        for key in extras:
            errors.append(
                f"reward_config: field '{key}' cannot be combined with a nested 'reward_config' object"
            )
        schema_version = payload.get("schema_version")
        config_version = payload.get("config_version")
        errors.extend(_version_errors(schema_version, config_version))
        body = payload["reward_config"]
        if not isinstance(body, Mapping):
            errors.append("reward_config.reward_config: must be a JSON object")
            return {}, errors
        return body, errors

    body = dict(payload)
    schema_version = body.pop("schema_version", None)
    config_version = body.pop("config_version", None)
    errors.extend(_version_errors(schema_version, config_version))
    return body, errors


def validate_reward_config(
    payload: Mapping[str, Any],
    *,
    allow_partial: bool = False,
    source: str = "reward_config",
) -> dict[str, float]:
    """Validate a reward configuration and return a complete effective copy.

    ``allow_partial=True`` is only for explicit overrides.  Missing fields then
    use the schema defaults; unknown fields, bad types, non-finite values,
    unsupported versions, and range/sign violations are always rejected.
    """
    if not isinstance(payload, Mapping):
        raise RewardConfigError(f"{source}: reward configuration must be a JSON object")
    if not payload:
        if allow_partial:
            return defaults()
        missing = ", ".join(PARAMETER_ORDER)
        raise RewardConfigError(f"{source}: reward configuration is empty; required fields: {missing}")

    body, errors = _split_versioned_payload(payload)
    body_keys = set(body)
    unknown = sorted(body_keys - set(PARAMETERS))
    for key in unknown:
        errors.append(f"{source}.{key}: unknown reward field")
    if not body_keys and not allow_partial and not unknown:
        missing = ", ".join(PARAMETER_ORDER)
        errors.append(f"{source}: reward configuration is empty; required fields: {missing}")

    result: dict[str, float] = {}
    for key in PARAMETER_ORDER:
        rule = PARAMETERS[key]
        if key not in body:
            if not allow_partial:
                errors.append(f"{source}.{key}: required field is missing")
            else:
                result[key] = defaults()[key]
            continue
        value = body[key]
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            errors.append(f"{source}.{key}: must be a number (got {type(value).__name__})")
            continue
        number = float(value)
        if not math.isfinite(number):
            errors.append(f"{source}.{key}: must be finite; NaN and Infinity are not allowed")
            continue
        minimum = float(rule["min"])
        maximum = float(rule["max"])
        if number < 0.0 and not rule["allow_negative"]:
            errors.append(
                f"{source}.{key}: must be non-negative because it is subtracted as a positive penalty "
                f"or is a non-negative reward term (got {_format_number(number)})"
            )
            continue
        if number < minimum or number > maximum:
            errors.append(
                f"{source}.{key}: {_format_number(number)} is outside the allowed range "
                f"[{_format_number(minimum)}, {_format_number(maximum)}]"
            )
            continue
        if number == 0.0 and not rule["allow_zero"]:
            errors.append(f"{source}.{key}: zero is not allowed for this component")
            continue
        result[key] = number

    if errors:
        raise RewardConfigError("; ".join(errors))
    return {key: result[key] for key in PARAMETER_ORDER}


def parse_reward_config_text(
    text: str,
    *,
    source: str = "reward_config",
    allow_partial: bool = True,
) -> dict[str, float]:
    """Parse and validate JSON text, rejecting duplicate keys explicitly."""
    try:
        payload = json.loads(text, object_pairs_hook=_reject_duplicate_keys)
    except json.JSONDecodeError as error:
        raise RewardConfigError(f"{source}: malformed JSON: {error.msg} at line {error.lineno}, column {error.colno}") from error
    return validate_reward_config(payload, allow_partial=allow_partial, source=source)


def load_reward_config_file(
    path: str | Path,
    *,
    allow_partial: bool = False,
    source: str | None = None,
) -> dict[str, float]:
    """Load and validate a reward configuration file."""
    config_path = Path(path)
    label = source or str(config_path)
    try:
        text = config_path.read_text(encoding="utf-8")
    except OSError as error:
        raise RewardConfigError(f"{label}: could not read reward configuration: {error}") from error
    return parse_reward_config_text(text, source=label, allow_partial=allow_partial)


def reward_config_hash(config: Mapping[str, Any]) -> str:
    """Return a stable SHA-256 over the schema version and effective values."""
    effective = validate_reward_config(config, allow_partial=False, source="reward_config")
    canonical = json.dumps(
        {"schema_version": SCHEMA_VERSION, "reward_config": effective},
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    )
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def reward_config_from_manifest(
    manifest: Mapping[str, Any] | None,
    *,
    source: str = "training manifest",
) -> dict[str, float]:
    """Return the validated reward configuration recorded by a manifest.

    Legacy manifests without a reward block use the schema defaults and are
    reported explicitly.  New manifests should carry ``reward_config_hash``;
    when present it is verified so edited values cannot masquerade as the
    original experiment configuration.
    """
    if not manifest:
        return defaults()
    recorded_version = manifest.get("reward_config_schema_version")
    if recorded_version is not None and recorded_version != SCHEMA_VERSION:
        raise RewardConfigError(
            f"{source}: unsupported reward configuration schema version {recorded_version} "
            f"(this project supports version {SCHEMA_VERSION})"
        )
    if "reward_config" not in manifest:
        print(
            f"Warning: {source} has no reward_config; using current reward defaults. "
            "Reward provenance cannot be verified for this legacy manifest.",
            flush=True,
        )
        return defaults()
    effective = validate_reward_config(
        manifest["reward_config"],
        allow_partial=False,
        source=f"{source}.reward_config",
    )
    recorded_hash = manifest.get("reward_config_hash")
    if recorded_hash is not None:
        actual_hash = reward_config_hash(effective)
        if recorded_hash != actual_hash:
            raise RewardConfigError(
                f"{source}: reward_config_hash does not match the recorded reward configuration "
                f"(recorded {recorded_hash}, computed {actual_hash})"
            )
    return effective
