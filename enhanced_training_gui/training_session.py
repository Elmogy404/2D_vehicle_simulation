"""Shared, Tk-free launch/control service for both standalone training modes."""
from __future__ import annotations

from contextlib import contextmanager
import configparser
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import zipfile

AI_DIR = Path(__file__).resolve().parents[1] / "ai"
if str(AI_DIR) not in sys.path:
    sys.path.insert(0, str(AI_DIR))
from godot_bridge import find_godot
from godot_gym_env import ENVIRONMENT_VERSION
from gui_train_launcher import process_is_running
from training_control import DEFAULT_REWARD_CONFIG, parse_reward_config, write_json_atomic

ACTIVE = {"starting", "running", "paused", "stopping", "saving"}
DEFAULTS = dict(run_name="", resume="", output_root="", steps=1_000_000, workers=1, seed=7,
    learning_rate=0.0003, batch_size=64, gamma=0.999, entropy_coefficient=0.01,
    checkpoint_every=10240, eval_every=50000, eval_episodes=64, eval_workers=4,
    eval_seed=10000, success_threshold=0.9, early_stop_patience=3, torch_threads=1)


def read_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def default_python(root: Path) -> str:
    return str(root / ".venv-ai" / ("Scripts/python.exe" if os.name == "nt" else "bin/python"))


def default_godot(root: Path) -> str:
    """Reuse this project's editor executable when Godot is absent from PATH."""
    try:
        return find_godot()
    except FileNotFoundError:
        pass
    metadata = configparser.ConfigParser(interpolation=None)
    try:
        metadata.read(root / ".godot/editor/project_metadata.cfg", encoding="utf-8")
        candidate = json.loads(metadata.get("editor_metadata", "executable_path"))
        if isinstance(candidate, str) and candidate:
            return find_godot(candidate)
    except (OSError, ValueError, configparser.Error):
        pass
    return ""


def resume_settings(checkpoint: str | Path) -> dict:
    path = Path(checkpoint).resolve()
    folder = path.parent.parent if path.parent.name == "checkpoints" else path.parent
    matches = [p for p in folder.glob("*_training_config.json")
               if path.stem == p.name.removesuffix("_training_config.json")
               or path.stem.startswith(p.name.removesuffix("_training_config.json") + "_")]
    if not matches:
        raise ValueError("No training configuration was found beside this checkpoint. Keep its original run name and settings manually.")
    manifest_path = max(matches, key=lambda p: len(p.name))
    manifest = read_json(manifest_path)
    if manifest.get("environment_version") != ENVIRONMENT_VERSION:
        raise ValueError("This checkpoint belongs to an older environment. Start a fresh version 3 run.")
    result = {key: manifest[key] for key in
        ("workers", "learning_rate", "batch_size", "gamma", "entropy_coefficient")}
    evaluation = manifest["evaluation"]
    result.update(run_name=manifest_path.name.removesuffix("_training_config.json"),
        resume=str(path), output_root=str(folder.parent), rewards=manifest["reward_config"],
        eval_seed=evaluation["seed"], eval_episodes=evaluation["episodes"],
        success_threshold=evaluation["threshold"])
    return result


