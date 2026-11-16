"""Central checkpoint discovery, resolution, and compatibility validation.

Every policy consumer (training resume, evaluation, the live policy server,
and the visible watch tool) resolves checkpoints through this module.  It is
also the single place that knows how a training manifest is associated with a
checkpoint and how checkpoint spaces are compared with the shared interface
schema in :mod:`interface_schema`.
"""

from __future__ import annotations

from dataclasses import dataclass
import io
import json
import os
from pathlib import Path
import zipfile
from unittest.mock import patch

from interface_schema import (
    ACTION_SIZE,
    OBSERVATION_SIZE,
    SCHEMA_VERSION,
    SchemaCompatibilityError,
    checkpoint_spaces_error,
    manifest_interface_error,
)


ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = Path(__file__).with_name("checkpoint_config.json")
STRATEGIES = ("best_then_latest", "best", "latest")
MANIFEST_SUFFIX = "_training_config.json"
# Only deliberately non-final artifacts are skipped.  A periodic checkpoint is
# complete the moment the training callback writes it.
IGNORED_PATH_PARTS = ("_recovery_",)
IGNORED_SUFFIXES = (".tmp", ".part", ".partial", ".incomplete", ".download")


class CheckpointError(RuntimeError):
    """Base class for checkpoint resolution and validation failures."""


class CheckpointNotFoundError(CheckpointError):
    """No checkpoint exists for the requested selection."""


class CheckpointAmbiguityError(CheckpointError):
    """Automatic discovery found multiple candidates the policy cannot rank."""


class CheckpointValidationError(CheckpointError):
    """A checkpoint or its manifest is unreadable or malformed."""


@dataclass(frozen=True)
class CheckpointConfig:
    """Central selection settings loaded from ``checkpoint_config.json``."""

    model_dir: Path
    default_checkpoint: Path | None
    manifest: Path | None
    strategy: str
    require_manifest: bool


@dataclass(frozen=True)
class CheckpointInfo:
    """Validated checkpoint metadata that can be inspected without training."""

    path: Path
    num_timesteps: int
    manifest_path: Path | None
    manifest: dict
    observation_space: object
    action_space: object


@dataclass(frozen=True)
class ResolvedCheckpoint:
    """The checkpoint chosen by the resolver plus the reason it was chosen."""

    path: Path
    source: str
    strategy: str
    num_timesteps: int
    manifest_path: Path | None
    manifest: dict


def _project_path(value: str | Path) -> Path:
    path = Path(value).expanduser()
    if not path.is_absolute():
        path = ROOT / path
    return path.resolve()


