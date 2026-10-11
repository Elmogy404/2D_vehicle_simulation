"""Small JSON-lines bridge that launches and controls one headless Godot world."""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import time
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]


def find_godot(executable: str | None = None) -> str:
    """Resolve Godot from an explicit path, GODOT_BIN, or PATH."""
    candidate = executable or os.environ.get("GODOT_BIN")
    if candidate:
        path = Path(candidate).expanduser()
        if path.is_file():
            return str(path.resolve())
        found = shutil.which(candidate)
        if found:
            return found
        raise FileNotFoundError(
            f"Godot executable not found: {candidate!r}. Set GODOT_BIN or pass --godot."
        )
    for name in ("godot", "godot4", "godot.exe", "godot4.exe"):
        found = shutil.which(name)
        if found:
            return found
    raise FileNotFoundError(
        "Godot was not found on PATH. Set GODOT_BIN to the Godot 4 executable "
        "or pass --godot <path>."
    )


class GodotBridge:
    """Request/response transport for the RL training scene (no ML deps)."""

    def __init__(
        self,
        godot_executable: str | None = None,
        project_root: Path = PROJECT_ROOT,
        startup_timeout: float = 45.0,
        visible: bool = False,
    ) -> None:
        self.project_root = Path(project_root).resolve()
        self.visible = visible
        self._socket: socket.socket | None = None
        self._process: subprocess.Popen[bytes] | None = None
        self._log_handle: Any = None
        self._receive_buffer = bytearray()
        self._closed = False

        godot = find_godot(godot_executable)
        runs_dir = self.project_root / "ai" / "runs"
        runs_dir.mkdir(parents=True, exist_ok=True)
        self.log_path = runs_dir / f"godot_{os.getpid()}_{time.time_ns()}.log"

        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        listener.settimeout(startup_timeout)
        port = listener.getsockname()[1]
        command = [godot]
        if not visible:
            command.append("--headless")
        command.extend(
            [
                "--path",
                str(self.project_root),
                "--scene",
                "res://ai/rl_training_world.tscn",
                "--",
                "--port",
                str(port),
            ]
        )
        if visible:
            command.append("--visible")
        self._log_handle = self.log_path.open("wb")
        try:
            self._process = subprocess.Popen(
                command,
                cwd=self.project_root,
                stdin=subprocess.DEVNULL,
                stdout=self._log_handle,
                stderr=subprocess.STDOUT,
            )
            connection, _address = listener.accept()
            connection.settimeout(startup_timeout)
            self._socket = connection
        except Exception:
            self._stop_process()
            tail = ""
            if self.log_path.exists():
                tail = self.log_path.read_text(encoding="utf-8", errors="replace")[-4000:]
            raise RuntimeError(
                f"Could not connect to the Godot training world. Log: {self.log_path}\n{tail}"
            ) from None
        finally:
            listener.close()

    def request(self, message: dict[str, Any]) -> dict[str, Any]:
        if self._socket is None or self._closed:
            raise RuntimeError("Godot bridge is closed")
        payload = json.dumps(message, separators=(",", ":"), allow_nan=False).encode("utf-8")
        self._socket.sendall(payload + b"\n")
        while b"\n" not in self._receive_buffer:
            chunk = self._socket.recv(65536)
            if not chunk:
                raise RuntimeError(f"Godot training world disconnected. Log: {self.log_path}")
            self._receive_buffer.extend(chunk)
        line, _, remainder = self._receive_buffer.partition(b"\n")
        self._receive_buffer = bytearray(remainder)
        response = json.loads(line.decode("utf-8"))
        if "error" in response:
            raise RuntimeError(f"Godot training world: {response['error']}")
        return response

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        if self._socket is not None:
            try:
                self._socket.sendall(b'{"type":"close"}\n')
                self._socket.settimeout(2.0)
                self._socket.recv(1024)
            except OSError:
                pass
            try:
                self._socket.close()
            except OSError:
                pass
            self._socket = None
        if self.visible:
            # In monitor mode the Godot window belongs to the user after the
            # evaluator exits; its close button ends the visible process.
            self._process = None
            if self._log_handle is not None:
                self._log_handle.close()
                self._log_handle = None
        else:
            self._stop_process()

    def _stop_process(self) -> None:
        if self._process is not None:
            if self._process.poll() is None:
                self._process.terminate()
                try:
                    self._process.wait(timeout=5.0)
                except subprocess.TimeoutExpired:
                    self._process.kill()
                    self._process.wait(timeout=5.0)
            self._process = None
        if self._log_handle is not None:
            self._log_handle.close()
            self._log_handle = None

    def __enter__(self) -> "GodotBridge":
        return self

    def __exit__(self, *_exc: object) -> None:
        self.close()