def validate_settings(root: Path, raw: dict) -> dict:
    config = dict(DEFAULTS, **raw)
    for key in DEFAULTS:
        if config[key] == "" and key not in {"run_name", "resume", "output_root"}:
            config[key] = DEFAULTS[key]
    for key in ("steps", "workers", "seed", "batch_size", "checkpoint_every", "eval_every",
                "eval_episodes", "eval_workers", "eval_seed", "early_stop_patience", "torch_threads"):
        try:
            config[key] = int(str(config[key]))
        except (ValueError, TypeError):
            raise ValueError(f"{key.replace('_', ' ').title()} must be a whole number.") from None
        minimum = 0 if key in {"eval_every", "early_stop_patience", "seed", "eval_seed"} else 1
        if config[key] < minimum:
            raise ValueError(f"{key.replace('_', ' ').title()} must be at least {minimum}.")
    if config["eval_workers"] > 32 or config["torch_threads"] > 64:
        raise ValueError("Evaluation workers must be at most 32; PPO CPU threads at most 64.")
    for key, low, high in (("learning_rate", 0, 0.01), ("gamma", 0, 1),
                            ("entropy_coefficient", 0, 1), ("success_threshold", 0, 1)):
        try:
            value = float(config[key])
        except (ValueError, TypeError):
            raise ValueError(f"{key} must be numeric.") from None
        if not math.isfinite(value) or not low <= value <= high or (key in {"gamma", "learning_rate"} and value == 0) or (key == "gamma" and value == 1):
            raise ValueError(f"Invalid {key.replace('_', ' ')}.")
        config[key] = value
    if config["eval_every"] == 0 and config["early_stop_patience"] != 0:
        raise ValueError("Set early-stop patience to 0 when evaluation is disabled.")
    config["python_path"] = str(Path(config.get("python_path") or default_python(root)).expanduser().resolve())
    if not Path(config["python_path"]).is_file():
        raise ValueError("Select a valid Python executable. Run setup_ai_training.cmd to prepare the project environment.")
    config["godot_path"] = find_godot(config.get("godot_path") or None)
    name = str(config["run_name"]).strip()
    if not name:
        if config["resume"]:
            raise ValueError("Use the original run name when resuming (Browse checkpoint loads its settings).")
        name = f"setup2_gui_{time.time_ns()}"
    if not re.fullmatch(r"[A-Za-z0-9_-]+", name):
        raise ValueError("Run name may use only letters, numbers, _ and -.")
    config["run_name"] = name
    config["output_root"] = str(Path(config["output_root"] or root / "ai").expanduser().resolve())
    config["rewards"] = parse_reward_config(json.dumps(config.get("rewards", DEFAULT_REWARD_CONFIG)))
    if config["resume"]:
        path = Path(config["resume"]).expanduser().resolve()
        if not path.is_file() or path.suffix.lower() != ".zip" or name not in path.stem:
            raise ValueError("Select an existing checkpoint ZIP from the same run name.")
        config["resume"] = str(path)
    else:
        models = Path(config["output_root"]) / "models"
        if any(models.glob(name + ".zip")) or (models / f"{name}_training_config.json").exists():
            raise ValueError("This run name already exists. Choose a new name or resume its checkpoint.")
    return config


