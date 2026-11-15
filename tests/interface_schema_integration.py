"""Live Godot/Python protocol checks for the shared interface schema."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ai"))

from godot_bridge import GodotBridge  # noqa: E402
from interface_schema import (  # noqa: E402
    SCHEMA_VERSION,
    metadata as interface_metadata,
    validate_observation,
    validate_remote_metadata,
)


SCHEMA_FIELDS = interface_metadata()


def reset_request(seed: int, *, schema_version: int = SCHEMA_VERSION) -> dict:
    fields = dict(SCHEMA_FIELDS, schema_version=schema_version)
    return {
        "type": "reset",
        "seed": seed,
        "options": {"curriculum": False, "curriculum_stage": 0},
        **fields,
    }


def step_request(action, *, schema_version: int = SCHEMA_VERSION) -> dict:
    return {
        "type": "step",
        "action": action,
        **dict(SCHEMA_FIELDS, schema_version=schema_version),
    }


def expect_error(bridge: GodotBridge, request: dict, expected: str) -> None:
    try:
        bridge.request(request)
    except RuntimeError as error:
        if expected not in str(error):
            raise RuntimeError(f"expected {expected!r} in error, got: {error}") from error
    else:
        raise RuntimeError(f"request unexpectedly succeeded: {request!r}")


def check_response(response: dict, label: str) -> None:
    validate_remote_metadata(response["info"].get("interface_schema"), source=label)
    validate_observation(response["observation"])


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True)
    arguments = parser.parse_args()

    with GodotBridge(arguments.godot) as bridge:
        expect_error(
            bridge,
            reset_request(4101, schema_version=SCHEMA_VERSION + 1),
            "interface schema version",
        )
        print("RESET SCHEMA MISMATCH PASS")

        reset_response = bridge.request(reset_request(4101))
        check_response(reset_response, "integration reset")
        print("RESET SCHEMA HANDSHAKE PASS")

        expect_error(
            bridge,
            step_request([0.0, 0.0], schema_version=SCHEMA_VERSION + 1),
            "interface schema version",
        )
        print("STEP SCHEMA MISMATCH PASS")

        expect_error(bridge, step_request(["bad", 0.0]), "action schema error")
        expect_error(bridge, step_request([0.0]), "action shape")
        print("MALFORMED ACTION REJECTION PASS")

        clipped_response = bridge.request(step_request([2.0, -2.0]))
        check_response(clipped_response, "integration clipped step")
        if not clipped_response["info"].get("action_clipped", False):
            raise RuntimeError("out-of-range action was not reported as clipped")
        print("ACTION CLIPPING PASS")

        valid_response = bridge.request(step_request([0.0, 0.35]))
        check_response(valid_response, "integration valid step")
        print("VALID STEP PASS")


if __name__ == "__main__":
    main()
