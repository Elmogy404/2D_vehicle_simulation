"""Checkpoint loading and manifest discovery shared by every policy consumer."""
from __future__ import annotations
import io
import json
from pathlib import Path
import zipfile
from unittest.mock import patch


def manifest_for_model(path: str | Path) -> tuple[Path | None, dict]:
    path = Path(path).resolve()
    folder = path.parent.parent if path.parent.name == "checkpoints" else path.parent
    candidates = [item for item in folder.glob("*_training_config.json")
                  if path.stem == item.name.removesuffix("_training_config.json")
                  or path.stem.startswith(item.name.removesuffix("_training_config.json") + "_")]
    if not candidates:
        return None, {}
    manifest = max(candidates, key=lambda item: len(item.name))
    return manifest, json.loads(manifest.read_text(encoding="utf-8"))


def checkpoint_generator(path: str | Path, explicit: str | None = None) -> str:
    _path, manifest = manifest_for_model(path)
    saved = manifest.get("generator_type", "original")
    if explicit and manifest and explicit != saved:
        raise ValueError(f"Checkpoint was trained on {saved} roads, not {explicit} roads.")
    return explicit or saved


def load_policy(path: str | Path, env: object = None):
    import torch
    from stable_baselines3 import PPO
    original = torch.load

    def buffered(member, *args, **kwargs):
        if isinstance(member, zipfile.ZipExtFile):
            member = io.BytesIO(member.read())
        return original(member, *args, **kwargs)

    with patch.object(torch, "load", side_effect=buffered):
        return PPO.load(path, env=env, device="cpu")