@contextmanager
def launch_lock(path: Path):
    """Serialize starts from multiple standalone GUI instances."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a+b") as handle:
        handle.seek(0, 2)
        if handle.tell() == 0:
            handle.write(b"0")
            handle.flush()
        handle.seek(0)
        try:
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            raise ValueError("Another GUI is starting training. Wait for it to finish.") from None
        try:
            yield
        finally:
            if os.name == "nt":
                handle.seek(0)
                msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(handle, fcntl.LOCK_UN)


class TrainingSession:
    def __init__(self, root: Path, *, status_path: Path | None = None):
        self.root = root.resolve()
        self.runs = self.root / "ai/runs"
        self.status_path = status_path or self.runs / "gui_training_status.json"
        self.control_path = self.status_path.with_name(self.status_path.stem.replace("status", "control") + ".json")
        self.process = None

    def is_active(self, status: dict | None = None) -> bool:
        if self.process is not None and self.process.poll() is None:
            return True
        status = self.read_status() if status is None else status
        return status.get("state") in ACTIVE and process_is_running(int(status.get("pid", -1)))

    def read_status(self) -> dict:
        return read_json(self.status_path)

    def poll(self) -> dict:
        status = self.read_status()
        if status.get("state") in ACTIVE and not self.is_active(status):
            status.update(state="failed", message="The trainer is no longer running. Open its log for details.")
            try:
                write_json_atomic(self.status_path, status)
            except OSError:
                pass
        return status

    def start(self, raw: dict, parent_ids: list[int] | None = None) -> dict:
        with launch_lock(self.status_path.with_suffix(".start.lock")):
            if self.is_active():
                raise ValueError("Training is already running. End and save it before starting another run.")
            config = validate_settings(self.root, raw)
            if parent_ids is not None and (len(parent_ids) != config["workers"] or len(set(parent_ids)) != len(parent_ids) or any(x <= 0 for x in parent_ids)):
                raise ValueError("Visual training needs one distinct native view for every worker.")
            self.runs.mkdir(parents=True, exist_ok=True)
            run_id = str(time.time_ns())
            log = self.runs / f"gui_training_{run_id}.log"
            rewards = self.runs / f"gui_rewards_{run_id}.json"
            write_json_atomic(rewards, config["rewards"])
            status = dict(run_id=run_id, run_name=config["run_name"], state="starting", pid=os.getpid(),
                python_path=config["python_path"], workers=config["workers"], total_steps=config["steps"],
                timesteps=0, log_path=str(log), visual_training=parent_ids is not None,
                message="Starting training worlds", updated_at=time.time())
            args = [config["python_path"], str(self.root / "ai/gui_train_launcher.py"), "--log-file", str(log)]
            for option, key in (("godot", "godot_path"), ("steps", "steps"), ("n-envs", "workers"),
                ("seed", "seed"), ("learning-rate", "learning_rate"), ("batch-size", "batch_size"),
                ("gamma", "gamma"), ("entropy-coefficient", "entropy_coefficient"),
                ("checkpoint-every", "checkpoint_every"), ("eval-every", "eval_every"),
                ("eval-episodes", "eval_episodes"), ("eval-workers", "eval_workers"), ("eval-seed", "eval_seed"),
                ("success-threshold", "success_threshold"), ("early-stop-patience", "early_stop_patience"),
                ("torch-threads", "torch_threads"), ("run-name", "run_name"), ("output-root", "output_root")):
                args += ["--" + option, str(config[key])]
            args += ["--reward-config-file", str(rewards), "--status-file", str(self.status_path),
                     "--control-file", str(self.control_path), "--run-id", run_id, "--gui-log-path", str(log)]
            if config["resume"]:
                args += ["--resume", config["resume"]]
            if parent_ids is not None:
                parents = self.runs / f"gui_views_{run_id}.json"
                parents.write_text(json.dumps(parent_ids), encoding="utf-8")
                args += ["--visual-parents", str(parents)]
            write_json_atomic(self.status_path, status)
            write_json_atomic(self.control_path, {"run_id": run_id, "command": "run"})
            try:
                self.process = subprocess.Popen(args, cwd=self.root,
                    creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
            except OSError as error:
                status.update(state="failed", message=str(error))
                write_json_atomic(self.status_path, status)
                raise
            current = self.read_status()
            if current.get("run_id") == run_id and current.get("state") == "starting" and current.get("pid") == os.getpid():
                status["pid"] = self.process.pid
                write_json_atomic(self.status_path, status)
            return config

    def command(self, command: str) -> None:
        if command not in {"pause", "run", "stop"}:
            raise ValueError("Invalid training command")
        status = self.read_status()
        if not self.is_active(status):
            raise ValueError("No active training run.")
        write_json_atomic(self.control_path, {"run_id": status["run_id"], "command": command})


def model_metadata(path: Path) -> dict:
    result = dict(path=str(path), name=path.stem, steps=None)
    stat = path.stat()
    result.update(size=stat.st_size, modified=stat.st_mtime)
    try:
        with zipfile.ZipFile(path) as archive:
            if archive.getinfo("data").file_size < 2_000_000:
                result["steps"] = json.loads(archive.read("data")).get("num_timesteps")
    except (OSError, ValueError, KeyError, zipfile.BadZipFile):
        pass
    return result
