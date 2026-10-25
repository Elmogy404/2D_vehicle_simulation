"""Defaults and experiment manifests shared by the trainer and both interfaces."""
from __future__ import annotations

import hashlib
from importlib.metadata import version
import json
from pathlib import Path
import platform
import sys

ROOT = Path(__file__).resolve().parents[1]
SPEC = json.loads((ROOT / "ai/training_defaults.json").read_text(encoding="utf-8"))
TRAINING_DEFAULTS = SPEC["training"]
REWARD_DEFAULTS = SPEC["reward_config"]


def runtime_provenance() -> dict:
    digest = hashlib.sha256()
    names = ["ai/rl_training_world.gd", "ai/godot_gym_env.py", "ai/godot_bridge.py", "ai/training_defaults.json",
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
        for key in ("environment_version", "generator_type", "workers", "evaluation", "reward_config",
                    "learning_rate", "batch_size", "gamma", "entropy_coefficient"):
            if previous.get(key) != manifest.get(key):
                raise ValueError(f"Resume settings differ for {key}; keep the original values or start a new run.")
        if previous.get("runtime", {}).get("source_hash") not in (None, manifest.get("runtime", {}).get("source_hash")):
            raise ValueError("Simulation source changed since this run. Start a new experiment instead of mixing environments.")
        return
    name = path.name.removesuffix("_training_config.json")
    if run_exists(path.parent, name):
        raise ValueError("This run name already exists. Choose a new name or resume its checkpoint.")
    # Exclusive creation also reserves the name against another launcher.
    with path.open("x", encoding="utf-8") as file:
        json.dump(manifest, file, indent=2)
