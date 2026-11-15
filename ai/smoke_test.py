"""End-to-end smoke test for the Godot/Python JSON-lines bridge."""

from __future__ import annotations

import argparse
import math

from godot_bridge import GodotBridge
from interface_schema import (
    OBSERVATION_SIZE,
    metadata as interface_metadata,
    validate_observation,
    validate_remote_metadata,
)


SCHEMA_FIELDS = interface_metadata()
GOAL_DISTANCE_RANGES = (
    (250.0, 400.0),
    (400.0, 650.0),
    (600.0, 900.0),
    (800.0, 1200.0),
    (1200.0, 1800.0),
    (1800.0, 2700.0),
    (2700.0, 4000.0),
    (4200.0, 5500.0),
)


def reset_request(seed: int, options: dict | None = None) -> dict:
    return {
        "type": "reset",
        "seed": seed,
        "options": options or {},
        **SCHEMA_FIELDS,
    }


def step_request(action: list[float]) -> dict:
    return {"type": "step", "action": action, **SCHEMA_FIELDS}


def checked_reset(bridge: GodotBridge, seed: int, options: dict | None = None) -> dict:
    result = bridge.request(reset_request(seed, options))
    validate_remote_metadata(result["info"].get("interface_schema"), source="smoke reset")
    validate_observation(result["observation"])
    return result


def checked_step(bridge: GodotBridge, action: list[float]) -> dict:
    result = bridge.request(step_request(action))
    validate_remote_metadata(result["info"].get("interface_schema"), source="smoke step")
    validate_observation(result["observation"])
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", help="Godot 4 executable; defaults to GODOT_BIN/PATH")
    parser.add_argument("--seed", type=int, default=4101)
    arguments = parser.parse_args()

    with GodotBridge(arguments.godot) as bridge:
        reset_result = checked_reset(bridge, arguments.seed)
        if not reset_result["info"].get("spawn_clear", False):
            raise RuntimeError("Training reset did not produce a collision-free spawn")
        observation = reset_result["observation"]
        if len(observation) != OBSERVATION_SIZE:
            raise RuntimeError(f"Expected {OBSERVATION_SIZE} observations, got {len(observation)}")
        goal_distance = float(reset_result["info"]["goal_distance"])
        if not (
            GOAL_DISTANCE_RANGES[0][0]
            <= goal_distance
            <= GOAL_DISTANCE_RANGES[0][1]
        ):
            raise RuntimeError(
                "Initial curriculum goal distance is outside stage 0: %.1f" % goal_distance
            )
        if int(reset_result["info"]["curriculum_stage"]) != 0:
            raise RuntimeError("A fresh training world must begin at curriculum stage 0")
        print(
            "RESET PASS: seed=%s start=%.1f goal=%.1f distance=%.1f stage=%d obs=%d"
            % (
                reset_result["info"]["seed"],
                reset_result["info"]["start_progress"],
                reset_result["info"]["goal_progress"],
                goal_distance,
                reset_result["info"]["curriculum_stage"],
                len(observation),
            )
        )

        repeated_reset = checked_reset(bridge, arguments.seed)
        if repeated_reset["observation"] != observation:
            raise RuntimeError("Resetting with the same seed changed the initial observation")
        stable = lambda info: {k: v for k, v in info.items() if k != "reset_ms"}
        if stable(repeated_reset["info"]) != stable(reset_result["info"]):
            raise RuntimeError("Resetting with the same seed changed episode route metadata")
        print("DETERMINISM PASS: same seed reproduces the route and initial observation")

        for stage, (minimum_distance, maximum_distance) in enumerate(GOAL_DISTANCE_RANGES):
            stage_reset = checked_reset(
                bridge,
                arguments.seed + stage,
                {"curriculum": False, "curriculum_stage": stage},
            )
            stage_distance = float(stage_reset["info"]["goal_distance"])
            if not stage_reset["info"].get("spawn_clear", False):
                raise RuntimeError(f"Stage {stage} spawned in an obstructed position")
            if int(stage_reset["info"]["curriculum_stage"]) != stage:
                raise RuntimeError(f"Requested curriculum stage {stage} was not applied")
            if not minimum_distance <= stage_distance <= maximum_distance:
                raise RuntimeError(
                    "Stage %d goal distance %.1f is outside [%.1f, %.1f]"
                    % (stage, stage_distance, minimum_distance, maximum_distance)
                )
            if stage == 7:
                if int(stage_reset["info"].get("route_turns", 0)) < 4:
                    raise RuntimeError("Longest route tier did not include the required turns")
                if not stage_reset["info"].get("turn_requirement_met", False):
                    raise RuntimeError("Longest route tier had to fall back below its turn target")
        print("CURRICULUM PASS: all eight route-distance/turn tiers are in range")

        observation = checked_reset(bridge, arguments.seed)["observation"]

        total_reward = 0.0
        for step_index in range(12):
            result = checked_step(bridge, [0.0, 0.35])
            observation = result["observation"]
            if len(observation) != OBSERVATION_SIZE:
                raise RuntimeError(f"Step returned {len(observation)} observations")
            if not math.isfinite(float(result["reward"])):
                raise RuntimeError(f"Step {step_index} returned a non-finite reward")
            total_reward += float(result["reward"])
            if result["terminated"] or result["truncated"]:
                break
        print(f"STEP PASS: {step_index + 1} actions, accumulated reward={total_reward:.3f}")

        from training_control import DEFAULT_REWARD_CONFIG

        zero_rewards = {key: 0.0 for key in DEFAULT_REWARD_CONFIG}
        checked_reset(bridge, arguments.seed, {"reward_config": zero_rewards})
        zero_step = checked_step(bridge, [0.0, 0.0])
        if abs(float(zero_step["reward"])) > 1e-6:
            raise RuntimeError("Custom reward weights were not applied to the training world")
        print("REWARD CONFIG PASS: zeroed weights produce zero reward")


if __name__ == "__main__":
    main()
