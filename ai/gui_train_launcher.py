"""Capture trainer startup/errors to a file when launched without a console."""

from __future__ import annotations

import os
from pathlib import Path
import runpy
import sys


def main() -> None:
    if len(sys.argv) < 4 or sys.argv[1] != "--log-file":
        raise SystemExit("Usage: gui_train_launcher.py --log-file PATH [train.py options]")
    log_path = Path(sys.argv[2])
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("a", encoding="utf-8", buffering=1) as log:
        os.dup2(log.fileno(), 1)
        os.dup2(log.fileno(), 2)
        sys.stdout = log
        sys.stderr = log
        trainer = Path(__file__).with_name("train.py")
        sys.argv = [str(trainer), *sys.argv[3:]]
        runpy.run_path(str(trainer), run_name="__main__")


if __name__ == "__main__":
    main()
