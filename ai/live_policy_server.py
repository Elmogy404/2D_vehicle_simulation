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
from policy_checkpoint import STRATEGIES, load_policy, resolve_checkpoint


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, help="Explicit PPO checkpoint; overrides discovery")
    parser.add_argument("--model-dir", type=Path, help="Override the configured checkpoint directory")
    parser.add_argument("--strategy", choices=STRATEGIES, help="Automatic checkpoint selection strategy")
    parser.add_argument("--manifest", type=Path, help="Optional training manifest for the selected checkpoint")
    parser.add_argument("--config", type=Path, help="Optional checkpoint_config.json path")
    parser.add_argument("--require-manifest", action="store_true", help="Reject checkpoints without a valid manifest")
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
        resolved = resolve_checkpoint(
            arguments.model,
            config_path=arguments.config,
            model_dir=arguments.model_dir,
            manifest=arguments.manifest,
            strategy=arguments.strategy,
            require_manifest=arguments.require_manifest,
        )
        logger.info(
            "Resolved PPO checkpoint %s (source=%s, strategy=%s, steps=%d, manifest=%s)",
            resolved.path,
            resolved.source,
            resolved.strategy,
            resolved.num_timesteps,
            resolved.manifest_path or "none",
        )
        model = load_policy(
            resolved.path,
            manifest=resolved.manifest_path,
            require_manifest=arguments.require_manifest,
        )
        logger.info(
            "Loaded PPO checkpoint %s (interface schema v%d)", resolved.path, SCHEMA_VERSION
        )
    except Exception as error:
        logger.exception("Could not load the live PPO checkpoint: %s", error)
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