def load_checkpoint_config(
    path: str | Path | None = None,
    *,
    model_dir: str | Path | None = None,
    default_checkpoint: str | Path | None = None,
    manifest: str | Path | None = None,
    strategy: str | None = None,
    require_manifest: bool | None = None,
) -> CheckpointConfig:
    """Load the shared config, applying explicit per-call overrides.

    Relative paths are always resolved against the project root, never the
    caller's current directory.  This keeps the Godot launcher, the Python
    tools, and tests consistent.
    """
    config_path = Path(path) if path is not None else CONFIG_PATH
    try:
        raw = json.loads(config_path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise CheckpointNotFoundError(f"Checkpoint configuration not found: {config_path}") from error
    except (OSError, json.JSONDecodeError) as error:
        raise CheckpointValidationError(f"Checkpoint configuration {config_path} is invalid: {error}") from error
    if not isinstance(raw, dict):
        raise CheckpointValidationError(f"Checkpoint configuration {config_path} must be a JSON object")

    selected_model_dir = model_dir if model_dir is not None else raw.get("model_dir", "ai/models")
    selected_default = default_checkpoint if default_checkpoint is not None else raw.get("default_checkpoint")
    selected_manifest = manifest if manifest is not None else raw.get("manifest")
    selected_strategy = strategy if strategy is not None else raw.get("strategy", "best_then_latest")
    selected_require = require_manifest if require_manifest is not None else raw.get("require_manifest", False)

    if not isinstance(selected_model_dir, (str, Path)) or not str(selected_model_dir).strip():
        raise CheckpointValidationError("Checkpoint model_dir must be a non-empty path")
    if selected_strategy not in STRATEGIES:
        raise CheckpointValidationError(
            f"Unknown checkpoint strategy {selected_strategy!r}; expected one of {', '.join(STRATEGIES)}"
        )
    if not isinstance(selected_require, bool):
        raise CheckpointValidationError("Checkpoint require_manifest must be true or false")
    for name, value in (("default_checkpoint", selected_default), ("manifest", selected_manifest)):
        if value is not None and (not isinstance(value, (str, Path)) or not str(value).strip()):
            raise CheckpointValidationError(f"Checkpoint {name} must be a path or null")

    return CheckpointConfig(
        model_dir=_project_path(selected_model_dir),
        default_checkpoint=(
            _project_path(selected_default)
            if selected_default is not None else None
        ),
        manifest=(
            _project_path(selected_manifest)
            if selected_manifest is not None else None
        ),
        strategy=selected_strategy,
        require_manifest=selected_require,
    )


def _read_manifest(path: Path) -> dict:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise CheckpointValidationError(f"Checkpoint manifest {path} is not readable: {error}") from error
    try:
        manifest = json.loads(text)
    except json.JSONDecodeError as error:
        raise CheckpointValidationError(
            f"Checkpoint manifest {path} is not valid JSON: {error}"
        ) from error
    if not isinstance(manifest, dict):
        raise CheckpointValidationError(f"Checkpoint manifest {path} must be a JSON object")
    interface_error = manifest_interface_error(manifest)
    if interface_error:
        raise SchemaCompatibilityError(
            f"Checkpoint manifest {path} is incompatible: {interface_error}"
        )
    return manifest


def manifest_for_model(
    path: str | Path,
    *,
    manifest: str | Path | None = None,
) -> tuple[Path | None, dict]:
    """Return the manifest associated with a checkpoint, validating it.

    An explicit manifest path always wins.  Otherwise the nearest
    ``<run>_training_config.json`` next to the model, or next to its
    ``checkpoints/`` parent, is used.  Legacy checkpoints without a manifest
    return ``(None, {})``; malformed manifests are rejected.
    """
    if manifest is not None:
        manifest_path = _project_path(manifest)
        if not manifest_path.is_file():
            raise CheckpointNotFoundError(f"Checkpoint manifest does not exist: {manifest_path}")
        return manifest_path, _read_manifest(manifest_path)

    path = Path(path).resolve()
    folder = path.parent.parent if path.parent.name == "checkpoints" else path.parent
    candidates = [
        item for item in folder.glob("*" + MANIFEST_SUFFIX)
        if path.stem == item.name.removesuffix(MANIFEST_SUFFIX)
        or path.stem.startswith(item.name.removesuffix(MANIFEST_SUFFIX) + "_")
    ]
    if not candidates:
        return None, {}
    chosen = max(candidates, key=lambda item: len(item.name))
    return chosen, _read_manifest(chosen)


def _read_checkpoint_data(path: Path) -> dict:
    try:
        with zipfile.ZipFile(path) as archive:
            names = set(archive.namelist())
            missing = {"data", "policy.pth"} - names
            if missing:
                raise CheckpointValidationError(
                    f"Checkpoint {path} is not a Stable-Baselines3 ZIP; missing {', '.join(sorted(missing))}"
                )
            raw = archive.read("data")
    except CheckpointValidationError:
        raise
    except (OSError, zipfile.BadZipFile, RuntimeError) as error:
        raise CheckpointValidationError(
            f"Checkpoint {path} is unreadable or corrupted: {error}"
        ) from error
    try:
        data = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CheckpointValidationError(
            f"Checkpoint {path} has malformed Stable-Baselines3 metadata: {error}"
        ) from error
    if not isinstance(data, dict):
        raise CheckpointValidationError(f"Checkpoint {path} metadata must be a JSON object")
    return data


def _decode_spaces(path: Path, data: dict) -> tuple[object, object]:
    from stable_baselines3.common.save_util import json_to_data

    try:
        decoded = json_to_data(json.dumps({
            section: data[section] for section in ("observation_space", "action_space")
        }))
    except Exception as error:
        raise CheckpointValidationError(
            f"Checkpoint {path} has unreadable observation/action spaces: {error}"
        ) from error
    return decoded["observation_space"], decoded["action_space"]


def _validate_algorithm(path: Path, data: dict) -> None:
    # PPO stores its clipped-objective settings in the SB3 metadata.  Other
    # algorithms (for example A2C) do not, so this rejects them before any
    # policy is constructed or served.
    required = ("clip_range", "clip_range_vf", "n_epochs", "batch_size", "target_kl")
    missing = [key for key in required if key not in data]
    if missing:
        raise CheckpointValidationError(
            f"Checkpoint {path} is not a Stable-Baselines3 PPO policy; "
            f"missing PPO settings: {', '.join(missing)}"
        )


def inspect_checkpoint(
    path: str | Path,
    *,
    manifest: str | Path | None = None,
    require_manifest: bool = False,
) -> CheckpointInfo:
    """Validate a checkpoint's file, algorithm, schema spaces, and manifest."""
    checkpoint = _project_path(path)
    if not checkpoint.exists():
        raise CheckpointNotFoundError(f"Checkpoint does not exist: {checkpoint}")
    if not checkpoint.is_file():
        raise CheckpointValidationError(f"Checkpoint path is not a file: {checkpoint}")
    try:
        with checkpoint.open("rb") as file:
            file.read(4)
    except OSError as error:
        raise CheckpointValidationError(f"Checkpoint {checkpoint} is not readable: {error}") from error

    data = _read_checkpoint_data(checkpoint)
    _validate_algorithm(checkpoint, data)
    observation_space, action_space = _decode_spaces(checkpoint, data)
    space_error = checkpoint_spaces_error(observation_space, action_space)
    if space_error:
        raise SchemaCompatibilityError(
            f"Checkpoint {checkpoint} is incompatible with interface schema v{SCHEMA_VERSION}: {space_error}"
        )

    manifest_path, manifest_data = manifest_for_model(checkpoint, manifest=manifest)
    if require_manifest and manifest_path is None:
        raise CheckpointValidationError(
            f"Checkpoint {checkpoint} has no adjacent {MANIFEST_SUFFIX} manifest, "
            "but the current loading policy requires one. "
            "Restore the run manifest or select a checkpoint that has one."
        )
    timesteps = data.get("num_timesteps", 0)
    if isinstance(timesteps, bool) or not isinstance(timesteps, int) or timesteps < 0:
        raise CheckpointValidationError(
            f"Checkpoint {checkpoint} has invalid training timesteps: {timesteps!r}"
        )

    return CheckpointInfo(
        path=checkpoint,
        num_timesteps=timesteps,
        manifest_path=manifest_path,
        manifest=manifest_data,
        observation_space=observation_space,
        action_space=action_space,
    )


def _is_ignored(path: Path) -> bool:
    name = path.name
    if name.startswith((".", "~")):
        return True
    if any(part in str(path) for part in IGNORED_PATH_PARTS):
        return True
    return any(name.endswith(suffix) for suffix in IGNORED_SUFFIXES)


def _best_score(candidate: CheckpointInfo) -> tuple[float, ...] | None:
    score_path = candidate.path.with_name(candidate.path.stem + "_score.json")
    if not score_path.is_file():
        return None
    try:
        payload = json.loads(score_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    score = payload.get("score") if isinstance(payload, dict) else None
    if not isinstance(score, list) or not score:
        return None
    try:
        return tuple(float(item) for item in score)
    except (TypeError, ValueError):
        return None


def _select_best(candidates: list[CheckpointInfo]) -> CheckpointInfo:
    if len(candidates) == 1:
        return candidates[0]
    ranked: list[tuple[tuple[float, ...], CheckpointInfo]] = []
    for candidate in candidates:
        score = _best_score(candidate)
        if score is None:
            raise CheckpointAmbiguityError(
                "Multiple best checkpoints were found and their selection is ambiguous: "
                + ", ".join(str(item.path) for item in candidates)
                + ". Add the corresponding *_best_score.json ranking files, select one "
                "explicitly with --model, or use --strategy latest."
            )
        ranked.append((score, candidate))
    ranked.sort(key=lambda item: item[0], reverse=True)
    if len(ranked) > 1 and ranked[0][0] == ranked[1][0]:
        raise CheckpointAmbiguityError(
            "Multiple best checkpoints have the same recorded evaluation score: "
            + ", ".join(str(item.path) for item in candidates)
            + ". Select one explicitly with --model."
        )
    return ranked[0][1]


def _select_latest(candidates: list[CheckpointInfo]) -> CheckpointInfo:
    # Training steps describe how much completed training a checkpoint has,
    # not its quality.  The path tie-break guarantees repeatable selection when
    # a final model and a periodic checkpoint share a timestep count.
    return max(candidates, key=lambda item: (item.num_timesteps, str(item.path)))


def _discover(config: CheckpointConfig) -> tuple[list[CheckpointInfo], dict[str, str]]:
    model_dir = config.model_dir
    if not model_dir.exists():
        raise CheckpointNotFoundError(
            f"Checkpoint directory does not exist: {model_dir}. "
            "Create it, train a policy, or pass --model / --model-dir."
        )
    if not model_dir.is_dir():
        raise CheckpointNotFoundError(f"Checkpoint directory is not a directory: {model_dir}")

    candidates: list[CheckpointInfo] = []
    skipped: dict[str, str] = {}
    for path in sorted(model_dir.rglob("*.zip"), key=lambda item: str(item)):
        if _is_ignored(path):
            skipped[str(path)] = "temporary, incomplete, hidden, or recovery artifact"
            continue
        try:
            candidates.append(
                inspect_checkpoint(
                    path,
                    manifest=config.manifest,
                    require_manifest=config.require_manifest,
                )
            )
        except (CheckpointError, SchemaCompatibilityError) as error:
            skipped[str(path)] = str(error)
    return candidates, skipped


def _discovery_error(config: CheckpointConfig, skipped: dict[str, str]) -> CheckpointNotFoundError:
    details = ""
    if skipped:
        shown = list(skipped.items())[:5]
        details = " Skipped candidates: " + "; ".join(
            f"{path} ({reason})" for path, reason in shown
        )
        if len(skipped) > len(shown):
            details += f"; and {len(skipped) - len(shown)} more."
    return CheckpointNotFoundError(
        f"No valid Stable-Baselines3 PPO checkpoint for interface schema v{SCHEMA_VERSION} "
        f"(observation {OBSERVATION_SIZE}, action {ACTION_SIZE}) was found in {config.model_dir} "
        f"using strategy {config.strategy!r}.{details} "
        "Pass an explicit --model path or add a compatible checkpoint."
    )


def resolve_checkpoint(
    explicit: str | Path | None = None,
    *,
    config: CheckpointConfig | None = None,
    config_path: str | Path | None = None,
    model_dir: str | Path | None = None,
    default_checkpoint: str | Path | None = None,
    manifest: str | Path | None = None,
    strategy: str | None = None,
    require_manifest: bool | None = None,
) -> ResolvedCheckpoint:
    """Resolve one checkpoint deterministically.

    Priority: explicit argument, ``AI_CHECKPOINT`` environment variable,
    configured default checkpoint, then automatic discovery.
    """
    if config is None:
        config = load_checkpoint_config(
            config_path,
            model_dir=model_dir,
            default_checkpoint=default_checkpoint,
            manifest=manifest,
            strategy=strategy,
            require_manifest=require_manifest,
        )

    requested = explicit
    source = "explicit"
    if requested is None:
        environment = os.environ.get("AI_CHECKPOINT", "").strip()
        if environment:
            requested = environment
            source = "environment"
    if requested is not None:
        info = inspect_checkpoint(
            requested,
            manifest=config.manifest,
            require_manifest=config.require_manifest,
        )
        return ResolvedCheckpoint(
            path=info.path,
            source=source,
            strategy="explicit",
            num_timesteps=info.num_timesteps,
            manifest_path=info.manifest_path,
            manifest=info.manifest,
        )

    if config.default_checkpoint is not None:
        info = inspect_checkpoint(
            config.default_checkpoint,
            manifest=config.manifest,
            require_manifest=config.require_manifest,
        )
        return ResolvedCheckpoint(
            path=info.path,
            source="configured-default",
            strategy="configured-default",
            num_timesteps=info.num_timesteps,
            manifest_path=info.manifest_path,
            manifest=info.manifest,
        )

    candidates, skipped = _discover(config)
    if not candidates:
        raise _discovery_error(config, skipped)

    if config.strategy == "latest":
        selected = _select_latest(candidates)
        used = "latest"
    else:
        best = [item for item in candidates if item.path.stem.endswith("_best")]
        if best:
            selected = _select_best(best)
            used = "best"
        elif config.strategy == "best":
            raise CheckpointNotFoundError(
                f"No *_best.zip checkpoint exists in {config.model_dir}. "
                "Use strategy 'best_then_latest', 'latest', or pass an explicit --model."
            )
        else:
            selected = _select_latest(candidates)
            used = "latest"

    return ResolvedCheckpoint(
        path=selected.path,
        source="discovered",
        strategy=used,
        num_timesteps=selected.num_timesteps,
        manifest_path=selected.manifest_path,
        manifest=selected.manifest,
    )


def checkpoint_generator(
    path: str | Path,
    explicit: str | None = None,
    *,
    manifest: str | Path | None = None,
) -> str:
    """Return the generator type stored in a checkpoint manifest."""
    _manifest_path, manifest_data = manifest_for_model(path, manifest=manifest)
    saved = manifest_data.get("generator_type", "original")
    if saved not in ("original", "segmented"):
        raise CheckpointValidationError(
            f"Checkpoint {path} manifest has invalid generator_type {saved!r}; "
            "expected 'original' or 'segmented'."
        )
    if explicit and manifest_data and explicit != saved:
        raise ValueError(f"Checkpoint was trained on {saved} roads, not {explicit} roads.")
    return explicit or saved


def load_policy(
    path: str | Path,
    env: object = None,
    *,
    manifest: str | Path | None = None,
    require_manifest: bool = False,
):
    """Validate and load a Stable-Baselines3 PPO checkpoint."""
    import torch
    from stable_baselines3 import PPO

    info = inspect_checkpoint(path, manifest=manifest, require_manifest=require_manifest)
    original = torch.load

    def buffered(member, *args, **kwargs):
        if isinstance(member, zipfile.ZipExtFile):
            member = io.BytesIO(member.read())
        return original(member, *args, **kwargs)

    try:
        with patch.object(torch, "load", side_effect=buffered):
            model = PPO.load(info.path, env=env, device="cpu")
    except Exception as error:
        raise CheckpointValidationError(
            f"Checkpoint {info.path} could not be loaded as a Stable-Baselines3 PPO "
            f"policy: {error}"
        ) from error

    space_error = checkpoint_spaces_error(model.observation_space, model.action_space)
    if space_error:
        raise SchemaCompatibilityError(
            f"Checkpoint {info.path} is incompatible with interface schema v{SCHEMA_VERSION}: {space_error}"
        )
    return model
