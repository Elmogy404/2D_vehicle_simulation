"""Serve deterministic PPO actions to the live Godot driving scene."""

from __future__ import annotations

import argparse
import io
import json
import logging
from pathlib import Path
import socket
import zipfile
from unittest.mock import patch

import numpy as np


OBSERVATION_SIZE = 31


def load_policy(path: Path):
    """Load a local SB3 archive with the compatibility used by our eval tools."""
    import torch
    from stable_baselines3 import PPO

    original_torch_load = torch.load

    def load_buffered_zip_member(file_object, *args, **kwargs):
        if isinstance(file_object, zipfile.ZipExtFile):
            file_object = io.BytesIO(file_object.read())
        return original_torch_load(file_object, *args, **kwargs)

    with patch.object(torch, "load", side_effect=load_buffered_zip_member):
        return PPO.load(path, device="cpu")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--port", required=True, type=int)
    return parser.parse_args()


def main() -> int:
    arguments = parse_args()
    project_root = Path(__file__).resolve().parents[1]
    log_path = project_root / "ai" / "runs" / "live_policy.log"
    log_path.parent.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(
        filename=log_path,
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        encoding="utf-8",
    )
    logger = logging.getLogger("live_policy")

    try:
        if not arguments.model.is_file():
            raise FileNotFoundError(f"PPO checkpoint does not exist: {arguments.model}")
        model = load_policy(arguments.model)
        logger.info("Loaded PPO checkpoint %s", arguments.model)
    except Exception:
        logger.exception("Could not load the live PPO checkpoint")
        return 2

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        server.bind(("127.0.0.1", arguments.port))
        server.listen(1)
        logger.info("Listening on 127.0.0.1:%d", arguments.port)
        connection, _address = server.accept()
        with connection:
            stream = connection.makefile("rwb")
            for raw_line in stream:
                request = {}
                try:
                    request = json.loads(raw_line)
                    if request.get("type") == "shutdown":
                        stream.write(b'{"closed":true}\n')
                        stream.flush()
                        break

                    request_id = int(request.get("request_id", -1))
                    observation = np.asarray(request.get("observation", []), dtype=np.float32)
                    if observation.shape != (OBSERVATION_SIZE,):
                        raise ValueError(
                            f"expected {OBSERVATION_SIZE} observation values, "
                            f"got shape {observation.shape}"
                        )
                    if not np.isfinite(observation).all():
                        raise ValueError("observation contains a non-finite value")
                    action, _state = model.predict(observation, deterministic=True)
                    response = {
                        "request_id": request_id,
                        "action": np.asarray(action, dtype=np.float32).reshape(2).tolist(),
                    }
                except Exception as error:
                    logger.exception("Live policy request failed")
                    response = {
                        "request_id": int(request.get("request_id", -1))
                        if isinstance(request, dict)
                        else -1,
                        "error": str(error),
                    }
                stream.write((json.dumps(response, separators=(",", ":")) + "\n").encode("utf-8"))
                stream.flush()
    except Exception:
        logger.exception("Live policy server stopped unexpectedly")
        return 3
    finally:
        server.close()
    logger.info("Live policy session ended")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
