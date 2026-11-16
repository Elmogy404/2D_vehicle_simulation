"""Run a trained policy continuously in a visible Godot window."""

from __future__ import annotations

import argparse
from collections import deque
from pathlib import Path

from godot_gym_env import GodotRoadEnv
from deterministic_seeds import set_global_seeds
from interface_schema import SchemaCompatibilityError


from policy_checkpoint import (
    STRATEGIES,
    CheckpointError,
    checkpoint_generator,
    load_policy as load_model,
    resolve_checkpoint,
)
from reward_config import RewardConfigError, reward_config_from_manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--model",
        help="Explicit saved Stable-Baselines3 PPO model; overrides automatic discovery",
    )
    parser.add_argument("--model-dir", type=Path, help="Override the configured checkpoint directory")
    parser.add_argument("--strategy", choices=STRATEGIES, help="Automatic checkpoint selection strategy")
    parser.add_argument("--manifest", type=Path, help="Optional training manifest for the selected checkpoint")
    parser.add_argument("--config", type=Path, help="Optional checkpoint_config.json path")
    parser.add_argument("--require-manifest", action="store_true", help="Reject checkpoints without a valid manifest")
    parser.add_argument("--seed", type=int, default=30_000)
    parser.add_argument(
        "--curriculum-stage",
        type=int,
        default=7,
        help="Goal-distance tier to monitor (0=shortest, 7=longest)",
    )
    parser.add_argument("--godot", help="Godot 4 executable; defaults to GODOT_BIN/PATH")
    parser.add_argument("--generator-type", choices=["original", "segmented"])
    parser.add_argument("--stop-file", help="GUI-owned watch session: stop when this file exists and close its Godot window")
    arguments = parser.parse_args()
    if arguments.curriculum_stage not in range(8):
        parser.error("--curriculum-stage must be from 0 to 7")
    set_global_seeds(arguments.seed)

    model_path = Path(arguments.model) if arguments.model else None
    try:
        resolved = resolve_checkpoint(
            model_path,
            config_path=arguments.config,
            model_dir=arguments.model_dir,
            manifest=arguments.manifest,
            strategy=arguments.strategy,
            require_manifest=arguments.require_manifest,
        )
        print(
            "Using checkpoint %s (source=%s, strategy=%s, steps=%d)"
            % (resolved.path, resolved.source, resolved.strategy, resolved.num_timesteps),
            flush=True,
        )
        model = load_model(
            resolved.path,
            manifest=resolved.manifest_path,
            require_manifest=arguments.require_manifest,
        )
        reward_config = reward_config_from_manifest(
            resolved.manifest,
            source=f"checkpoint manifest {resolved.manifest_path or '(none)'}",
        )
    except (CheckpointError, SchemaCompatibilityError, RewardConfigError) as error:
        parser.error(str(error))
    env = GodotRoadEnv(
        arguments.godot,
        visible=True,
        close_visible_on_exit=bool(arguments.stop_file),
        reward_config=reward_config,
        generator_type=checkpoint_generator(resolved.path, arguments.generator_type, manifest=resolved.manifest_path),
    )
    stop_file = Path(arguments.stop_file) if arguments.stop_file else None
    episode = 0
    successes = 0
    crashes = 0
    off_road_ends = 0
    recent_successes: deque[bool] = deque(maxlen=50)
    print(
        "AI watch active: close the Godot window or press Escape to stop. "
        "Setup 2 has no traffic, pedestrians, or signals.",
        flush=True,
    )

    try:
        while not (stop_file and stop_file.exists()):
            seed = arguments.seed + episode
            observation, _info = env.reset(
                seed=seed,
                options={
                    "curriculum": False,
                    "curriculum_stage": arguments.curriculum_stage,
                },
            )
            episode_return = 0.0
            steps = 0
            final_info: dict[str, object] = {}
            while True:
                if stop_file and stop_file.exists():
                    return
                action, _state = model.predict(observation, deterministic=True)
                observation, reward, terminated, truncated, final_info = env.step(action)
                episode_return += float(reward)
                steps += 1
                if terminated or truncated:
                    break

            success = bool(final_info.get("success", False))
            crashed = bool(final_info.get("crashed", False))
            off_road = bool(final_info.get("off_road", False))
            successes += int(success)
            crashes += int(crashed)
            off_road_ends += int(off_road)
            episode += 1
            recent_successes.append(success)
            rolling_success_rate = 100.0 * sum(recent_successes) / len(recent_successes)
            print(
                "episode=%d seed=%d success=%s crash=%s off_road=%s turns=%d "
                "turn_target_met=%s steps=%d return=%.2f rolling_success_50=%.1f%%"
                % (
                    episode,
                    seed,
                    success,
                    crashed,
                    off_road,
                    int(final_info.get("route_turns", 0)),
                    bool(final_info.get("turn_requirement_met", False)),
                    steps,
                    episode_return,
                    rolling_success_rate,
                ),
                flush=True,
            )
    except (OSError, RuntimeError) as error:
        # Closing the Godot window disconnects the bridge; treat that as a
        # normal end to this user-controlled monitoring session.
        print(f"AI watch stopped: {error}", flush=True)
    finally:
        env.close()
        if episode:
            print(
                "FINAL episodes=%d success=%.1f%% crash=%d off_road=%d"
                % (
                    episode,
                    100.0 * successes / episode,
                    crashes,
                    off_road_ends,
                ),
                flush=True,
            )


if __name__ == "__main__":
    main()
