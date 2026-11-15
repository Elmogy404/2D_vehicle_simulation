"""Serve deterministic PPO actions to the live Godot driving scene."""

from __future__ import annotations

import argparse
import json
import logging
from pathlib import Path
import socket

from interface_schema import (
    SCHEMA_VERSION,
    metadata as interface_metadata,
    validate_action,
    validate_observation,
    validate_remote_metadata,
)
from policy_checkpoint import load_policy


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
        logger.info(
            "Loaded PPO checkpoint %s (interface schema v%d)", arguments.model, SCHEMA_VERSION
        )
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
                    validate_remote_metadata(request, source="Godot live request")
                    observation = validate_observation(request.get("observation"))
                    action, _state = model.predict(observation, deterministic=True)
                    validated_action, action_clipped = validate_action(action, clip=True)
                    response = {
                        "request_id": request_id,
                        "schema_version": SCHEMA_VERSION,
                        "interface_schema": interface_metadata(),
                        "action": validated_action.tolist(),
                        "action_clipped": action_clipped,
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
