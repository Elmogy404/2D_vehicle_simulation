"""Capture trainer startup/errors to a file when launched without a console."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import traceback


def process_is_running(pid: int) -> bool:
    """Check an external PID, including processes another Godot window started."""
    if pid <= 0:
        return False
    if os.name == "nt":
        import ctypes
        from ctypes import wintypes

        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        kernel.OpenProcess.restype = wintypes.HANDLE
        kernel.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
        kernel.GetExitCodeProcess.restype = wintypes.BOOL
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        handle = kernel.OpenProcess(0x1000, False, pid)  # QUERY_LIMITED_INFORMATION
        if not handle:
            return ctypes.get_last_error() == 5  # Access denied still proves it exists.
        try:
            code = wintypes.DWORD()
            return bool(kernel.GetExitCodeProcess(handle, ctypes.byref(code))) and code.value == 259
        finally:
            kernel.CloseHandle(handle)
    try:
        os.kill(pid, 0)
        return True
    except PermissionError:
        return True
    except ProcessLookupError:
        return False


def report_failure(arguments: list[str], message: str) -> None:
    """Report failures that occur before the trainer creates TrainingControl."""
    def option(name: str) -> str:
        if name not in arguments:
            return ""
        index = arguments.index(name) + 1
        return arguments[index] if index < len(arguments) else ""

    status_name = option("--status-file")
    if not status_name:
        return
    path = Path(status_name)
    try:
        status = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(status, dict):
            return
        if status.get("run_id") != option("--run-id") or status.get("state") == "failed":
            return
        status.update(state="failed", message=message)
        temporary = path.with_suffix(".launcher.tmp")
        temporary.write_text(json.dumps(status), encoding="utf-8")
        temporary.replace(path)
    except (OSError, ValueError):
        pass  # The complete error remains available in the run log.


def main() -> None:
    if len(sys.argv) == 3 and sys.argv[1] == "--probe-pid":
        raise SystemExit(0 if process_is_running(int(sys.argv[2])) else 1)
    if len(sys.argv) < 4 or sys.argv[1] != "--log-file":
        raise SystemExit("Usage: gui_train_launcher.py --log-file PATH [train.py options]")
    log_path = Path(sys.argv[2])
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("a", encoding="utf-8", buffering=1) as log:
        trainer = Path(__file__).resolve().with_name("train.py")
        arguments = sys.argv[3:]
        log.write(f"Python: {sys.executable}\nVersion: {sys.version}\nTrainer: {trainer}\n")
        try:
            log.write(f"Trainer SHA256: {hashlib.sha256(trainer.read_bytes()).hexdigest()}\n")
            log.flush()
            result = subprocess.run(
                [sys.executable, "-u", str(trainer), *arguments],
                cwd=trainer.parent.parent,
                stdout=log,
                stderr=subprocess.STDOUT,
                env={**os.environ, "PYTHONUNBUFFERED": "1"},
            )
            exit_code = result.returncode
        except Exception as error:
            traceback.print_exc(file=log)
            report_failure(arguments, str(error))
            exit_code = 1
    if exit_code:
        lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
        message = next((line.strip() for line in reversed(lines) if line.strip()), "Trainer failed")
        if "ModuleNotFoundError" in message or "ImportError" in message:
            message += ". Run setup_ai_training.cmd in the project folder to install AI dependencies."
        report_failure(arguments, message)
    raise SystemExit(exit_code)


if __name__ == "__main__":
    main()
