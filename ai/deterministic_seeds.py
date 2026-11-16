"""Central seed derivation and global random-generator seeding.

The master seed is the only seed users need to provide.  Component and worker
seeds are derived with SHA-256 so they stay stable when unrelated components
are added, and so two workers never intentionally consume the same stream.

This module deliberately has no Stable-Baselines3 dependency so it can be
imported by the command-line tools, the GUI launcher, and lightweight tests.
"""

from __future__ import annotations

import hashlib
import platform
import random
import subprocess
import sys
from pathlib import Path
from typing import Any

import numpy as np


SEED_DERIVATION_VERSION = 1
SEED_DERIVATION_NAME = "sha256-components-v1"
MAX_SEED = 2**31 - 1
COMPONENT_NAMES = (
    "python",
    "numpy",
    "torch",
    "gymnasium",
    "episode_stream",
    "map",
    "scenario",
    "traffic",
    "pedestrians",
    "traffic_lights",
)
_WORKER_COMPONENTS = ("episode_stream", "map", "scenario", "traffic", "pedestrians", "traffic_lights")
_SALT = b"autonomous-vehicles-seed-v1"


def validate_master_seed(seed: int) -> int:
    """Return a normalised master seed or raise a useful error."""
    if isinstance(seed, bool) or not isinstance(seed, (int, np.integer)):
        raise ValueError("master seed must be an integer")
    value = int(seed)
    if value < 0:
        raise ValueError("master seed must be non-negative")
    # Keep the value JSON-safe and portable across platforms.
    if value > 2**63 - 1:
        raise ValueError("master seed must fit in a signed 64-bit integer")
    return value


def derive_seed(master_seed: int, component: str, index: int = 0) -> int:
    """Derive a stable positive 31-bit seed for one component or worker.

    Includes the derivation version and a component/index pair in the digest,
    so changing one component's sequence does not perturb another component.
    """
    master = validate_master_seed(master_seed)
    if not isinstance(component, str) or not component:
        raise ValueError("seed component must be a non-empty string")
    if isinstance(index, bool) or not isinstance(index, (int, np.integer)) or int(index) < 0:
        raise ValueError("seed index must be a non-negative integer")
    payload = b":".join(
        (
            _SALT,
            str(SEED_DERIVATION_VERSION).encode("ascii"),
            str(master).encode("ascii"),
            component.encode("utf-8"),
            str(int(index)).encode("ascii"),
        )
    )
    digest = hashlib.sha256(payload).digest()
    value = int.from_bytes(digest[:8], "big") & MAX_SEED
    return value or 1


def _component_seeds(master_seed: int, index: int = 0) -> dict[str, int]:
    return {name: derive_seed(master_seed, name, index) for name in COMPONENT_NAMES}


def seed_plan(
    master_seed: int,
    *,
    workers: int = 1,
    evaluation_seed: int | None = None,
    final_evaluation_seed: int | None = None,
    replay_format_version: int | None = None,
) -> dict[str, Any]:
    """Build the effective, serialisable seed configuration for a run."""
    master = validate_master_seed(master_seed)
    if isinstance(workers, bool) or not isinstance(workers, int) or workers < 1:
        raise ValueError("workers must be a positive integer")
    components = _component_seeds(master)
    worker_entries = []
    for index in range(workers):
        worker_entries.append(
            {
                "index": index,
                "worker_seed": derive_seed(master, "worker", index),
                "replay_seed": derive_seed(master, "worker_replay", index),
                "components": {
                    name: derive_seed(master, name, index)
                    for name in _WORKER_COMPONENTS
                },
            }
        )
    plan: dict[str, Any] = {
        "master_seed": master,
        "derivation": SEED_DERIVATION_NAME,
        "derivation_version": SEED_DERIVATION_VERSION,
        "components": components,
        "workers": worker_entries,
    }
    if evaluation_seed is not None:
        plan["evaluation_seed"] = validate_master_seed(evaluation_seed)
    if final_evaluation_seed is not None:
        plan["final_evaluation_seed"] = validate_master_seed(final_evaluation_seed)
    if replay_format_version is not None:
        plan["replay_format_version"] = int(replay_format_version)
    return plan


def environment_seed(master_seed: int, worker_index: int = 0) -> int:
    """Seed used to initialise a worker's Gymnasium random stream."""
    return derive_seed(master_seed, "episode_stream", worker_index)


def set_global_seeds(master_seed: int, *, include_torch: bool = True) -> dict[str, int]:
    """Seed every process-global generator used by the Python training stack.

    Stable-Baselines3 also receives ``--seed`` and applies its own seeding, but
    setting these globals makes standalone tools, NumPy helpers, and any
    library that falls back to process globals reproducible as well.
    """
    master = validate_master_seed(master_seed)
    python_seed = derive_seed(master, "python")
    numpy_seed = derive_seed(master, "numpy")
    random.seed(python_seed)
    np.random.seed(numpy_seed)
    seeded = {"python": python_seed, "numpy": numpy_seed}
    if include_torch:
        try:
            import torch
        except ImportError:  # Optional for tests and non-training tools.
            pass
        else:
            torch_seed = derive_seed(master, "torch")
            torch.manual_seed(torch_seed)
            if torch.cuda.is_available():
                torch.cuda.manual_seed_all(torch_seed)
            seeded["torch"] = torch_seed
    return seeded


def code_revision(project_root: str | Path | None = None) -> str | None:
    """Return the current Git revision when the project is a Git checkout."""
    root = Path(project_root).resolve() if project_root is not None else Path(__file__).resolve().parents[1]
    try:
        result = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=root,
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    revision = result.stdout.strip()
    return revision if result.returncode == 0 and len(revision) == 40 else None


def runtime_metadata() -> dict[str, Any]:
    """Small, portable runtime fingerprint stored in recordings and manifests."""
    from importlib.metadata import PackageNotFoundError, version

    packages: dict[str, str] = {}
    for name in ("numpy", "gymnasium", "stable-baselines3", "torch"):
        try:
            packages[name] = version(name)
        except PackageNotFoundError:
            continue
    return {
        "python": sys.version,
        "platform": platform.platform(),
        "packages": packages,
        "code_revision": code_revision(),
    }


def determinism_metadata(
    master_seed: int,
    *,
    workers: int = 1,
    evaluation_seed: int | None = None,
    final_evaluation_seed: int | None = None,
    replay_format_version: int | None = None,
) -> dict[str, Any]:
    """Manifest metadata describing what reproducibility is guaranteed."""
    plan = seed_plan(
        master_seed,
        workers=workers,
        evaluation_seed=evaluation_seed,
        final_evaluation_seed=final_evaluation_seed,
        replay_format_version=replay_format_version,
    )
    return {
        "schema_version": 1,
        "seed_plan": plan,
        "global_generators": ["python.random", "numpy.random", "torch"],
        "simulation_generators": ["godot.map", "godot.scenario", "godot.traffic", "godot.pedestrians", "godot.traffic_lights"],
        "guarantee": (
            "Same platform, engine, dependency versions, seed, configuration, "
            "initial conditions, and action sequence reproduce observations, "
            "rewards, flags, and collision metadata within comparison tolerances. "
            "Cross-platform bitwise equality is not claimed."
        ),
        "comparison_defaults": {"atol": 1e-6, "rtol": 1e-6},
    }
