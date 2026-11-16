"""Defaults and experiment manifests shared by the trainer and both interfaces."""
from __future__ import annotations

import hashlib
from importlib.metadata import version
import json
from pathlib import Path
import platform
import sys

from reward_config import (
    SCHEMA_VERSION as REWARD_SCHEMA_VERSION,
    defaults as reward_defaults,
    reward_config_hash,
    validate_reward_config,
)

ROOT = Path(__file__).resolve().parents[1]
SPEC = json.loads((ROOT / "ai/training_defaults.json").read_text(encoding="utf-8"))
TRAINING_DEFAULTS = SPEC["training"]
REWARD_DEFAULTS = reward_defaults()


def runtime_provenance() -> dict:
    digest = hashlib.sha256()
    names = ["ai/rl_training_world.gd", "ai/godot_gym_env.py", "ai/godot_bridge.py", "ai/training_defaults.json",
             "ai/interface_schema.json", "ai/interface_schema.py", "scripts/ai_interface_schema.gd",
             "scenes/EgoVehicle.tscn", "scenes/RoadGenerator.tscn", "project.godot"]
    names += [str(path.relative_to(ROOT)).replace("\\", "/") for path in sorted((ROOT / "scenes/road_pieces").glob("*.tscn"))]
    names += ["scripts/" + name + ".gd" for name in ("driving_task", "driving_route", "vehicle_clearance",
        "ego_vehicle", "road_network", "road_generator", "segment_road_generator", "road_piece", "route_path", "sensor_rig")]
    for name in names:
        digest.update(name.encode())
        digest.update((ROOT / name).read_bytes().replace(b"\r\n", b"\n"))
    return {"source_hash": digest.hexdigest(), "python": sys.version, "platform": platform.platform(),
            "packages": {name: version(name) for name in ("numpy", "torch", "gymnasium", "stable-baselines3")}}


def run_exists(model_dir: Path, name: str) -> bool:
    return any((model_dir / (name + suffix)).exists() for suffix in (".zip", "_best.zip", "_training_config.json")) or any(
        (model_dir / "checkpoints").glob(name + "_*.zip"))


def prepare_manifest(path: Path, manifest: dict, *, resume: bool) -> None:
    if resume:
        if not path.exists():
            print("Warning: no run manifest exists; original training settings cannot be fully verified.", flush=True)
            return
        previous = json.loads(path.read_text(encoding="utf-8"))
        previous.setdefault("generator_type", "original")
        for key in ("environment_version", "generator_type", "workers", "evaluation",
                    "learning_rate", "batch_size", "gamma", "entropy_coefficient"):
            if previous.get(key) != manifest.get(key):
                raise ValueError(f"Resume settings differ for {key}; keep the original values or start a new run.")
        previous_reward = previous.get("reward_config")
        requested_reward = manifest.get("reward_config")
        previous_schema = previous.get("reward_config_schema_version")
        if previous_schema is not None and previous_schema != REWARD_SCHEMA_VERSION:
            raise ValueError(
                f"Resume reward configuration schema version {previous_schema} is unsupported; "
                f"this project supports version {REWARD_SCHEMA_VERSION}."
            )
        if previous_reward is not None:
            previous_effective = validate_reward_config(
                previous_reward,
                allow_partial=False,
                source=f"{path.name}.reward_config",
            )
            recorded_hash = previous.get("reward_config_hash")
            if recorded_hash is not None and recorded_hash != reward_config_hash(previous_effective):
                raise ValueError(
                    "Resume manifest reward_config_hash does not match its recorded reward configuration; "
                    "the manifest was edited or corrupted."
                )
            if requested_reward is not None:
                requested_effective = validate_reward_config(
                    requested_reward,
                    allow_partial=False,
                    source="requested reward_config",
                )
                requested_hash = manifest.get("reward_config_hash")
                if requested_hash is not None and requested_hash != reward_config_hash(requested_effective):
                    raise ValueError("Requested reward_config_hash does not match the requested reward configuration.")
                if previous_effective != requested_effective:
                    raise ValueError(
                        "Resume reward configuration differs from the original run; "
                        "keep the original reward values or start a new run."
                    )
            else:
                raise ValueError(
                    "Resume reward configuration is missing from the requested manifest; "
                    "the original run recorded reward values."
                )
        elif previous.get("reward_config_hash") is not None:
            raise ValueError(
                "Resume manifest records a reward_config_hash without a reward_config; "
                "the manifest is incomplete."
            )
        elif requested_reward is not None:
            print(
                "Warning: the existing manifest has no reward_config; reward provenance cannot be verified. "
                "The current reward configuration will be used.",
                flush=True,
            )
        if previous.get("interface_schema") is not None \
                and previous.get("interface_schema") != manifest.get("interface_schema"):
            raise ValueError("Resume interface schema differs; keep the original observation/action contract or start a new run.")
        if previous.get("runtime", {}).get("source_hash") not in (None, manifest.get("runtime", {}).get("source_hash")):
            raise ValueError("Simulation source changed since this run. Start a new experiment instead of mixing environments.")
        return
    name = path.name.removesuffix("_training_config.json")
    if run_exists(path.parent, name):
        raise ValueError("This run name already exists. Choose a new name or resume its checkpoint.")
    # Exclusive creation also reserves the name against another launcher.
    with path.open("x", encoding="utf-8") as file:
        json.dump(manifest, file, indent=2)
