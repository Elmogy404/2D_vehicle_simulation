"""Create a Python environment for this computer and install PPO dependencies."""

from __future__ import annotations

from datetime import datetime
import json
from pathlib import Path
import subprocess
import sys
import venv


def main() -> None:
    if sys.version_info < (3, 10):
        raise SystemExit("Install Python 3.10 or newer, then run setup_ai_training.cmd again.")
    project = Path(__file__).resolve().parents[1]
    environment = project / ".venv-ai"
    python = environment / "Scripts" / "python.exe"
    if environment.exists():
        # A copied venv contains paths to the original computer's Python.
        # Preserve it before replacing it with a compatible local environment.
        compatible = False
        try:
            result = subprocess.run(
                [str(python), "-c", "import json,sys; print(json.dumps([sys.base_prefix, list(sys.version_info[:2])]))"],
                capture_output=True, text=True, timeout=20, check=True,
            )
            base, version = json.loads(result.stdout)
            compatible = Path(base).resolve() == Path(sys.base_prefix).resolve() and version == list(sys.version_info[:2])
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
        if not compatible:
            backup = environment.with_name(".venv-ai-backup-" + datetime.now().strftime("%Y%m%d-%H%M%S-%f"))
            environment.rename(backup)
            print(f"Preserved the incompatible/copied environment at {backup}", flush=True)
    if not python.exists():
        print("Creating this computer's AI Python environment...", flush=True)
        venv.EnvBuilder(with_pip=True).create(environment)
    print("Installing AI dependencies. This needs internet access and may take several minutes...", flush=True)
    subprocess.run([str(python), "-m", "pip", "install", "-r", str(project / "ai" / "requirements.txt")], check=True)
    subprocess.run([str(python), "-c", "import torch, gymnasium, stable_baselines3; print('AI dependencies loaded successfully.')"], check=True)
    print(f"\nPython executable for the AI Training tab:\n{python}", flush=True)
    print("Set Godot executable to your installed Godot 4 engine .exe, then press Start training.")


if __name__ == "__main__":
    main()
